import { createHash } from "node:crypto";
import type { Risk } from "../protocol/objects.js";

/**
 * What a shell command is, for approval rules and approval modes. Only one simple command, a
 * single program with plain arguments, may pass without asking. Chains, pipes, substitutions,
 * redirections, environment assignments and programs that run other commands or code always ask
 * and rate high risk. The reading is conservative: whatever the Town Hall cannot be sure of
 * counts as not simple.
 */
export interface CommandShape {
  /** One program with plain arguments: the only kind a rule or the approval mode may pass. */
  simple: boolean;
  /** Why the command is not simple; null when it is. */
  reason: string | null;
  /**
   * What a task or agent rule made from the command covers. A program with known subcommands
   * gives its subcommand ("git status", "npm run build", "npx vitest run") and covers any further
   * arguments that stay inside the work folder; any other command gives all its words and covers
   * only itself.
   */
  signature: string;
  /** "high" when the command is not simple, or can destroy work or reach far. */
  risk: Risk | undefined;
}

/** The shell a command is written for. "any" must read the same in bash and in PowerShell. */
export type Dialect = "bash" | "powershell" | "any";

const WHY = {
  text: "the request has no command text",
  empty: "there is no program to run",
  several: "it runs several commands",
  redirect: "it redirects input or output",
  expand: "it substitutes or expands text",
  group: "it groups commands or code",
  comment: "it contains a comment",
  quoting: "its quoting or escaping is ambiguous",
  characters: "it contains unusual characters",
  assignment: "it sets environment variables first",
  statement: "it is a shell statement",
  pattern: "its program is a file pattern",
  wrapper: "it runs another command or inline code",
  long: "it is too long to read for certain",
} as const;

/** The shells of the harness tools; Codex's `shell` names its own (see unwrapCodex). */
const DIALECTS: Record<string, Dialect> = { Bash: "bash", bash: "bash", PowerShell: "powershell", powershell: "powershell" };

/** A table entry by a name from the command, never one of Object.prototype's. */
function lookup<T>(table: Record<string, T>, key: string): T | undefined {
  return Object.hasOwn(table, key) ? table[key] : undefined;
}

/** The shape of a command-category call; a call without command text is never simple. */
export function commandShapeOf(tool: string, input: unknown): CommandShape {
  const command = input && typeof input === "object" ? (input as Record<string, unknown>).command : undefined;
  return typeof command === "string" ? commandShape(tool, command) : notSimple(WHY.text);
}

export function commandShape(tool: string, command: string): CommandShape {
  const { script, dialect } = tool === "shell" ? unwrapCodex(command) : { script: command, dialect: lookup(DIALECTS, tool) ?? "any" };
  const lexed = lex(script, dialect);
  const judged = "reason" in lexed ? lexed : judge(lexed.words, dialect, 0);
  if ("reason" in judged) return notSimple(judged.reason);
  return { simple: true, reason: null, signature: capped(judged.signature), risk: judged.high ? "high" : undefined };
}

function notSimple(reason: string): CommandShape {
  return { simple: false, reason, signature: `<${reason}>`, risk: "high" };
}

// ---------- the harness wrapper ----------

const PWSH_FLAGS = new Set(["-nologo", "-noprofile", "-noninteractive"]);
/** Prefixes Codex puts before a PowerShell script so that its output is UTF-8. */
const UTF8_PREFIXES = [
  "try { [Console]::OutputEncoding=[System.Text.Encoding]::UTF8 } catch {}",
  "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;",
];
const SHELL_FILES = new Set(["pwsh", "pwsh.exe", "powershell", "powershell.exe", "bash", "bash.exe", "zsh", "sh", "sh.exe"]);
/** Where an installed shell lives; a shell anywhere else could be a file the agent wrote. */
const SHELL_DIRS = [
  /^[a-z]:\/program files( \(x86\))?\/powershell\/[^/]+$/,
  /^[a-z]:\/program files\/windowsapps\/microsoft\.powershell_[^/]+$/,
  /^[a-z]:\/windows\/system32\/windowspowershell\/v1\.0$/,
  /^[a-z]:\/users\/[^/]+\/appdata\/local\/microsoft\/windowsapps$/,
  /^[a-z]:\/program files\/git\/(usr\/)?bin$/,
  /^\/(usr\/(local\/)?)?bin$/,
  /^\/opt\/homebrew\/bin$/,
];

