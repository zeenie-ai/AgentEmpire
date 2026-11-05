import { createHash } from "node:crypto";
import type { Risk } from "../protocol/objects.js";

/**
 * What a shell command is, for approval rules and approval modes. Only a simple command may pass
 * without asking: one program with plain arguments, or in bash a few of them joined with `&&`.
 * Each may discard its output (`2>&1`, `> /dev/null`) or send it through a read-only filter
 * (`| tail -20`), and a chain may start in a folder (`cd app && npm test`). Anything else
 * (other chains and pipes, substitutions, redirections into files, environment assignments,
 * programs that run other commands or code, commands that change the shell or settings outside
 * the work folder) always asks and rates high risk. The reading is conservative: whatever the
 * Town Hall cannot be sure of counts as not simple.
 */
export interface CommandShape {
  /** Simple, as above: the only kind a rule or the approval mode may pass. */
  simple: boolean;
  /** Why the command is not simple; null when it is. */
  reason: string | null;
  /**
   * What a task or agent rule made from the command covers. A program with known subcommands
   * gives its subcommand ("git status", "npm run build", "npx vitest run") and covers any further
   * arguments that stay inside the work folder; any other command gives all its words and covers
   * only itself. A chain gives its commands' in order ("npm run build && npm test"). Filters,
   * discarded output and the leading `cd` are left out, so `npm test 2>&1 | tail` is `npm test`.
   */
  signature: string;
  /** True when the signature leaves no argument free: a rule from it covers only these words. */
  exact: boolean;
  /** The folder a leading `cd <folder> &&` moves to, for the caller to judge as a path; else null. */
  folder: string | null;
  /** "high" when the command is not simple, or can destroy work or reach far. */
  risk: Risk | undefined;
}

/** The shell a command is written for. "any" must read the same in bash and in PowerShell. */
export type Dialect = "bash" | "powershell" | "any";

const WHY = {
  text: "the request has no command text",
  empty: "there is no program to run",
  several: "it runs several commands",
  pipe: "it pipes into a command that is not a plain output filter",
  redirect: "it redirects input or output",
  expand: "it substitutes or expands text",
  group: "it groups commands or code",
  comment: "it contains a comment",
  quoting: "its quoting or escaping is ambiguous",
  characters: "it contains unusual characters",
  assignment: "it sets environment variables first",
  statement: "it is a shell statement",
  state: "it changes the shell for the commands after it",
  folder: "it changes folders other than once, at the start, to a folder it names",
  pattern: "its program is a file pattern",
  wrapper: "it runs another command or inline code",
  settings: "it changes settings outside the work folder",
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
  const parsed = parse(script, dialect, false);
  const judged = "reason" in parsed ? parsed : judgeScript(parsed.pipelines, dialect);
  if ("reason" in judged) return notSimple(judged.reason);
  return {
    simple: true,
    reason: null,
    signature: capped(judged.signature),
    exact: judged.exact,
    folder: judged.folder,
    risk: judged.high ? "high" : undefined,
  };
}

function notSimple(reason: string): CommandShape {
  return { simple: false, reason, signature: `<${reason}>`, exact: true, folder: null, risk: "high" };
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

// ---------- splitting into commands and words ----------

// Control characters, invisible and bidirectional formatting and Unicode spaces: a card would
// show the command as something it is not, and the shells disagree on them.
const UNUSUAL =
  /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u00a0\u00ad\u034f\u061c\u115f\u1160\u1680\u17b4\u17b5\u180e\u2000-\u200f\u2028-\u202f\u205f-\u206f\u2800\u3000\u3164\ufeff\uffa0\ufff9-\ufffb]/;
/** Curly quotes, which PowerShell reads as quotes. */
const CURLY_QUOTES = /[\u2018-\u201f]/;

/** A command's words, then the words of each output filter it pipes into. */
type Pipeline = string[][];
type Parsed = { pipelines: Pipeline[] } | { reason: string };
type Lexed = { words: string[] } | { reason: string };

function oneOf(ch: string, set: string): boolean {
  return ch !== "" && set.includes(ch);
}

/** One plain command's words, with no operators, redirections or here-documents (Codex's argv). */
function lex(text: string, dialect: Dialect): Lexed {
  const parsed = parse(text, dialect, true);
  if ("reason" in parsed) return parsed;
  return { words: parsed.pipelines[0]?.[0] ?? [] };
}

/**
 * Splits a script into `&&`-joined pipelines of unquoted words, or says why it is not simple.
 * `strict` allows a single plain command only. Otherwise bash may chain with `&&`, every dialect
 * may pipe (judgeScript checks that each later stage is a filter), and the redirections that
 * only discard or merge output are taken off.
 */