/** The shell a Codex argv starts with, when it is an installed one: "pwsh", "bash", ... */
function installedShell(word: string): string | null {
  const path = word.toLowerCase().replace(/\\/g, "/");
  const slash = path.lastIndexOf("/");
  const file = path.slice(slash + 1);
  if (!SHELL_FILES.has(file)) return null;
  if (slash >= 0 && !SHELL_DIRS.some((dir) => dir.test(path.slice(0, slash)))) return null;
  return file.replace(/\.exe$/, "");
}

/**
 * Codex runs every command through the player's shell and sends the argv joined with POSIX
 * quoting: `"C:\\...\\pwsh.exe" -Command '<script>'`, `/bin/zsh -lc '<script>'`. Exactly those
 * wrappers are taken off; the script inside is read in that shell's dialect. Anything else is
 * read as it stands, for bash and PowerShell at once, where a shell is a wrapper.
 */
function unwrapCodex(command: string): { script: string; dialect: Dialect } {
  const argv = lex(command, "bash");
  if ("words" in argv) {
    const [shell = "", ...rest] = argv.words;
    const name = installedShell(shell);
    if (name === "pwsh" || name === "powershell") {
      let i = 0;
      while (i < rest.length - 2 && PWSH_FLAGS.has(rest[i]!.toLowerCase())) i++;
      const flag = rest[i]?.toLowerCase();
      if (rest.length === i + 2 && (flag === "-command" || flag === "-c")) {
        return { script: withoutUtf8Prefix(rest[i + 1]!), dialect: "powershell" };
      }
    }
    if (name === "bash" || name === "zsh" || name === "sh") {
      if (rest.length === 2 && (rest[0] === "-lc" || rest[0] === "-c")) return { script: rest[1]!, dialect: "bash" };
      if (rest.length === 3 && rest[0] === "-l" && rest[1] === "-c") return { script: rest[2]!, dialect: "bash" };
    }
  }
  return { script: command, dialect: "any" };
}

function withoutUtf8Prefix(script: string): string {
  for (const prefix of UTF8_PREFIXES) {
    if (script.startsWith(prefix)) return script.slice(prefix.length).replace(/^[\s;]+/, "");
  }
  return script;
}

// ---------- splitting into words ----------

// Control characters, invisible and bidirectional formatting and Unicode spaces: a card would
// show the command as something it is not, and the shells disagree on them.
const UNUSUAL =
  /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u00a0\u00ad\u034f\u061c\u115f\u1160\u1680\u17b4\u17b5\u180e\u2000-\u200f\u2028-\u202f\u205f-\u206f\u2800\u3000\u3164\ufeff\uffa0\ufff9-\ufffb]/;
/** Curly quotes, which PowerShell reads as quotes. */
const CURLY_QUOTES = /[\u2018-\u201f]/;

type Lexed = { words: string[] } | { reason: string };

function oneOf(ch: string, set: string): boolean {
  return ch !== "" && set.includes(ch);
}

/** Splits a command into unquoted words, or says why it is not one plain command. */
function lex(text: string, dialect: Dialect): Lexed {
  if (UNUSUAL.test(text) || (dialect !== "bash" && CURLY_QUOTES.test(text))) return { reason: WHY.characters };
  const words: string[] = [];
  let word = "";
  let open = false;
  let i = 0;
  while (i < text.length) {
    const c = text.charAt(i);
    const next = text.charAt(i + 1);
    if (c === " " || c === "\t") {
      if (open) words.push(word);
      word = "";
      open = false;
      i++;
    } else if (c === "'") {
      // Literal up to the closing quote; PowerShell doubles a quote inside.
      let j = i + 1;
      for (;;) {
        if (j >= text.length) return { reason: WHY.quoting };
        const q = text.charAt(j);
        if (q === "'" && dialect === "powershell" && text.charAt(j + 1) === "'") {
          word += "'";
          j += 2;
        } else if (q === "'") {
          break;
        } else {
          word += q;
          j++;
        }
      }
      open = true;
      i = j + 1;
    } else if (c === '"') {
      let j = i + 1;
      for (;;) {
        if (j >= text.length) return { reason: WHY.quoting };
        const q = text.charAt(j);
        const e = text.charAt(j + 1);
        if (q === '"' && dialect === "powershell" && e === '"') {
          word += '"';
          j += 2;
        } else if (q === '"') {
          break;
        } else if (q === "$" || q === "`") {
          // Both shells expand variables and run substitutions inside double quotes.
          return { reason: WHY.expand };
        } else if (q === "\\" && dialect !== "powershell" && oneOf(e, '"\\$`\n\r')) {
          // bash escapes these; PowerShell keeps the backslash, so "any" cannot tell.
          if (dialect === "any" || e === "\n" || e === "\r") return { reason: WHY.quoting };
          word += e;
          j += 2;
        } else {
          word += q;
          j++;
        }
      }
      open = true;
      i = j + 1;
    } else if (c === "\\" && dialect !== "powershell") {
      // An escape in bash, a plain character in PowerShell: "any" cannot tell which.
      if (dialect === "any" || next === "" || next === "\n" || next === "\r") return { reason: WHY.quoting };
      word += next;
      open = true;
      i += 2;
    } else if (oneOf(c, ";&|\n\r")) {
      return { reason: WHY.several };
    } else if (c === "<" || c === ">") {
      return { reason: WHY.redirect };
    } else if (oneOf(c, "(){}")) {
      return { reason: WHY.group };
    } else if (oneOf(c, "$`!")) {
      return { reason: WHY.expand };
    } else if (c === "#") {
      return { reason: WHY.comment };
    } else if (c === "@" && !open && dialect !== "bash" && (next === "'" || next === '"' || /^@[\w:]+(?:[ \t]|$)/.test(text.slice(i)))) {
      // A PowerShell here-string or splatted variable.
      return { reason: WHY.expand };
    } else {
      word += c;
      open = true;
      i++;
    }
  }
  if (open) words.push(word);
  // PowerShell's stop-parsing token hands the rest of the line over unparsed.
  if (dialect !== "bash" && words.includes("--%")) return { reason: WHY.quoting };
  return { words };
}

// ---------- judging the words ----------

type Judged = { signature: string; high: boolean } | { reason: string };

const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=/;
const STATEMENTS = new Set([
  "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "select", "function",
  "coproc", "[[", "]]", "!", "foreach", "switch", "try", "catch", "finally", "param", "begin", "process", "end",
  "filter", "workflow", "class", "enum", "using", "data", "configuration",
]);

/** Programs that run another command, a script or code given as an argument. */
const WRAPPERS = new Set([
  // Shells and terminals.
  "sh", "bash", "zsh", "dash", "ksh", "mksh", "csh", "tcsh", "fish", "ash", "busybox", "nu", "xonsh", "elvish",
  "cmd", "pwsh", "powershell", "powershell_ise", "wsl", "wt", "conhost", "winpty",
  // Running something else, elevated, later or elsewhere.
  "env", "xargs", "sudo", "doas", "su", "runas", "pkexec", "gsudo", "nohup", "time", "timeout", "nice", "ionice",
  "chrt", "taskset", "stdbuf", "unbuffer", "watch", "strace", "ltrace", "gdb", "chroot", "setsid", "flock",
  "parallel", "script", "expect", "at", "batch", "crontab", "schtasks", "ssh", "scp", "sftp", "exec", "eval",
  "source", ".", "command", "builtin", "trap", "call", "start", "open", "xdg-open", "explorer", "forfiles", "wmic",
  "sc", "rundll32", "regsvr32", "mshta", "cscript", "wscript", "cross-env", "dotenv", "dotenvx", "direnv",
  "concurrently", "nodemon", "hyperfine", "mise", "asdf",
  // PowerShell.
  "iex", "invoke-expression", "icm", "invoke-command", "start-process", "saps", "start-job", "sajb",
  "start-threadjob", "invoke-item", "ii", "add-type", "invoke-wmimethod", "invoke-cimmethod",
  "register-scheduledtask", "register-scheduledjob",
  // Interpreters whose program is an argument.
  "awk", "gawk", "mawk", "nawk", "osascript", "vim", "nvim", "vi", "emacs",
]);