function parse(text: string, dialect: Dialect, strict: boolean): Parsed {
  if (UNUSUAL.test(text) || (dialect !== "bash" && CURLY_QUOTES.test(text))) return { reason: WHY.characters };
  const pipelines: Pipeline[] = [];
  let pipeline: Pipeline = [];
  let stage: string[] = [];
  let word = "";
  let open = false;
  /** The word holds a quote or an escape, so it is no stream number (`"2">x`). */
  let quoted = false;
  const endWord = () => {
    if (open) stage.push(word);
    word = "";
    open = false;
    quoted = false;
  };
  const endStage = (): boolean => {
    endWord();
    if (stage.length === 0) return false;
    pipeline.push(stage);
    stage = [];
    return true;
  };
  let i = 0;
  while (i < text.length) {
    const c = text.charAt(i);
    const next = text.charAt(i + 1);
    if (c === " " || c === "\t") {
      endWord();
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
      quoted = true;
      i = j + 1;
    } else if (c === '"') {
      const doc = strict || dialect !== "bash" ? null : hereDocument(text, i);
      if (doc && "reason" in doc) return doc;
      if (doc) {
        word += doc.value;
        open = true;
        quoted = true;
        i = doc.end;
        continue;
      }
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
      quoted = true;
      i = j + 1;
    } else if (c === "\\" && dialect !== "powershell") {
      // An escape in bash, a plain character in PowerShell: "any" cannot tell which.
      if (dialect === "any" || next === "" || next === "\n" || next === "\r") return { reason: WHY.quoting };
      word += next;
      open = true;
      quoted = true;
      i += 2;
    } else if (c === "&" && next === "&" && !strict && dialect === "bash") {
      if (!endStage()) return { reason: WHY.several };
      pipelines.push(pipeline);
      pipeline = [];
      i += 2;
    } else if (c === "|" && next !== "|" && next !== "&" && !strict) {
      if (!endStage()) return { reason: WHY.several };
      i++;
    } else if (c === ">" || c === "<" || (c === "&" && next === ">" && dialect === "bash")) {
      if (strict) return { reason: WHY.redirect };
      // An unquoted number right before the operator names the stream; any other word ends there.
      let stream: string | null = null;
      if (c !== "&" && open && !quoted && (/^\d+$/.test(word) || (dialect === "powershell" && word === "*"))) {
        stream = word;
        word = "";
        open = false;
      } else {
        endWord();
      }
      const end = redirection(text, i, stream, dialect);
      if (typeof end !== "number") return end;
      i = end;
    } else if (oneOf(c, ";&|\n\r")) {
      return { reason: WHY.several };
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
  endWord();
  if (stage.length > 0) {
    pipeline.push(stage);
  } else if (pipeline.length > 0 || pipelines.length > 0) {
    // A trailing `|` or `&&`.
    return { reason: WHY.several };
  }
  pipelines.push(pipeline.length > 0 ? pipeline : [[]]);
  // PowerShell's stop-parsing token hands the rest of the line over unparsed.
  if (dialect !== "bash" && pipelines.some((p) => p.some((s) => s.includes("--%")))) return { reason: WHY.quoting };
  return { pipelines };
}

/**
 * A redirection at `i` (past its stream number, if any). Only those that discard or merge
 * output pass: `2>&1`, `>&2`, `> /dev/null`, `2>nul`, `&> /dev/null` and `< /dev/null` in bash,
 * `2>&1` and `> $null` in PowerShell, `2>&1` alone where the shell is unknown. Returns where the
 * command goes on.
 */
function redirection(text: string, i: number, stream: string | null, dialect: Dialect): number | { reason: string } {
  const refused = { reason: WHY.redirect };
  let j = i;
  const both = text.charAt(j) === "&";
  if (both) j++;
  const op = text.charAt(j);
  j++;
  if (op === "<") {
    if (both || dialect !== "bash" || oneOf(text.charAt(j), "<>&(") || (stream !== null && stream !== "0")) return refused;
    const target = targetAt(text, j);
    return isNullDevice(target.word, dialect) ? target.end : refused;
  }
  const append = text.charAt(j) === ">";
  if (append) j++;
  if (oneOf(text.charAt(j), "|(")) return refused;
  if (text.charAt(j) === "&" && !both && !append) {
    // One stream copied into another; the copy must end the word.
    const to = text.charAt(j + 1);
    if (j + 2 < text.length && !oneOf(text.charAt(j + 2), " \t|&;<>\n\r")) return refused;
    const from = stream ?? "1";
    const ok =
      dialect === "bash"
        ? (from === "1" && to === "2") || (from === "2" && to === "1")
        : dialect === "powershell"
          ? to === "1" && (from === "2" || from === "*")
          : from === "2" && to === "1";
    return ok ? j + 2 : refused;
  }
  if (stream !== null && stream !== "1" && stream !== "2" && !(dialect === "powershell" && stream === "*")) return refused;
  const target = targetAt(text, j);
  return isNullDevice(target.word, dialect) ? target.end : refused;
}

/** The raw word after a redirection operator; quotes and escapes are kept, so they never match. */
function targetAt(text: string, i: number): { word: string; end: number } {
  let j = i;
  while (text.charAt(j) === " " || text.charAt(j) === "\t") j++;
  const start = j;
  while (j < text.length && !oneOf(text.charAt(j), " \t;&|<>()\n\r")) j++;
  return { word: text.slice(start, j), end: j };
}

function isNullDevice(word: string, dialect: Dialect): boolean {
  if (dialect === "bash") return word === "/dev/null" || /^nul$/i.test(word);
  if (dialect === "powershell") return /^\$null$/i.test(word);
  return false;
}

/**
 * Claude Code's commit messages: `"$(cat <<'EOF'` and lines up to `EOF`, then `)"`. The
 * here-document's delimiter is quoted, so bash takes its text as written; the word is that text
 * without its trailing newlines, as the substitution gives it. Null when the word is not one.
 */
function hereDocument(text: string, i: number): { value: string; end: number } | { reason: string } | null {
  const start = /"\$\(cat <<[ \t]*(['"])([A-Za-z_][A-Za-z0-9_]*)\1\n/y;
  start.lastIndex = i;
  const m = start.exec(text);
  if (!m) return null;
  const delimiter = m[2]!;
  const bodyStart = start.lastIndex;
  let line = bodyStart;
  for (;;) {
    const nl = text.indexOf("\n", line);
    if (nl < 0) return { reason: WHY.quoting };
    if (text.slice(line, nl) === delimiter) {
      const close = /[ \t\n]*\)"/y;
      close.lastIndex = nl + 1;
      const body = text.slice(bodyStart, line);
      if (!close.exec(text) || body.includes("\r")) return { reason: WHY.quoting };
      return { value: body.replace(/\n+$/, ""), end: close.lastIndex };
    }
    line = nl + 1;
  }
}