const PYTHON = /^(python[0-9.]*|py|pythonw|pypy[0-9.]*)$/;

/** Interpreter options that take code (python covers python3, py and pypy). */
const INLINE_CODE: Record<string, readonly string[]> = {
  node: ["-e", "--eval", "-p", "--print"],
  nodejs: ["-e", "--eval", "-p", "--print"],
  bun: ["-e", "--eval", "-p", "--print"],
  tsx: ["-e", "--eval", "-p", "--print"],
  "ts-node": ["-e", "--eval", "-p", "--print"],
  python: ["-c"],
  perl: ["-e", "-E"],
  ruby: ["-e"],
  php: ["-r", "-B", "-R", "-E"],
  lua: ["-e"],
  luajit: ["-e"],
  rscript: ["-e"],
  julia: ["-e", "-E", "--eval", "--print"],
};
/** Programs that load modules from `data:` URLs, which carry their code inline. */
const DATA_URLS = new Set(["node", "nodejs", "bun", "deno", "tsx", "ts-node"]);
/** Python modules that run code given as an argument: `python -m timeit '<code>'`. */
const PYTHON_CODE_MODULES = new Set(["timeit", "code", "pdb", "cprofile", "profile", "trace", "runpy"]);

const GIT_VALUE_OPTIONS = new Set(["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env", "--attr-source"]);
const GIT_WRAPPERS = new Set(["filter-branch", "instaweb", "send-email"]);
/** git options that run a command or plant code that runs later. */
const GIT_EXEC_OPTIONS: Record<string, readonly string[]> = {
  rebase: ["-x", "--exec"],
  grep: ["-O", "--open-files-in-pager"],
  difftool: ["-x", "--extcmd"],
  clone: ["-u", "--upload-pack", "-c", "--config", "--template"],
  init: ["--template"],
  fetch: ["--upload-pack"],
  pull: ["--upload-pack"],
  "ls-remote": ["--upload-pack"],
  archive: ["--exec"],
  push: ["--receive-pack", "--exec"],
};
const FIND_EXEC = new Set(["-exec", "-execdir", "-ok", "-okdir"]);
/** GNU sed's `e` command and the `e` flag of `s`, which run their text as a shell command. */
const SED_EXECUTES = /(?:^|[\s;{}!,$\d/])e(?:\s|;|$)|s(.)(?:\\.|(?!\1).)*\1(?:\\.|(?!\1).)*\1[A-Za-z0-9]*e/;

interface Spec {
  /** Words that name the subcommand: 1 for `git status` (the default), 2 for `gh pr view`. */
  words?: number;
  /** Subcommands named by one more word: `npm run build`, `git remote add`. */
  deeper?: readonly string[];
  /** Subcommands followed by another command: `npm exec vitest`, `uv run pytest`. */
  runs?: readonly string[];
  /** Subcommands a rule must match word for word. */
  exact?: readonly string[];
  /** The subcommand may name a script or any other program (`pnpm vitest`): it is checked as a command too. */
  bins?: boolean;
}