// ---------- judging the words ----------

type Judged = { signature: string; high: boolean; exact: boolean } | { reason: string };

/** How many commands a chain, or filters a pipeline, may hold. */
const MAX_PARTS = 16;

/**
 * A chain of pipelines. Each pipeline's first command is judged as a command; every later one
 * must be a read-only output filter. A leading `cd <folder>` is taken off and reported, like the
 * folder of a Codex command, for the caller to judge as a path.
 */
function judgeScript(pipelines: Pipeline[], dialect: Dialect): { signature: string; high: boolean; exact: boolean; folder: string | null } | { reason: string } {
  if (pipelines.length > MAX_PARTS || pipelines.some((p) => p.length > MAX_PARTS)) return { reason: WHY.long };
  let parts = pipelines;
  let folder: string | null = null;
  const first = pipelines[0]![0]!;
  if (pipelines.length > 1 && first[0] === "cd") {
    // `cd -`, `cd +1` and a bare `cd` go to places the words do not name.
    const target = first[1];
    if (pipelines[0]!.length > 1 || first.length !== 2 || target === undefined || target === "" || /^[-+]/.test(target)) return { reason: WHY.folder };
    folder = target;
    parts = pipelines.slice(1);
  }
  const signatures: string[] = [];
  let high = false;
  let exact = true;
  for (const [command, ...filters] of parts) {
    if (pipelines.length > 1 && command![0] === "cd") return { reason: WHY.folder };
    const judged = judge(command!, dialect, 0);
    if ("reason" in judged) return judged;
    if (!filters.every((f) => isFilter(f, dialect))) return { reason: WHY.pipe };
    signatures.push(judged.signature);
    high ||= judged.high;
    exact &&= judged.exact;
  }
  return { signature: signatures.join(" && "), high, exact, folder };
}

interface FilterSpec {
  /** Short options that take no value. */
  flags: string;
  /** Short options that take a value, attached or as the next word. */
  values: string;
  /** Long options (without `--`) that take no value, or only an attached one. */
  long: readonly string[];
  /** Long options that take a value. */
  longValues: readonly string[];
  /** Operands it may have; none of them is ever a file (grep's pattern, tr's sets). */
  operands: number;
  /** Takes counts like `-20`. */
  counts?: boolean;
}

/** Read-only filters for a pipeline's output, with every option that could name a file left out. */
const FILTERS: Record<string, FilterSpec> = {
  head: { flags: "qvz", values: "nc", long: ["quiet", "silent", "verbose", "zero-terminated"], longValues: ["lines", "bytes"], operands: 0, counts: true },
  tail: { flags: "qvzfF", values: "nc", long: ["quiet", "silent", "verbose", "zero-terminated", "follow", "retry"], longValues: ["lines", "bytes"], operands: 0, counts: true },
  grep: {
    flags: "EFGPiywxvcLloqsbHhnTZzaUI",
    values: "eABCm",
    long: [
      "extended-regexp", "fixed-strings", "basic-regexp", "perl-regexp", "ignore-case", "no-ignore-case", "word-regexp",
      "line-regexp", "null-data", "no-messages", "invert-match", "count", "color", "colour", "files-without-match",
      "files-with-matches", "only-matching", "quiet", "silent", "byte-offset", "with-filename", "no-filename",
      "line-number", "line-buffered", "initial-tab", "null", "text",
    ],
    longValues: ["regexp", "max-count", "after-context", "before-context", "context", "label", "binary-files"],
    operands: 1,
    counts: true,
  },
  sort: {
    flags: "bcCdfghiMmnRrsuVz",
    values: "ktS",
    long: [
      "ignore-leading-blanks", "dictionary-order", "ignore-case", "general-numeric-sort", "ignore-nonprinting",
      "month-sort", "human-numeric-sort", "numeric-sort", "random-sort", "reverse", "version-sort", "check", "merge",
      "stable", "unique", "zero-terminated", "debug",
    ],
    longValues: ["key", "field-separator", "buffer-size", "parallel", "sort"],
    operands: 0,
  },
  uniq: {
    flags: "cdDiuz",
    values: "fsw",
    long: ["count", "repeated", "all-repeated", "group", "ignore-case", "unique", "zero-terminated"],
    longValues: ["skip-fields", "skip-chars", "check-chars"],
    operands: 0,
  },
  wc: { flags: "clmwL", values: "", long: ["bytes", "chars", "lines", "words", "max-line-length"], longValues: [], operands: 0 },
  cut: {
    flags: "nsz",
    values: "bcdf",
    long: ["only-delimited", "complement", "zero-terminated"],
    longValues: ["bytes", "characters", "fields", "delimiter", "output-delimiter"],
    operands: 0,
  },
  tr: { flags: "cCdst", values: "", long: ["complement", "delete", "squeeze-repeats", "truncate-set1"], longValues: [], operands: 2 },
  cat: {
    flags: "AbeEnstTuv",
    values: "",
    long: ["show-all", "number-nonblank", "show-ends", "number", "squeeze-blank", "show-tabs", "show-nonprinting"],
    longValues: [],
    operands: 0,
  },
};

/** A later stage of a pipeline that only reads the output before it: no files, no programs. */
function isFilter(words: string[], dialect: Dialect): boolean {
  const [name = "", ...args] = words;
  if (dialect === "powershell") return isPowerShellFilter(name.toLowerCase(), args);
  const spec = dialect === "bash" ? lookup(FILTERS, name) : undefined;
  if (!spec) return false;
  let operands = 0;
  let patterns = 0;
  for (let k = 0; k < args.length; k++) {
    const a = args[k]!;
    if (a === "--") {
      operands += args.length - k - 1;
      break;
    }
    if (a.startsWith("--")) {
      const [option = "", ...value] = a.slice(2).split("=");
      if (spec.long.includes(option)) continue;
      if (!spec.longValues.includes(option)) return false;
      if (value.length === 0) k++;
      if (option === "regexp") patterns++;
      continue;
    }
    if (a.startsWith("-") && a.length > 1) {
      if (spec.counts && /^-\d+$/.test(a)) continue;
      for (let j = 1; j < a.length; j++) {
        const ch = a.charAt(j);
        if (spec.flags.includes(ch)) continue;
        if (!spec.values.includes(ch)) return false;
        if (j === a.length - 1) k++;
        if (ch === "e") patterns++;
        break;
      }
      continue;
    }
    operands++;
  }
  return operands <= (patterns > 0 ? 0 : spec.operands);
}

/** `| Select-Object -First 20` and the like: counts, switches and nothing that names a file. */
function isPowerShellFilter(name: string, args: string[]): boolean {
  switch (name) {
    case "select-object":
    case "select":
      for (let k = 0; k < args.length; k++) {
        const [flag = "", ...value] = dashed(args[k]!).toLowerCase().split(":");
        if (!["-first", "-last", "-skip", "-skiplast"].includes(flag)) return false;
        const count = value.length > 0 ? value.join(":") : args[++k];
        if (count === undefined || !/^\d+$/.test(count)) return false;
      }
      return true;
    case "measure-object":
    case "measure":
      return args.every((a) => ["-line", "-word", "-character", "-ignorewhitespace"].includes(dashed(a).toLowerCase()));
    case "out-null":
      return args.length === 0;
    default:
      return false;
  }
}

const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=/;
const STATEMENTS = new Set([
  "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "select", "function",
  "coproc", "[[", "]]", "!", "foreach", "switch", "try", "catch", "finally", "param", "begin", "process", "end",
  "filter", "workflow", "class", "enum", "using", "data", "configuration",
]);
/**
 * Builtins that change the shell for the commands after them (variables, aliases, options, the
 * folder) or evaluate a name's array subscript, which can run a command: `read 'v[$(id)]'`.
 */
const SHELL_STATE = new Set([
  "export", "declare", "typeset", "local", "readonly", "unset", "set", "shopt", "alias", "unalias", "hash", "let",
  "read", "mapfile", "readarray", "getopts", "umask", "ulimit", "pushd", "popd", "shift", "bind", "compgen",
  "complete", "compopt",
  // zsh.
  "setopt", "unsetopt", "unhash", "disable", "autoload", "zmodload", "zstyle", "bindkey", "functions", "integer",
  "float", "vared", "zle", "zparseopts", "private",
  // PowerShell.
  "set-variable", "sv", "new-variable", "nv", "remove-variable", "rv", "clear-variable", "clv", "set-alias", "sal",
  "new-alias", "nal", "set-location", "sl", "chdir", "push-location", "pop-location", "set-item", "si",
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
  "concurrently", "nodemon", "hyperfine", "mise", "asdf", "fc", "enable",
  // zsh's precommand modifiers and repeaters.
  "noglob", "nocorrect", "repeat", "emulate", "sched",
  // PowerShell.
  "iex", "invoke-expression", "icm", "invoke-command", "start-process", "saps", "start-job", "sajb",
  "start-threadjob", "invoke-item", "ii", "add-type", "invoke-wmimethod", "invoke-cimmethod",
  "register-scheduledtask", "register-scheduledjob", "import-module", "ipmo", "enter-pssession", "new-pssession",
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
/**
 * npm settings that name a program to run or a file of settings, which can name one in turn:
 * `npm test --script-shell=./evil.sh`, `npm edit x --editor=./evil.sh`.
 */
const NPM_PROGRAM_SETTINGS = [
  "--script-shell", "--node-options", "--shell", "--editor", "--browser", "--viewer", "--git", "--node-gyp",
  "--userconfig", "--globalconfig", "--init-module", "--onload-script",
];

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
  "send-pack": ["--receive-pack", "--exec"],
};
const FIND_EXEC = new Set(["-exec", "-execdir", "-ok", "-okdir"]);

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
  // `git checkout <word>` switches branches or throws away a file's changes, by what the word names.
  git: {
    deeper: ["bisect", "config", "lfs", "notes", "p4", "reflog", "remote", "sparse-checkout", "submodule", "subtree", "svn", "worktree"],
    exact: ["checkout"],
  },
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
  // A Deno program's permissions are its arguments: a rule for one run must not cover another.
  deno: { deeper: ["task"], exact: ["run", "test", "serve", "compile", "bench", "install", "repl", "x"] },
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
  // Processes by name, everyone's: other agents' harnesses, your programs, the Town Hall.
  "pkill", "killall", "taskkill", "tskill", "skill",
]);
/** Remove-Item and the aliases PowerShell gives it. */
const REMOVE_ITEM = new Set(["remove-item", "ri", "rm", "rmdir", "rd", "del", "erase"]);
/** Stop-Process and its aliases. */
const STOP_PROCESS = new Set(["stop-process", "spps", "kill"]);
/** Words that publish to a package registry, or take a published version back. */
const PUBLISHERS: Record<string, readonly string[]> = {
  npm: ["publish", "unpublish", "deprecate"],
  pnpm: ["publish", "unpublish", "deprecate"],
  yarn: ["publish", "unpublish"],
  bun: ["publish"],
  cargo: ["publish", "yank"],
  poetry: ["publish"],
  uv: ["publish"],
  hatch: ["publish"],
  pdm: ["publish"],
  flit: ["publish"],
  deno: ["publish"],
  twine: ["upload"],
  gem: ["push", "yank"],
};
/** systemctl and loginctl verbs that end or suspend the session or the machine. */
const POWER_VERBS = new Set(["poweroff", "reboot", "halt", "kexec", "suspend", "hibernate", "hybrid-sleep", "soft-reboot", "rescue", "emergency", "kill-user", "kill-session", "terminate-user", "terminate-session"]);

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