/** Programs whose first words name what they do: a rule covers any arguments after those. */
const PROGRAMS: Record<string, Spec> = {
  git: { deeper: ["bisect", "config", "lfs", "notes", "reflog", "remote", "sparse-checkout", "submodule", "worktree"] },
  npm: { deeper: ["run", "run-script", "init", "create", "config", "pkg", "cache", "audit"], runs: ["exec", "x"] },
  pnpm: { deeper: ["run", "create", "config", "store"], runs: ["exec", "dlx"], bins: true },
  yarn: { deeper: ["run", "create", "config", "cache"], runs: ["exec", "dlx"], exact: ["workspace", "workspaces"], bins: true },
  bun: { deeper: ["run", "create", "pm"], runs: ["x"], bins: true },
  uv: { deeper: ["pip", "tool", "python", "cache", "self"], runs: ["run", "tool run"] },
  pip: {},
  pip3: {},
  pipx: { runs: ["run"] },
  poetry: { deeper: ["env", "self", "source", "cache"], runs: ["run"] },
  pipenv: { runs: ["run"] },
  pdm: { runs: ["run"] },
  hatch: { runs: ["run"] },
  cargo: {},
  go: { deeper: ["mod", "work", "tool"] },
  dotnet: { deeper: ["tool", "nuget", "workload", "dev-certs"], runs: ["tool run"] },
  deno: { deeper: ["task"] },
  gh: { words: 2 },
  vitest: {},
  playwright: {},
  vite: {},
  turbo: { deeper: ["run"] },
  nx: { deeper: ["run"] },
};
/** Programs whose arguments start with the command they run: `npx vitest run`. */
const RUNNERS = new Set(["npx", "pnpx", "bunx", "uvx"]);

const ALWAYS_HIGH = new Set([
  "rimraf", "format", "format-volume", "clear-disk", "initialize-disk", "diskpart", "shutdown", "reboot", "halt",
  "poweroff", "stop-computer", "restart-computer",
]);
/** Remove-Item and the aliases PowerShell gives it. */
const REMOVE_ITEM = new Set(["remove-item", "ri", "rm", "rmdir", "rd", "del", "erase"]);
const PUBLISHERS = new Set(["npm", "pnpm", "yarn", "bun", "cargo"]);

/** PowerShell reads these dashes as "-". */
const DASHES = new Set(["\u2013", "\u2014", "\u2015"]);

function isOption(word: string): boolean {
  return word.length > 1 && (word.startsWith("-") || DASHES.has(word.charAt(0)));
}

function dashed(word: string): string {
  return DASHES.has(word.charAt(0)) ? `-${word.slice(1)}` : word;
}

/** A word that can name a subcommand, script, package or module. */
function isName(word: string): boolean {
  return /^[A-Za-z0-9_@.][\w@.:/+-]*$/.test(word);
}

/** Whether an argument is `flag`, carries its value (`--eval=...`, `-ccode`) or bundles it (`-Bc`). */
function usesOption(arg: string, flag: string): boolean {
  if (arg === flag) return true;
  if (flag.startsWith("--")) return arg.startsWith(`${flag}=`);
  return arg.startsWith(flag) || (/^-[A-Za-z]+$/.test(arg) && arg.includes(flag.slice(1)));
}

/**
 * The program's base name in lower case without .exe, .com, .cmd, .bat or .ps1, and the name a
 * rule uses. A program named by its path keeps the path there, so that a rule for `git status`
 * does not cover `./git status`.
 */
function programOf(word: string): { base: string; name: string } {
  const lower = word.toLowerCase();
  const slash = Math.max(lower.lastIndexOf("/"), lower.lastIndexOf("\\"));
  const strip = (s: string) => s.replace(/\.(exe|com|cmd|bat|ps1)$/, "");
  const base = strip(lower.slice(slash + 1));
  return { base, name: slash < 0 ? base : strip(lower.replace(/\\/g, "/")) };
}