/** A long option written as a prefix of `flag`, which git, getopt_long and nopt all accept: `--upl` for `--upload-pack`. */
function longPrefix(arg: string, flag: string): boolean {
  const name = arg.split("=")[0]!;
  return flag.startsWith("--") && name.startsWith("--") && name.length > 2 && flag.startsWith(name);
}

/** usesOption, also taking any prefix of a long flag for the flag itself. */
function usesOptionOrPrefix(arg: string, flag: string): boolean {
  return usesOption(arg, flag) || longPrefix(arg, flag);
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
  const lower = head.toLowerCase();
  if (STATEMENTS.has(lower)) return { reason: WHY.statement };
  if (SHELL_STATE.has(lower)) return { reason: WHY.state };
  // zsh runs `- cmd` as a login command and expands `=git` to git's path.
  if (head === "-") return { reason: WHY.wrapper };
  if (head.startsWith("=")) return { reason: WHY.expand };
  if (/[*?[\]]/.test(head)) return { reason: WHY.pattern };
  const { base, name } = programOf(head);
  if (base === "") return { reason: WHY.empty };
  const args = words.slice(1);
  if (runsOtherCode(base, args)) return { reason: WHY.wrapper };
  if (evaluatesNames(base, args)) return { reason: WHY.expand };
  if (changesSettings(base, args)) return { reason: WHY.settings };
  const high = destroysOrReachesFar(base, args, dialect);

  const runner = runnerSplit(base, args);
  if (runner) {
    const rest = runner.rest[0] === "--" ? runner.rest.slice(1) : runner.rest;
    const inner = rest[0];
    if (inner !== undefined && isName(inner)) {
      if (depth >= MAX_NESTING) return { reason: WHY.wrapper };
      const nested = judge(rest, dialect, depth + 1);
      if ("reason" in nested) return nested;
      return {
        signature: [name, ...runner.lead].map(quoteWord).concat(nested.signature).join(" "),
        high: high || nested.high,
        exact: nested.exact,
      };
    }
    // The runner's own options come first, so where its command starts is unknown.
    const hidden = hiddenCommand(rest, dialect);
    return "reason" in hidden ? hidden : { signature: exactSignature(name, args), high: high || hidden.high, exact: true };
  }

  const spec = lookup(PROGRAMS, base);
  const sub = spec ? subcommandOf(spec, args) : null;
  if (!sub && (RUNNERS.has(base) || PYTHON.test(base) || spec?.runs || spec?.bins)) {
    // `npm -w app exec -- ...`, `pnpm --filter app ...`: options hide where a command starts.
    const hidden = hiddenCommand(args, dialect);
    return "reason" in hidden ? hidden : { signature: exactSignature(name, args), high: high || hidden.high, exact: true };
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
  const free = sub !== null && !withoutMessages(base, args).some(reachesOutside);
  const signature = free ? [name, ...sub].map(quoteWord).join(" ") : exactSignature(name, args);
  return { signature, high: high || nestedHigh, exact: !free };
}

/**
 * An argument naming a path outside the work folder (absolute, a drive, `~`, `..`, a URL), a
 * global install location (`-g`), or the repository's `.git` folder, which every worktree of the
 * repository shares: `--output=/home/me/.bashrc`, `-o ~/bin/ls`, `--prefix=../other`, `.git/hooks`.
 */
function reachesOutside(arg: string): boolean {
  if (/^(-g|--global|--location=global|--user|--system)$/.test(arg)) return true;
  if (namesGitFolder(arg)) return true;
  return /(?:^|[=:]|^-[A-Za-z])(?:[/\\~]|[A-Za-z]:)|(?:^|[/\\=:])\.\.(?:[/\\]|$)/.test(arg);
}

/** An argument naming `.git` (or Windows' `.git.` and `GIT~1`), whose configuration can name commands. */
function namesGitFolder(arg: string): boolean {
  return /(?:^|[/\\=:])(?:\.git[. ]*|git~\d+)(?:[/\\]|$)/i.test(arg);
}

/** The arguments without commit, tag and merge messages, which git never reads as paths. */
function withoutMessages(base: string, args: string[]): string[] {
  if (base !== "git") return args;
  const { sub, rest } = gitSplit(args);
  if (sub !== "commit" && sub !== "tag" && sub !== "merge") return args;
  const kept = args.slice(0, args.length - rest.length);
  for (let k = 0; k < rest.length; k++) {
    const a = rest[k]!;
    // `-m <message>` and `-am <message>`; `-m<message>` and `--message=<message>` carry it.
    if (a === "--message" || /^-[A-Za-z]*m$/.test(a)) k++;
    else if (!a.startsWith("--message=") && !/^-m./.test(a)) kept.push(a);
  }
  return kept;
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
    if (changesSettings(base, rest)) return { reason: WHY.settings };
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
      return sedRuns(args);
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
      // `npm explore <package> -- <command>` runs the command in the package's folder.
      if (args.find((a) => !isOption(a)) === "explore") return true;
      return args.some(
        (a) =>
          /script-shell|node-options/i.test(a) ||
          NPM_PROGRAM_SETTINGS.some((s) => usesOption(a, s)) ||
          usesOption(a, "--call") ||
          a === "-c" ||
          a === "--shell-mode",
      );
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

/**
 * bash evaluates the array subscript in a variable name these builtins take, and a subscript can
 * run a command: `printf -v 'v[$(id)]' x`, `test -v 'v[$(id)]'`.
 */
function evaluatesNames(base: string, args: string[]): boolean {
  if (base === "printf") return args.some((a) => a.startsWith("-v"));
  if (base === "test") return args.some((a) => a === "-v" || a === "-R");
  return false;
}

/**
 * Commands that write configuration outside the work folder: your npm, pnpm, yarn, pip, poetry
 * and gh settings, and git's, whose repository configuration every worktree shares. Settings
 * can name programs that run later.
 */
function changesSettings(base: string, args: string[]): boolean {
  // Options' values count as words here, so a pair is looked for anywhere: `npm --prefix app config set`.
  const words = args.filter((a) => !isOption(a));
  const pair = (first: (w: string) => boolean, second: readonly string[]) => words.some((w, k) => first(w) && second.includes(words[k + 1] ?? ""));
  switch (base) {
    case "git": {
      const { sub, rest } = gitSplit(args);
      return sub === "config" && gitConfigWrites(rest);
    }
    case "npm":
    case "pnpm":
    case "yarn":
      return words.slice(0, 2).includes("set") || pair((w) => w === "config" || w === "c", ["set", "delete", "unset", "rm", "edit", "fix"]);
    case "pip":
    case "pip3":
      return pair((w) => w === "config", ["set", "unset", "edit"]);
    case "poetry": {
      const at = words.indexOf("config");
      return at >= 0 && !args.includes("--local") && (words.length - at >= 3 || args.includes("--unset"));
    }
    case "gh":
      return (
        pair((w) => w === "config", ["set"]) ||
        pair((w) => w === "alias", ["set", "import", "delete"]) ||
        pair((w) => /^ext(ension)?s?$/.test(w), ["install", "upgrade", "remove"])
      );
    default:
      return false;
  }
}

/** `git config` that writes (a value, `--unset`, `set`, ...), as opposed to reading a setting. */
function gitConfigWrites(rest: string[]): boolean {
  const writes = ["--add", "--replace-all", "--unset", "--unset-all", "--rename-section", "--remove-section", "--edit", "-e"];
  if (rest.some((a) => writes.some((w) => usesOptionOrPrefix(a, w)))) return true;
  const words = rest.filter((a) => !isOption(a));
  if (words[0] === "get" || words[0] === "list") return false;
  if (["set", "unset", "rename-section", "remove-section", "edit"].includes(words[0] ?? "")) return true;
  const reads = ["--get", "--get-all", "--get-regexp", "--get-urlmatch", "--get-color", "--get-colorbool", "--list", "-l"];
  if (rest.some((a) => reads.some((r) => a === r || a.startsWith(`${r}=`)))) return false;
  return words.length >= 2;
}

/** GNU sed runs commands with `e`; a script it reads from a file (`-f`) cannot be checked. */
function sedRuns(args: string[]): boolean {
  const scripts: string[] = [];
  const operands: string[] = [];
  let given = false;
  for (let k = 0; k < args.length; k++) {
    const a = args[k]!;
    if (a === "--") {
      operands.push(...args.slice(k + 1));
      break;
    }
    if (a.startsWith("--")) {
      if (longPrefix(a, "--file")) return true;
      if (longPrefix(a, "--expression")) {
        given = true;
        const eq = a.indexOf("=");
        const script = eq >= 0 ? a.slice(eq + 1) : args[++k];
        if (script === undefined) return true;
        scripts.push(script);
      }
      continue;
    }
    if (a.startsWith("-") && a.length > 1) {
      for (let j = 1; j < a.length; j++) {
        const ch = a.charAt(j);
        if (ch === "f") return true;
        if (ch === "e") {
          given = true;
          const script = j + 1 < a.length ? a.slice(j + 1) : args[++k];
          if (script === undefined) return true;
          scripts.push(script);
          break;
        }
        // -l takes a number; -i and -I take an attached suffix.
        if (ch === "l") {
          if (j === a.length - 1) k++;
          break;
        }
        if (ch === "i" || ch === "I") break;
      }
      continue;
    }
    operands.push(a);
  }
  if (!given && operands[0] !== undefined) scripts.push(operands[0]);
  return scripts.some(sedScriptRuns);
}

/**
 * Whether a sed script may run a command (GNU sed's `e` command and the `e` flag of `s`), read
 * command by command. A script that cannot be read for certain counts as running one.
 */
function sedScriptRuns(script: string): boolean {
  const n = script.length;
  let i = 0;
  const at = (k = i) => script.charAt(k);
  const digits = () => {
    while (/\d/.test(at())) i++;
  };
  const spaces = () => {
    while (at() === " " || at() === "\t") i++;
  };
  const toLineEnd = () => {
    const nl = script.indexOf("\n", i);
    i = nl < 0 ? n : nl;
  };
  // A bracket expression may hold the delimiter: s/[/]/x/.
  const bracket = (): boolean => {
    i++;
    if (at() === "^") i++;
    if (at() === "]") i++;
    while (i < n) {
      const c = at();
      if (c === "\n") return false;
      if (c === "[" && oneOf(at(i + 1), ":.=")) {
        const close = script.indexOf(`${at(i + 1)}]`, i + 2);
        if (close < 0) return false;
        i = close + 2;
      } else if (c === "]") {
        i++;
        return true;
      } else {
        i++;
      }
    }
    return false;
  };
  const regex = (delimiter: string): boolean => {
    while (i < n) {
      const c = at();
      if (c === "\n") return false;
      if (c === "\\") {
        i += 2;
      } else if (c === delimiter) {
        i++;
        return true;
      } else if (c === "[") {
        if (!bracket()) return false;
      } else {
        i++;
      }
    }
    return false;
  };
  const text = (delimiter: string): boolean => {
    while (i < n) {
      const c = at();
      if (c === "\n") return false;
      if (c === "\\") i += 2;
      else if (c === delimiter) {
        i++;
        return true;
      } else i++;
    }
    return false;
  };
  const delimiter = (): string | null => {
    const d = at();
    if (d === "" || d === "\n" || d === "\\") return null;
    i++;
    return d;
  };
  const address = (): boolean => {
    const c = at();
    if (/\d/.test(c)) {
      digits();
      if (at() === "~") {
        i++;
        digits();
      }
    } else if (c === "$") {
      i++;
    } else if (c === "/" || c === "\\") {
      if (c === "\\") i++;
      const d = c === "/" ? "/" : delimiter();
      if (c === "/") i++;
      if (d === null || !regex(d)) return false;
      while (at() === "I" || at() === "M") i++;
    }
    return true;
  };
  const ends = (): boolean => {
    spaces();
    return i >= n || oneOf(at(), ";\n}#");
  };
  for (;;) {
    while (i < n && oneOf(at(), " \t\n;")) i++;
    if (i >= n) return false;
    if (at() === "#") {
      toLineEnd();
      continue;
    }
    if (!address()) return true;
    spaces();
    if (at() === ",") {
      i++;
      spaces();
      if (at() === "+" || at() === "~") {
        i++;
        if (!/\d/.test(at())) return true;
        digits();
      } else {
        const before = i;
        if (!address() || i === before) return true;
      }
      spaces();
    }
    if (at() === "!") {
      i++;
      spaces();
    }
    const command = at();
    i++;
    switch (command) {
      case "{":
      case "}":
        continue;
      case "e":
        return true;
      case "s": {
        const d = delimiter();
        if (d === null || !regex(d) || !text(d)) return true;
        for (;;) {
          const flag = at();
          if (flag === "e") return true;
          if (flag === "w") {
            toLineEnd();
            break;
          }
          if (flag === "" || !"gpiImM0123456789".includes(flag)) break;
          i++;
        }
        if (!ends()) return true;
        continue;
      }
      case "y": {
        const d = delimiter();
        if (d === null || !text(d) || !text(d) || !ends()) return true;
        continue;
      }
      case "a":
      case "i":
      case "c":
        // Text to the end of the line; a backslash carries it on.
        while (i < n && at() !== "\n") i += at() === "\\" ? 2 : 1;
        continue;
      case "r":
      case "R":
      case "w":
      case "W":
        // A file name, to the end of the line.
        toLineEnd();
        continue;
      case ":":
      case "b":
      case "t":
      case "T":
        // A label.
        while (i < n && !oneOf(at(), ";\n")) i++;
        continue;
      case "q":
      case "Q":
      case "l":
      case "L":
        spaces();
        digits();
        if (!ends()) return true;
        continue;
      case "v":
        spaces();
        while (/[\d.]/.test(at())) i++;
        if (!ends()) return true;
        continue;
      default:
        if (command === "" || !"=dDgGhHnNpPxzF".includes(command) || !ends()) return true;
        continue;
    }
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
  if (globals.some((g) => g === "-c" || usesOptionOrPrefix(g, "--config-env") || usesOptionOrPrefix(g, "--exec-path"))) return true;
  if (sub === undefined) return false;
  if (GIT_WRAPPERS.has(sub)) return true;
  if ((sub === "submodule" && rest.includes("foreach")) || (sub === "bisect" && rest.includes("run"))) return true;
  // git takes any unique prefix of a long option (`--upl` for `--upload-pack`) and bundles short ones.
  const options = lookup(GIT_EXEC_OPTIONS, sub) ?? [];
  return rest.some((a) => options.some((o) => usesOptionOrPrefix(a, o)));
}

// The risk rating has to name the destructive git commands it rates, so the source scan in the
// unit tests skips it.
// banned-git-guard:start
/** A word `git checkout` can only read as a path: `.`, `./x`, `:/`, `src/`, `*.ts`, `app.ts`. */
function looksLikePath(word: string): boolean {
  const last = word.split(/[\\/]/).pop() ?? "";
  return (
    word === "." ||
    word === ".." ||
    /^\.{1,2}[\\/]/.test(word) ||
    /^[:\\/]/.test(word) ||
    /[\\/]$/.test(word) ||
    /[*?[\]]/.test(word) ||
    /\.[A-Za-z][A-Za-z0-9]*$/.test(last)
  );
}

/**
 * `git checkout` that throws away changes: forced (`-f`, also bundled, as in `-qf`), resetting a
 * branch (`-B`), or given paths: after `--`, after a tree-ish, or a word that can only be one.
 */
function checkoutDiscards(rest: string[], has: (...flags: string[]) => boolean, letters: string): boolean {
  if (/[fBm]/.test(letters) || rest.includes("--")) return true;
  if (has("--force", "--merge", "--ours", "--theirs", "--conflict", "--patch", "--pathspec-from-file", "--overlay", "--no-overlay")) return true;
  const words: string[] = [];
  for (let k = 0; k < rest.length; k++) {
    const a = rest[k]!;
    // The new branch's name.
    if (a === "-b" || a === "--orphan") k++;
    else if (!isOption(a)) words.push(a);
  }
  return words.length > 1 || words.some(looksLikePath);
}

function gitDestroysOrReachesFar(args: string[]): boolean {
  const { sub, rest } = gitSplit(args);
  // Long options by any prefix git accepts, short ones also inside bundles.
  const has = (...flags: string[]) => rest.some((a) => flags.some((f) => usesOptionOrPrefix(a, f)));
  const letters = rest.filter((a) => /^-[A-Za-z]+$/.test(a)).join("");
  switch (sub) {
    case "push":
    case "send-pack":
    case "http-push":
    case "clean":
    case "stash":
    case "filter-branch":
      return true;
    case "subtree":
    case "lfs":
      return rest.includes("push");
    case "p4":
      return rest.includes("submit");
    case "svn":
      return rest.some((a) => ["dcommit", "set-tree", "branch", "tag"].includes(a));
    case "reset":
      return has("--hard");
    case "checkout":
      return checkoutDiscards(rest, has, letters);
    case "restore": {
      // Only `--staged` leaves the files alone. A bundle's letters after -s are its value.
      const staged = rest.some((a) => a === "--staged" || (/^-[A-Za-z]+$/.test(a) && a.split("s")[0]!.includes("S")));
      return !staged || has("--worktree") || letters.includes("W");
    }
    case "switch":
      return has("--force", "--discard-changes", "--force-create") || /[fC]/.test(letters);
    case "branch":
      // -D deletes unmerged work; -M, -C and -f overwrite another branch.
      return /[DMCf]/.test(letters) || has("--force");
    case "rm":
      return letters.includes("f") || has("--force");
    case "worktree":
      return rest[0] === "remove" && (letters.includes("f") || has("--force"));
    case "update-ref":
      return has("-d", "--delete");
    case "reflog":
      return rest[0] === "expire" || rest[0] === "delete";
    default:
      return false;
  }
}

/** Commands that can destroy work or reach far are high risk: they ask every time, and only once. */
function destroysOrReachesFar(base: string, args: string[], dialect: Dialect): boolean {
  if (ALWAYS_HIGH.has(base) || base.startsWith("mkfs")) return true;
  // The repository's .git, which every worktree shares, as the file tools treat it.
  if (args.some(namesGitFolder)) return true;
  const bundles = args.filter((a) => /^-[A-Za-z]+$/.test(a)).join(" ");
  if (base === "rm" && (/r/i.test(bundles) || args.includes("--recursive")) && (/f/i.test(bundles) || args.includes("--force"))) return true;
  // In PowerShell, rm, rd, del and the rest are Remove-Item, and -r is -Recurse.
  if (dialect !== "bash" && REMOVE_ITEM.has(base) && args.some(recursesPowerShell)) return true;
  if ((base === "rd" || base === "rmdir" || base === "del" || base === "erase") && args.some((a) => a.toLowerCase() === "/s")) return true;
  const publishes = lookup(PUBLISHERS, base);
  if (publishes && args.some((a) => publishes.includes(a))) return true;
  if (dialect !== "bash" && STOP_PROCESS.has(base) && args.some(namesProcess)) return true;
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
    case "dotnet":
      return args[0] === "nuget" && (args[1] === "push" || args[1] === "delete");
    case "kill":
      return dialect !== "powershell" && killsWidely(args);
    case "systemctl":
    case "loginctl":
      return args.some((a) => POWER_VERBS.has(a));
    default:
      return false;
  }
}
// banned-git-guard:end

function recursesPowerShell(arg: string): boolean {
  const flag = dashed(arg).toLowerCase().split(":")[0] ?? "";
  return flag.length >= 2 && "-recurse".startsWith(flag);
}

/** Stop-Process -Name (or -ProcessName, or a prefix PowerShell accepts): every process of that name. */
function namesProcess(arg: string): boolean {
  const flag = dashed(arg).toLowerCase().split(":")[0] ?? "";
  return flag.length >= 2 && flag.startsWith("-") && ("-name".startsWith(flag) || "-processname".startsWith(flag));
}

/** bash's kill aimed at every process (-1), a process group (a negative id) or the shell's own (0). */
function killsWidely(args: string[]): boolean {
  let k = 0;
  if (args[0] === "-s" || args[0] === "-n") k = 2;
  else if (args[0] !== undefined && args[0] !== "--" && isOption(args[0])) k = 1;
  if (args[k] === "--") k++;
  return args.slice(k).some((a) => a === "0" || /^-\d/.test(a));
}