/** A word of a signature: bare when plain, else JSON-quoted, so different word lists never collide. */
function quoteWord(word: string): string {
  return /^[^\s"]+$/.test(word) ? word : JSON.stringify(word);
}

function exactSignature(name: string, args: string[]): string {
  return [name, ...args].map(quoteWord).join(" ");
}

const SIGNATURE_MAX = 512;

/** Keeps very long exact signatures short and still exact. */
function capped(signature: string): string {
  if (signature.length <= SIGNATURE_MAX) return signature;
  return `${signature.slice(0, 200)}... sha256:${createHash("sha256").update(signature).digest("hex")}`;
}

/** How many programs deep a command may run another (`npx`, `uv run`, `python -m`, ...). */
const MAX_NESTING = 4;

function judge(words: string[], dialect: Dialect, depth: number): Judged {
  const head = words[0];
  if (head === undefined || head === "" || isOption(head)) return { reason: WHY.empty };
  if (ASSIGNMENT.test(head)) return { reason: WHY.assignment };
  if (STATEMENTS.has(head.toLowerCase())) return { reason: WHY.statement };
  // zsh expands `=git` to git's path.
  if (head.startsWith("=")) return { reason: WHY.expand };
  if (/[*?[\]]/.test(head)) return { reason: WHY.pattern };
  const { base, name } = programOf(head);
  if (base === "") return { reason: WHY.empty };
  const args = words.slice(1);
  if (runsOtherCode(base, args)) return { reason: WHY.wrapper };
  const high = destroysOrReachesFar(base, args, dialect);

  const runner = runnerSplit(base, args);
  if (runner) {
    const rest = runner.rest[0] === "--" ? runner.rest.slice(1) : runner.rest;
    const inner = rest[0];
    if (inner !== undefined && isName(inner)) {
      if (depth >= MAX_NESTING) return { reason: WHY.wrapper };
      const nested = judge(rest, dialect, depth + 1);
      if ("reason" in nested) return nested;
      return { signature: [name, ...runner.lead].map(quoteWord).concat(nested.signature).join(" "), high: high || nested.high };
    }
    // The runner's own options come first, so where its command starts is unknown.
    const hidden = hiddenCommand(rest, dialect);
    return "reason" in hidden ? hidden : { signature: exactSignature(name, args), high: high || hidden.high };
  }

  const spec = lookup(PROGRAMS, base);
  const sub = spec ? subcommandOf(spec, args) : null;
  if (!sub && (RUNNERS.has(base) || PYTHON.test(base) || spec?.runs || spec?.bins)) {
    // `npm -w app exec -- ...`, `pnpm --filter app ...`: options hide where a command starts.
    const hidden = hiddenCommand(args, dialect);
    return "reason" in hidden ? hidden : { signature: exactSignature(name, args), high: high || hidden.high };
  }
  let nestedHigh = false;
  if (spec?.bins && sub?.length === 1) {
    // `pnpm bash -c ...`, `yarn node -e ...`: the subcommand may be a program of its own.
    if (depth >= MAX_NESTING) return { reason: WHY.wrapper };
    const nested = judge(args, dialect, depth + 1);
    if ("reason" in nested) return nested;
    nestedHigh = nested.high;
  }
  // Further arguments are free only while none of them reaches outside the work folder.
  const signature = sub && !args.some(reachesOutside) ? [name, ...sub].map(quoteWord).join(" ") : exactSignature(name, args);
  return { signature, high: high || nestedHigh };
}

/**
 * An argument naming a path outside the work folder (absolute, a drive, `~`, `..`, a URL) or a
 * global install location: `--output=/home/me/.bashrc`, `-o ~/bin/ls`, `--prefix=../other`, `-g`.
 */
function reachesOutside(arg: string): boolean {
  if (/^(-g|--global|--location=global|--user|--system)$/.test(arg)) return true;
  return /(?:^|[=:]|^-[A-Za-z])(?:[/\\~]|[A-Za-z]:)|(?:^|[/\\=:])\.\.(?:[/\\]|$)/.test(arg);
}

/** The words naming the subcommand, or null when the rule must match the command word for word. */
function subcommandOf(spec: Spec, args: string[]): string[] | null {
  const first = args[0];
  if (first === undefined || !isName(first) || spec.exact?.includes(first)) return null;
  const count = Math.max(spec.words ?? 1, spec.deeper?.includes(first) ? 2 : 1);
  const sub = args.slice(0, count);
  return sub.length === count && sub.every(isName) ? sub : null;
}

/** Where a runner's own command starts: `npx vitest`, `npm exec -- tsc`, `python -m pytest`. */
function runnerSplit(base: string, args: string[]): { lead: string[]; rest: string[] } | null {
  if (RUNNERS.has(base)) return { lead: [], rest: args };
  if (PYTHON.test(base) && args[0] === "-m") return { lead: ["-m"], rest: args.slice(1) };
  for (const sub of lookup(PROGRAMS, base)?.runs ?? []) {
    const lead = sub.split(" ");
    if (lead.every((w, k) => args[k] === w)) return { lead, rest: args.slice(lead.length) };
  }
  return null;
}

/** A word naming a wrapper, an interpreter or an inline-code option. */
function namesOtherCode(word: string): boolean {
  const { base } = programOf(word);
  return WRAPPERS.has(base) || PYTHON.test(base) || lookup(INLINE_CODE, base) !== undefined || /^(-[ecp]|--eval|--print|--call)(=|$)/.test(word);
}

/** How many words a command whose start is unknown may have. */
const MAX_HIDDEN = 64;

/**
 * Reads every word that could start a runner's command as that command: a wrapper anywhere makes
 * the whole not simple, and any reading that can destroy work or reach far makes it high risk.
 */
function hiddenCommand(words: string[], dialect: Dialect): { reason: string } | { high: boolean } {
  if (words.length > MAX_HIDDEN) return { reason: WHY.long };
  let high = false;
  for (let k = 0; k < words.length; k++) {
    const word = words[k]!;
    if (namesOtherCode(word)) return { reason: WHY.wrapper };
    if (isOption(word)) continue;
    const base = programOf(word).base;
    const rest = words.slice(k + 1);
    if (runsOtherCode(base, rest)) return { reason: WHY.wrapper };
    high ||= destroysOrReachesFar(base, rest, dialect);
  }
  return { high };
}

function runsOtherCode(base: string, args: string[]): boolean {
  // `command -v` only looks a program up.
  if (WRAPPERS.has(base)) return !(base === "command" && (args[0] === "-v" || args[0] === "-V"));
  const inline = lookup(INLINE_CODE, PYTHON.test(base) ? "python" : base);
  if (inline && args.some((a) => inline.some((flag) => usesOption(a, flag)))) return true;
  if (DATA_URLS.has(base) && args.some((a) => /data:/i.test(a))) return true;
  if (PYTHON.test(base) && args.some((a, k) => a === "-m" && PYTHON_CODE_MODULES.has((args[k + 1] ?? "").toLowerCase()))) return true;
  switch (base) {
    case "git":
      return gitRunsOtherCode(args);
    case "find":
      return args.some((a) => FIND_EXEC.has(a));
    case "sed":
    case "gsed":
      return args.some((a) => SED_EXECUTES.test(a));
    case "tar":
    case "bsdtar":
      return args.some(
        (a) =>
          usesOption(a, "-I") || usesOption(a, "-F") || /^--(to-command|checkpoint-action|use-compress-program|rsh-command|info-script|new-volume-script)/.test(a),
      );
    case "rsync":
      return args.some((a) => /^--(rsh|rsync-path)/.test(a) || (/^-[A-Za-z]+$/.test(a) && a.includes("e")));
    case "npm":
    case "pnpm":
    case "yarn":
    case "bun":
      return args.some((a) => /script-shell|node-options/i.test(a) || usesOption(a, "--call") || a === "-c" || a === "--shell-mode");
    case "go":
      return args.some((a) => /^--?(exec|toolexec)(=|$)/.test(a)) || (args[0] === "env" && args.some((a) => a === "-w" || a === "-u"));
    case "cargo":
      return args.some((a) => usesOption(a, "--config"));
    case "deno":
      return args[0] === "eval";
    case "wget":
      return args.some((a) => a === "-e" || /^--(use-askpass|execute)/.test(a));
    case "man":
      return args.some((a) => a === "-P" || a === "-H" || /^--(pager|html)/.test(a));
    case "zip":
      return args.some((a) => a === "-TT" || a.startsWith("--unzip-command"));
    case "sqlite3":
      return args.some((a) => /\.(shell|system)\b/.test(a));
    default:
      return false;
  }
}

/** git's global options, its subcommand and the arguments after it. */
function gitSplit(args: string[]): { globals: string[]; sub: string | undefined; rest: string[] } {
  const globals: string[] = [];
  let i = 0;
  while (i < args.length && isOption(args[i]!)) {
    globals.push(args[i]!);
    i += GIT_VALUE_OPTIONS.has(args[i]!) ? 2 : 1;
  }
  return { globals, sub: args[i], rest: args.slice(i + 1) };
}

function gitRunsOtherCode(args: string[]): boolean {
  const { globals, sub, rest } = gitSplit(args);
  if (globals.some((g) => g === "-c" || g.startsWith("--config-env") || g.startsWith("--exec-path"))) return true;
  if (sub === undefined) return false;
  if (GIT_WRAPPERS.has(sub)) return true;
  if ((sub === "submodule" && rest.includes("foreach")) || (sub === "bisect" && rest.includes("run"))) return true;
  const options = lookup(GIT_EXEC_OPTIONS, sub) ?? [];
  return rest.some((a) => options.some((o) => usesOption(a, o)));
}

// The risk rating has to name the destructive git commands it rates, so the source scan in the
// unit tests skips it.
// banned-git-guard:start
function gitDestroysOrReachesFar(args: string[]): boolean {
  const { sub, rest } = gitSplit(args);
  const has = (...flags: string[]) => rest.some((a) => flags.includes(a));
  const letters = rest.filter((a) => /^-[A-Za-z]+$/.test(a)).join("");
  switch (sub) {
    case "push":
    case "clean":
    case "stash":
    case "filter-branch":
      return true;
    case "reset":
      return has("--hard");
    case "checkout":
      // `checkout -- <path>` and `checkout .` throw changes away.
      return has("-f", ".") || rest.some((a) => a.startsWith("--"));
    case "restore":
      // Only `--staged` leaves the files alone.
      return !has("--staged", "-S") || has("--worktree", "-W");
    case "switch":
      return has("-f", "--force", "--discard-changes", "-C");
    case "branch":
      return letters.includes("D") || ((letters.includes("d") || has("--delete")) && (letters.includes("f") || has("--force")));
    case "rm":
      return letters.includes("f") || has("--force");
    default:
      return false;
  }
}

/** Commands that can destroy work or reach far are high risk: they ask every time, and only once. */
function destroysOrReachesFar(base: string, args: string[], dialect: Dialect): boolean {
  if (ALWAYS_HIGH.has(base) || base.startsWith("mkfs")) return true;
  const bundles = args.filter((a) => /^-[A-Za-z]+$/.test(a)).join(" ");
  if (base === "rm" && (/r/i.test(bundles) || args.includes("--recursive")) && (/f/i.test(bundles) || args.includes("--force"))) return true;
  // In PowerShell, rm, rd, del and the rest are Remove-Item, and -r is -Recurse.
  if (dialect !== "bash" && REMOVE_ITEM.has(base) && args.some(recursesPowerShell)) return true;
  if ((base === "rd" || base === "rmdir" || base === "del" || base === "erase") && args.some((a) => a.toLowerCase() === "/s")) return true;
  if (PUBLISHERS.has(base) && args.some((a) => a === "publish" || a === "unpublish")) return true;
  switch (base) {
    case "git":
      return gitDestroysOrReachesFar(args);
    case "find":
      return args.includes("-delete");
    case "chmod":
    case "chown":
    case "chgrp":
      return /R/.test(bundles) || args.includes("--recursive");
    case "dd":
      return args.some((a) => a.startsWith("of="));
    default:
      return false;
  }
}
// banned-git-guard:end

function recursesPowerShell(arg: string): boolean {
  const flag = dashed(arg).toLowerCase().split(":")[0] ?? "";
  return flag.length >= 2 && "-recurse".startsWith(flag);
}
