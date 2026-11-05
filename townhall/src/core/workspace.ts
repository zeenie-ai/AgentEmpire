import { execFile, spawn } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmdirSync,
  statSync,
  unlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fromJson } from "../db/db.js";
import { fail } from "../protocol/errors.js";
import type { DiffFile, DiffFileStatus, DiffStat, MergeBlockedReason, RiteResult } from "../protocol/objects.js";
import { currentPlatform, isInside, isUncOrDevicePath, samePath, type Platform } from "../security/path-guard.js";
import { tailBytes } from "../security/redact.js";
import type { AgentRow } from "./agents.js";
import { MAX_TIMER_MS } from "./clock.js";
import type { Ctx } from "./context.js";
import { shortRandom } from "./ids.js";

export const TOWN_HALL_IDENTITY = ["-c", "user.name=AgentEmpire Town Hall", "-c", "user.email=townhall@agentempire.invalid"];
/** The folder in the data folder that the Town Hall's git commands use as their hooks folder. */
export const NO_HOOKS_DIR = "no-hooks";
/**
 * Options for every diff the Town Hall runs: no external diff or textconv program, and a
 * submodule shown as the commit it names, without looking inside it.
 */
const DIFF_OPTIONS = ["--no-ext-diff", "--no-textconv", "--submodule=short"];
const RITE_OUTPUT_TAIL_BYTES = 2 * 1024;
const RITE_BUFFER_BYTES = 64 * 1024;
const GIT_MAX_BUFFER = 64 * 1024 * 1024;
/** A worktree's `.git` and its git folder's `gitdir` hold one path; anything longer is not git's. */
const POINTER_MAX_BYTES = 4096;

export interface TaskWorkspace {
  mode: "git_worktree" | "plain_folder";
  /** The repository whose worktree the task uses: the user's repo, or the agent's versioned copy. */
  repo: string;
  worktree: string;
  branch: string;
  base_sha: string;
  base_branch: string | null;
  cwd: string;
  snapshot_sha: string | null;
  /** Plain-folder mode: the user's source folder that `export` writes back to. */
  source: string | null;
  archived_ref: string | null;
  removed: boolean;
}

export interface SnapshotResult {
  snapshot_sha: string;
  diff_stat: DiffStat;
  files: DiffFile[];
  /** Folders left out because each holds a git repository of its own (see `nestedRepos`). */
  nested: string[];
}

export interface GitResult {
  code: number;
  stdout: string;
  stderr: string;
}

export interface GitRunOptions {
  allowFail?: boolean;
  env?: Record<string, string>;
  /** Written to git's standard input. */
  input?: string;
}

/** git in one folder, with the options that every command there needs already given. */
type GitIn = (args: string[], opts?: GitRunOptions) => Promise<GitResult>;

/** Where the git subcommand is in `args`, after the global options (`-c` and `-C` take a value). */
function subcommandIndex(args: readonly string[]): number {
  let i = 0;
  while (i < args.length && args[i]!.startsWith("-")) {
    i += args[i] === "-c" || args[i] === "-C" ? 2 : 1;
  }
  return i;
}

/**
 * Refuses git invocations that can destroy work. The Town Hall never runs these; this is a
 * second line of defence behind the source scan in the unit tests (which skips this block).
 */
// banned-git-guard:start
export function assertSafeGitArgs(args: readonly string[]): void {
  const i = subcommandIndex(args);
  const sub = args[i];
  const rest = args.slice(i + 1);
  const banned =
    sub === "stash" ||
    sub === "clean" ||
    (sub === "reset" && rest.includes("--hard")) ||
    (sub === "worktree" && rest[0] === "remove" && (rest.includes("--force") || rest.includes("-f"))) ||
    (sub === "checkout" && (rest.includes("--force") || rest.includes("-f")));
  if (banned) throw new Error(`refusing a destructive git command: git ${args.join(" ")}`);
}
// banned-git-guard:end

const TRANSIENT_GIT = /index\.lock|could not lock|unable to (unlink|create|write)|permission denied|device or resource busy|resource temporarily unavailable/i;

export class Git {
  constructor(
    private readonly transientRetries: number,
    private readonly sleep: (ms: number) => Promise<void>,
    /** An empty folder of the Town Hall's own, given to git as its hooks folder. */
    private readonly hooksDir: string,
  ) {}

  private env(extra: Record<string, string> = {}): NodeJS.ProcessEnv {
    const env: NodeJS.ProcessEnv = { ...process.env, GIT_TERMINAL_PROMPT: "0", GCM_INTERACTIVE: "never", ...extra };
    // Never let an inherited repository selection redirect our commands.
    delete env.GIT_DIR;
    delete env.GIT_COMMON_DIR;
    delete env.GIT_WORK_TREE;
    delete env.GIT_INDEX_FILE;
    return env;
  }

  /**
   * Settings for every command. Settings on the command line win over every config file (the
   * repository's, or one an agent planted), and git passes them on to the git processes it starts
   * itself through GIT_CONFIG_PARAMETERS, such as the status that `worktree remove` runs.
   */
  private settings(): string[] {
    const settings = [
      "core.longpaths=true",
      "core.quotepath=false",
      // Otherwise git runs the fsmonitor command, through the shell, whenever it reads the index.
      "core.fsmonitor=false",
      // An empty folder, so no hook runs: neither the repository's nor one an agent wrote.
      `core.hooksPath=${this.emptyHooksDir()}`,
      // An ext:: remote is a command line. The Town Hall never fetches, but git can on its own,
      // for a partial clone's missing objects.
      "protocol.ext.allow=never",
      "submodule.recurse=false",
    ];
    return settings.flatMap((s) => ["-c", s]);
  }

  /** The hooks folder, created when missing and refused when it is not an empty folder. */
  private emptyHooksDir(): string {
    try {
      mkdirSync(this.hooksDir, { recursive: true });
    } catch {
      // A file in its place; refused below.
    }
    let empty = false;
    try {
      empty = lstatSync(this.hooksDir).isDirectory() && readdirSync(this.hooksDir).length === 0;
    } catch {
      empty = false;
    }
    if (!empty) {
      throw fail.workspace(`${this.hooksDir} must be an empty folder: git takes it as the Town Hall's hooks folder; remove what is in it`);
    }
    return this.hooksDir;
  }

  private once(
    cwd: string,
    args: string[],
    opts: { env?: Record<string, string> | undefined; binary?: boolean; input?: string | undefined } = {},
  ): Promise<{ code: number; stdout: string | Buffer; stderr: string }> {
    return new Promise((resolve) => {
      const child = execFile(
        "git",
        args,
        {
          cwd,
          windowsHide: true,
          maxBuffer: GIT_MAX_BUFFER,
          env: this.env(opts.env),
          encoding: opts.binary ? "buffer" : "utf8",
        },
        (err, stdout, stderr) => {
          const code = err ? (typeof (err as { code?: unknown }).code === "number" ? ((err as { code: number }).code) : 1) : 0;
          resolve({ code, stdout, stderr: stderr.toString() });
        },
      );
      if (opts.input !== undefined && child.stdin) {
        // git may exit before it reads everything; its exit code tells what happened.
        child.stdin.on("error", () => undefined);
        child.stdin.end(opts.input);
      }
    });
  }

  private checkCwd(cwd: string): void {
    // A missing cwd makes execFile report "spawn git ENOENT", which reads like git is missing.
    let ok = false;
    try {
      ok = statSync(cwd).isDirectory();
    } catch {
      ok = false;
    }
    if (!ok) throw fail.workspace(`the folder ${cwd} no longer exists`);
  }

  async run(cwd: string, args: string[], opts: GitRunOptions = {}): Promise<GitResult> {
    assertSafeGitArgs(args);
    this.checkCwd(cwd);
    const full = [...this.settings(), ...args];
    let attempt = 0;
    for (;;) {
      const r = await this.once(cwd, full, { env: opts.env, input: opts.input });
      const out: GitResult = { code: r.code, stdout: String(r.stdout).replace(/\r\n/g, "\n"), stderr: r.stderr.replace(/\r\n/g, "\n") };
      if (out.code === 0) return out;
      if (attempt < this.transientRetries && TRANSIENT_GIT.test(out.stderr)) {
        attempt++;
        await this.sleep(150 * attempt);
        continue;
      }
      if (opts.allowFail) return out;
      throw fail.workspace(`git ${args[subcommandIndex(args)] ?? ""} failed: ${out.stderr.trim().split("\n").slice(-3).join(" ")}`);
    }
  }

  async buffer(cwd: string, args: string[]): Promise<Buffer | null> {
    assertSafeGitArgs(args);
    this.checkCwd(cwd);
    const r = await this.once(cwd, [...this.settings(), ...args], { binary: true });
    return r.code === 0 ? (r.stdout as Buffer) : null;
  }
}

function readSmall(file: string): string | null {
  try {
    if (statSync(file).size > POINTER_MAX_BYTES) return null;
    return readFileSync(file, "utf8");
  } catch {
    return null;
  }
}

function realOrNull(p: string): string | null {
  try {
    return realpathSync.native(p);
  } catch {
    return null;
  }
}

/** A path written by git into a pointer file; like git, drops only the line breaks after it. */
function pointerPath(text: string): string | null {
  const p = text.replace(/[\r\n]+$/, "");
  return p === "" || /[\0\r\n]/.test(p) ? null : p;
}

/**
 * Checks that a task worktree's `.git` is still what `git worktree add` wrote, and returns the
 * git folder it names. An agent can rewrite that file like any other in its worktree, and aim it
 * at a repository it planted, whose config and hooks git would then run (its fsmonitor command,
 * hooks, filters). So `.git` must be a plain file reading `gitdir: <path>`, the path must lead to
 * a folder in the repository's `worktrees` folder (`commonDir` is the repository's git folder),
 * and that folder's `gitdir` file must lead back to this `.git`, the link git keeps both ways.
 */
export function worktreeGitDir(worktree: string, commonDir: string, platform: Platform = currentPlatform()): string {
  const changed = (why: string) =>
    fail.workspace(`the work folder's .git was changed (${why}), so the Town Hall runs no git in ${worktree}`);
  const pointer = path.join(worktree, ".git");
  let isFile = false;
  try {
    isFile = lstatSync(pointer).isFile();
  } catch {
    throw changed("it is missing");
  }
  // A folder, or a link or junction to anything, is not what git wrote.
  if (!isFile) throw changed("it is no longer a plain file");
  const text = readSmall(pointer);
  const named = text?.startsWith("gitdir: ") ? pointerPath(text.slice("gitdir: ".length)) : null;
  if (named === null) throw changed("it no longer names a git folder");
  const target = path.resolve(worktree, named);
  // Resolving a network path would connect to the host it names, and sign in there as the player.
  if (isUncOrDevicePath(target)) throw changed("it names a network or device path");
  const gitDir = realOrNull(target);
  const worktrees = realOrNull(path.join(commonDir, "worktrees"));
  if (gitDir === null || worktrees === null || !samePath(path.dirname(gitDir), worktrees, platform)) {
    throw changed("it names a folder that is not one of the repository's worktrees");
  }
  const back = readSmall(path.join(gitDir, "gitdir"));
  const backPath = back === null ? null : pointerPath(back);
  const backReal = backPath === null ? null : realOrNull(path.resolve(gitDir, backPath));
  const self = realOrNull(pointer);
  if (backReal === null || self === null || !samePath(backReal, self, platform)) {
    throw changed("it names the git folder of another worktree");
  }
  return gitDir;
}

/**
 * Whether a folder entry is `.git`, or may stand for it on Windows: the name in any case, with
 * trailing dots or spaces (which Windows drops), or `GIT~1`, the short name Windows gives `.git`.
 */
export function isDotGit(name: string): boolean {
  const n = name.toLowerCase().replace(/[. ]+$/, "");
  return n === ".git" || n === "git~1";
}

/** Diff arguments for `from` against `to`, or against the worktree's files when `to` is null. */
function diffRange(from: string, to: string | null): string[] {
  // Against the files, git would look inside each submodule (by running git there): leave them out.
  return to ? [...DIFF_OPTIONS, from, to] : [...DIFF_OPTIONS, "--ignore-submodules=all", from];
}

function mapStatus(letter: string): DiffFileStatus {
  switch (letter[0]) {
    case "A":
      return "added";
    case "M":
      return "modified";
    case "D":
      return "deleted";
    case "R":
      return "renamed";
    case "C":
      return "copied";
    case "T":
      return "type_changed";
    default:
      return "unknown";
  }
}

/** Parses `git diff --numstat -z` (renames list source and destination separately). */
export function parseNumstatZ(out: string): Map<string, { added: number; removed: number }> {
  const parts = out.split("\0");
  const result = new Map<string, { added: number; removed: number }>();
  let i = 0;
  while (i < parts.length) {
    const head = parts[i]!;
    if (head === "") {
      i++;
      continue;
    }
    const t1 = head.indexOf("\t");
    const t2 = head.indexOf("\t", t1 + 1);
    const a = head.slice(0, t1);
    const d = head.slice(t1 + 1, t2);
    let file = head.slice(t2 + 1);
    if (file === "") {
      file = parts[i + 2] ?? "";
      i += 3;
    } else {
      i += 1;
    }
    result.set(file, { added: a === "-" ? 0 : Number(a) || 0, removed: d === "-" ? 0 : Number(d) || 0 });
  }
  return result;
}

/** Parses `git diff --name-status -z`. */
export function parseNameStatusZ(out: string): Array<{ status: DiffFileStatus; path: string; from?: string }> {
  const parts = out.split("\0");
  const result: Array<{ status: DiffFileStatus; path: string; from?: string }> = [];
  let i = 0;
  while (i < parts.length) {
    const code = parts[i]!;
    if (code === "") {
      i++;
      continue;
    }
    if (code[0] === "R" || code[0] === "C") {
      result.push({ status: mapStatus(code), from: parts[i + 1] ?? "", path: parts[i + 2] ?? "" });
      i += 3;
    } else {
      result.push({ status: mapStatus(code), path: parts[i + 1] ?? "" });
      i += 2;
    }
  }
  return result;
}

function sameFile(a: Buffer | null, b: Buffer | null): boolean {
  if (a === null || b === null) return a === b;
  return a.equals(b);
}

function readOrNull(file: string): Buffer | null {
  try {
    return readFileSync(file);
  } catch {
    return null;
  }
}

function killTree(pid: number | undefined): void {
  if (!pid) return;
  if (process.platform === "win32") {
    execFile("taskkill", ["/pid", String(pid), "/T", "/F"], { windowsHide: true }, () => undefined);
  } else {
    try {
      process.kill(-pid, "SIGKILL");
    } catch {
      // already gone
    }
  }
}

export class WorkspaceService {
  readonly git: Git;

  constructor(private readonly ctx: Ctx) {
    this.git = new Git(
      ctx.econ.data.incidents.transient_retries,
      (ms) => new Promise((r) => setTimeout(r, ms)),
      path.join(ctx.config.dataDir, NO_HOOKS_DIR),
    );
  }

  private get platform() {
    return currentPlatform();
  }

  taskWorkspace(json: string | null): TaskWorkspace | null {
    return fromJson<TaskWorkspace | null>(json, null);
  }

  /** Finds the repository that contains `folder`, if any. */
  async detect(folder: string): Promise<{ mode: "git_worktree" | "plain_folder"; repoRoot: string | null; sub: string }> {
    if (folder.split(/[\\/]/).some((seg) => seg.toLowerCase() === ".git")) {
      throw fail.workspace("a folder inside .git cannot be a work folder");
    }
    const r = await this.git.run(folder, ["rev-parse", "--show-toplevel"], { allowFail: true });
    if (r.code !== 0) return { mode: "plain_folder", repoRoot: null, sub: "" };
    const top = path.resolve(r.stdout.trim());
    const sub = path.relative(top, folder);
    if (sub.startsWith("..") || path.isAbsolute(sub)) return { mode: "git_worktree", repoRoot: top, sub: "" };
    return { mode: "git_worktree", repoRoot: top, sub };
  }

  private mirrorPath(agentId: string): string {
    return path.join(this.ctx.config.dataDir, "mirrors", agentId.slice(-10).toLowerCase());
  }

  /** Runs at home_built. Returns the versioned copy path for plain folders, or null. */
  async setupAgent(agent: AgentRow): Promise<string | null> {
    if (agent.workspace_mode === "git_worktree") {
      const root = agent.repo_root!;
      const head = await this.git.run(root, ["rev-parse", "--verify", "--quiet", "HEAD"], { allowFail: true });
      if (head.code !== 0) throw fail.workspace("the repository has no commits yet; make a first commit");
      return null;
    }
    const mirror = this.mirrorPath(agent.id);
    await this.syncMirror(agent.workspace_path, mirror);
    return mirror;
  }

  /** Brings the Town Hall's versioned copy of a plain folder up to date with the source. */
  private async syncMirror(source: string, mirror: string): Promise<void> {
    await this.ctx.locks.run(`repo:${mirror}`, async () => {
      mkdirSync(mirror, { recursive: true });
      if (!existsSync(path.join(mirror, ".git"))) {
        await this.git.run(mirror, ["init", "-q"]);
        await this.git.run(mirror, ["symbolic-ref", "HEAD", "refs/heads/main"]);
      }
      this.copyTree(source, mirror);
      await this.git.run(mirror, ["add", "-A"]);
      const status = await this.git.run(mirror, ["status", "--porcelain", "-z", "--ignore-submodules=all"]);
      const hasHead = (await this.git.run(mirror, ["rev-parse", "--verify", "--quiet", "HEAD"], { allowFail: true })).code === 0;
      if (status.stdout.length > 0 || !hasHead) {
        await this.git.run(mirror, [
          ...TOWN_HALL_IDENTITY,
          "commit",
          "--no-verify",
          "--allow-empty",
          "-q",
          "-m",
          "AgentEmpire: sync from the work folder",
        ]);
      }
    });
  }

  /**
   * Mirrors `source` into `dest` (skipping .git and symlinks), within the configured limits.
   * Every spelling of `.git` is skipped, so nothing is ever copied into the copy's own git folder.
   */
  private copyTree(source: string, dest: string): void {
    const maxFiles = this.ctx.config.plainFolderMaxFiles;
    const maxBytes = this.ctx.config.plainFolderMaxBytes;
    let files = 0;
    let bytes = 0;
    const seen = new Set<string>();
    const walk = (rel: string) => {
      const dir = path.join(source, rel);
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        if (isDotGit(entry.name)) continue;
        const relPath = path.join(rel, entry.name);
        if (entry.isSymbolicLink()) continue;
        if (entry.isDirectory()) {
          mkdirSync(path.join(dest, relPath), { recursive: true });
          seen.add(relPath.toLowerCase());
          walk(relPath);
        } else if (entry.isFile()) {
          const src = path.join(source, relPath);
          const dst = path.join(dest, relPath);
          const st = statSync(src);
          files++;
          bytes += st.size;
          if (files > maxFiles || bytes > maxBytes) {
            throw fail.workspace("the work folder is too large to copy; use a git repository instead");
          }
          seen.add(relPath.toLowerCase());
          let same = false;
          try {
            const dt = statSync(dst);
            same = dt.size === st.size && Math.abs(dt.mtimeMs - st.mtimeMs) < 1;
          } catch {
            same = false;
          }
          if (!same) {
            copyFileSync(src, dst);
            utimesSync(dst, st.atime, st.mtime);
          }
        }
      }
    };
    walk("");
    // Remove files that disappeared from the source (only inside our own copy).
    const prune = (rel: string) => {
      const dir = path.join(dest, rel);
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        if (rel === "" && isDotGit(entry.name)) continue;
        const relPath = path.join(rel, entry.name);
        if (entry.isDirectory()) {
          prune(relPath);
          if (!seen.has(relPath.toLowerCase()) && readdirSync(path.join(dest, relPath)).length === 0) {
            rmdirSync(path.join(dest, relPath));
          }
        } else if (!seen.has(relPath.toLowerCase())) {
          unlinkSync(path.join(dest, relPath));
        }
      }
    };
    prune("");
  }

  /** Creates (or reuses) the task's isolated worktree. The main checkout is never touched. */
  async prepareTask(task: { id: string; workspace_json: string | null }, agent: AgentRow): Promise<TaskWorkspace> {
    const existing = this.taskWorkspace(task.workspace_json);
    if (existing && !existing.removed && existsSync(existing.worktree)) return existing;

    const plain = agent.workspace_mode === "plain_folder";
    const repo = plain ? (agent.mirror_path ?? this.mirrorPath(agent.id)) : agent.repo_root!;
    if (plain) await this.syncMirror(agent.workspace_path, repo);

    return this.ctx.locks.run(`repo:${repo}`, async () => {
      const branch = `agentempire/${agent.id}/${task.id}`;
      const branchExists =
        (await this.git.run(repo, ["rev-parse", "--verify", "--quiet", `refs/heads/${branch}`], { allowFail: true })).code === 0;
      let baseSha = existing?.base_sha ?? "";
      let baseBranch = existing?.base_branch ?? null;
      if (!baseSha) {
        baseSha = (await this.git.run(repo, ["rev-parse", "HEAD"])).stdout.trim();
        const sym = await this.git.run(repo, ["symbolic-ref", "--short", "-q", "HEAD"], { allowFail: true });
        baseBranch = sym.code === 0 && sym.stdout.trim() ? sym.stdout.trim() : null;
      }
      // Short roots keep Windows paths well under git's limits.
      const worktree = path.join(this.ctx.config.dataDir, "wt", shortRandom(8));
      mkdirSync(path.dirname(worktree), { recursive: true });
      if (branchExists) await this.git.run(repo, ["worktree", "add", worktree, branch]);
      else await this.git.run(repo, ["worktree", "add", "-b", branch, worktree, baseSha]);
      await this.git.run(repo, ["worktree", "lock", "--reason", `AgentEmpire task ${task.id}`, worktree]);
      const cwd = path.join(worktree, plain ? "" : agent.workspace_sub);
      mkdirSync(cwd, { recursive: true });
      return {
        mode: agent.workspace_mode,
        repo,
        worktree,
        branch,
        base_sha: baseSha,
        base_branch: baseBranch,
        cwd,
        snapshot_sha: existing?.snapshot_sha ?? null,
        source: plain ? agent.workspace_path : null,
        archived_ref: null,
        removed: false,
      };
    });
  }

  /**
   * git for a task's worktree. It checks the worktree's `.git` first (`worktreeGitDir`), then
   * names the worktree's git folder and files on every command, so git never reads `.git` itself,
   * even if it changes in the meantime.
   */
  private async inWorktree(ws: TaskWorkspace): Promise<GitIn> {
    const common = (await this.git.run(ws.repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"])).stdout.trim();
    const gitDir = worktreeGitDir(ws.worktree, path.resolve(ws.repo, common), this.platform);
    const pinned = [`--git-dir=${gitDir}`, `--work-tree=${ws.worktree}`];
    return (args, opts) => this.git.run(ws.worktree, [...pinned, ...args], opts);
  }

  /**
   * Folders in the worktree that hold a git repository of their own: untracked ones, which
   * `ls-files` lists whole, with a trailing slash, and submodules that were filled in. `git add`
   * would record the first kind as a bare commit id, without its files, and runs `git status`
   * inside the second kind, under the config of the repository there, which the agent can write.
   */
  private async nestedRepos(git: GitIn, worktree: string): Promise<string[]> {
    const untracked = (await git(["ls-files", "--others", "--exclude-standard", "-z"])).stdout
      .split("\0")
      .filter((p) => p.endsWith("/"))
      .map((p) => p.slice(0, -1));
    const submodules = (await git(["ls-files", "--stage", "-z"])).stdout
      .split("\0")
      .filter((entry) => entry.startsWith("160000 "))
      .map((entry) => entry.slice(entry.indexOf("\t") + 1))
      .filter((p) => existsSync(path.join(worktree, p, ".git")));
    return [...new Set([...untracked, ...submodules])].sort();
  }

  /** Commits everything in the worktree as the Town Hall, except nested repositories, which it returns. */
  private async commitAll(git: GitIn, worktree: string, message: string): Promise<string[]> {
    const nested = await this.nestedRepos(git, worktree);
    if (nested.length === 0) {
      await git(["add", "-A"]);
    } else {
      // On standard input, so that any number of them fits.
      const pathspecs = [".", ...nested.map((p) => `:(exclude,literal)${p}`)];
      await git(["add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul"], { input: pathspecs.join("\0") });
    }
    const staged = await git(["diff", "--cached", "--quiet", ...DIFF_OPTIONS], { allowFail: true });
    if (staged.code !== 0 && staged.code !== 1) throw fail.workspace(`git diff failed: ${staged.stderr.trim()}`);
    if (staged.code === 1) await git([...TOWN_HALL_IDENTITY, "commit", "--no-verify", "-q", "-m", message]);
    return nested;
  }

  /** Commits everything in the worktree as the Town Hall and returns the change stats. */
  async snapshot(ws: TaskWorkspace, message: string): Promise<SnapshotResult> {
    const git = await this.inWorktree(ws);
    const nested = await this.commitAll(git, ws.worktree, message);
    const head = (await git(["rev-parse", "HEAD"])).stdout.trim();
    const { files, stat } = await this.diffIn(git, ws.worktree, ws.base_sha, head);
    return { snapshot_sha: head, diff_stat: stat, files, nested };
  }

  /**
   * Where a task's changes are read for review: its worktree while it exists (the files while the
   * work is under way, else the snapshot), otherwise the repository (the snapshot, or nothing).
   */
  private async reviewSource(ws: TaskWorkspace): Promise<{ git: GitIn; cwd: string; to: string | null }> {
    if (!ws.removed && existsSync(ws.worktree)) return { git: await this.inWorktree(ws), cwd: ws.worktree, to: ws.snapshot_sha };
    return { git: (args, opts) => this.git.run(ws.repo, args, opts), cwd: ws.repo, to: ws.snapshot_sha ?? ws.base_sha };
  }

  /** A task's changed files against its base, for review. */
  async changes(ws: TaskWorkspace): Promise<{ files: DiffFile[]; stat: DiffStat }> {
    const at = await this.reviewSource(ws);
    return this.diffIn(at.git, at.cwd, ws.base_sha, at.to);
  }

  private async diffIn(git: GitIn, cwd: string, from: string, to: string | null): Promise<{ files: DiffFile[]; stat: DiffStat }> {
    const range = diffRange(from, to);
    const numstat = parseNumstatZ((await git(["diff", "--numstat", "-z", "-M", ...range])).stdout);
    const names = parseNameStatusZ((await git(["diff", "--name-status", "-z", "-M", ...range])).stdout);
    const files: DiffFile[] = names.map((n) => ({
      path: n.path,
      status: n.status,
      added: numstat.get(n.path)?.added ?? 0,
      removed: numstat.get(n.path)?.removed ?? 0,
    }));
    if (!to) {
      // Work in progress: untracked files are not in `git diff`.
      const untracked = (await git(["ls-files", "--others", "--exclude-standard", "-z"])).stdout
        .split("\0")
        .filter((p) => p.length > 0);
      for (const p of untracked) {
        const content = readOrNull(path.join(cwd, p));
        const lines = content ? content.toString("utf8").split("\n").length - (content.at(-1) === 10 ? 1 : 0) : 0;
        files.push({ path: p, status: "added", added: lines, removed: 0 });
      }
    }
    const stat: DiffStat = {
      files: files.length,
      added: files.reduce((a, f) => a + f.added, 0),
      removed: files.reduce((a, f) => a + f.removed, 0),
    };
    return { files, stat };
  }

  async patch(ws: TaskWorkspace, maxBytes: number): Promise<string> {
    const at = await this.reviewSource(ws);
    const out = (await at.git(["diff", "-M", ...diffRange(ws.base_sha, at.to)], { allowFail: true })).stdout;
    if (Buffer.byteLength(out, "utf8") <= maxBytes) return out;
    return Buffer.from(out, "utf8").subarray(0, maxBytes).toString("utf8") + "\n[patch truncated]\n";
  }

  /** Runs the optional Rite command (the player's own check, such as tests) in the worktree. */
  runRite(cwd: string, command: string, timeoutMs: number): Promise<RiteResult> {
    return new Promise((resolve) => {
      let output = "";
      let timedOut = false;
      const append = (chunk: Buffer) => {
        output += chunk.toString("utf8");
        if (output.length > RITE_BUFFER_BYTES * 2) output = output.slice(-RITE_BUFFER_BYTES);
      };
      let child: ReturnType<typeof spawn>;
      try {
        child = spawn(command, {
          cwd,
          shell: true,
          windowsHide: true,
          detached: process.platform !== "win32",
          env: process.env,
        });
      } catch (err) {
        resolve({ passed: false, output_tail: `the Rite could not start: ${String(err)}` });
        return;
      }
      child.stdout?.on("data", append);
      child.stderr?.on("data", append);
      // A limit past MAX_TIMER_MS (about 24.8 days, from AURELHAVEN_RITE_TIMEOUT_S) would fire
      // after 1 ms and fail every Rite; that far off it means no limit anyway.
      const timer = setTimeout(() => {
        timedOut = true;
        killTree(child.pid);
      }, Math.min(timeoutMs, MAX_TIMER_MS));
      const finish = (code: number | null) => {
        clearTimeout(timer);
        let text = this.ctx.redactor.redact(output);
        if (timedOut) text += `\n[the Rite timed out after ${Math.round(timeoutMs / 1000)} s]`;
        resolve({ passed: !timedOut && code === 0, output_tail: tailBytes(text, RITE_OUTPUT_TAIL_BYTES) });
      };
      child.on("error", (err) => {
        output += `\n${String(err)}`;
        finish(1);
      });
      child.on("close", (code) => finish(code));
    });
  }

  /** Merges the task branch into the main checkout, only when it is clean and on the base branch. */
  async merge(ws: TaskWorkspace, title: string, taskId: string): Promise<{ commit?: string; blocked?: MergeBlockedReason }> {
    if (ws.mode !== "git_worktree") return { blocked: "not_a_repo" };
    if (!existsSync(ws.repo)) return { blocked: "workspace_missing" };
    return this.ctx.locks.run(`repo:${ws.repo}`, async () => {
      const status = await this.git.run(ws.repo, ["status", "--porcelain=v1", "-z", "--untracked-files=no", "--ignore-submodules=all"], {
        env: { GIT_OPTIONAL_LOCKS: "0" },
      });
      if (status.stdout.length > 0) return { blocked: "checkout_dirty" as const };
      const sym = await this.git.run(ws.repo, ["symbolic-ref", "--short", "-q", "HEAD"], { allowFail: true });
      const current = sym.code === 0 ? sym.stdout.trim() : "";
      if (!current || !ws.base_branch || current !== ws.base_branch) return { blocked: "wrong_branch" as const };
      const tree = await this.git.run(ws.repo, ["merge-tree", "--write-tree", "HEAD", ws.branch], { allowFail: true });
      if (tree.code === 1) return { blocked: "conflict" as const };
      if (tree.code !== 0) return { blocked: "merge_failed" as const };
      const email = await this.git.run(ws.repo, ["config", "user.email"], { allowFail: true });
      const identity = email.code === 0 && email.stdout.trim() ? [] : TOWN_HALL_IDENTITY;
      const merged = await this.git.run(
        ws.repo,
        [...identity, "merge", "--no-ff", "--no-edit", "-m", `AgentEmpire: ${title} (${taskId})`, ws.branch],
        { allowFail: true },
      );
      if (merged.code !== 0) {
        const mergeHead = await this.git.run(ws.repo, ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], { allowFail: true });
        if (mergeHead.code === 0) await this.git.run(ws.repo, ["merge", "--abort"], { allowFail: true });
        return { blocked: "merge_failed" as const };
      }
      const commit = (await this.git.run(ws.repo, ["rev-parse", "HEAD"])).stdout.trim();
      await this.removeWorktree(ws, true);
      return { commit };
    });
  }

  /** Accepts without merging: the branch stays for the player; the worktree is removed. */
  async keepBranch(ws: TaskWorkspace): Promise<void> {
    await this.ctx.locks.run(`repo:${ws.repo}`, () => this.removeWorktree(ws, false));
  }

  /**
   * Plain-folder accept: writes the task's changes back to the source folder. All-or-nothing:
   * a file the player changed since the task started is a conflict and nothing is written.
   */
  async exportPlain(ws: TaskWorkspace): Promise<{ blocked?: MergeBlockedReason; written: number }> {
    if (ws.mode !== "plain_folder" || !ws.source || !ws.snapshot_sha) return { blocked: "not_a_repo", written: 0 };
    const source = ws.source;
    if (!existsSync(source)) return { blocked: "workspace_missing", written: 0 };
    const changes = parseNameStatusZ(
      (await this.git.run(ws.repo, ["diff", "--name-status", "-z", "--no-renames", ...diffRange(ws.base_sha, ws.snapshot_sha)])).stdout,
    );
    const plan: Array<{ target: string; content: Buffer | null }> = [];
    for (const c of changes) {
      const target = path.resolve(source, c.path);
      if (!isInside(target, source, this.platform)) return { blocked: "export_conflict", written: 0 };
      const current = readOrNull(target);
      const base = c.status === "added" ? null : await this.git.buffer(ws.repo, ["show", `${ws.base_sha}:${c.path}`]);
      const next = c.status === "deleted" ? null : await this.git.buffer(ws.repo, ["show", `${ws.snapshot_sha}:${c.path}`]);
      if (!sameFile(current, base) && !sameFile(current, next)) return { blocked: "export_conflict", written: 0 };
      plan.push({ target, content: next });
    }
    let written = 0;
    for (const p of plan) {
      if (p.content === null) {
        if (existsSync(p.target)) unlinkSync(p.target);
      } else {
        mkdirSync(path.dirname(p.target), { recursive: true });
        writeFileSync(p.target, p.content);
      }
      written++;
    }
    await this.ctx.locks.run(`repo:${ws.repo}`, () => this.removeWorktree(ws, false));
    return { written };
  }

  /** Unlocks and removes the worktree without force; a dirty worktree is left in place. */
  private async removeWorktree(ws: TaskWorkspace, deleteMergedBranch: boolean): Promise<boolean> {
    if (ws.removed) return true;
    if (existsSync(ws.worktree)) {
      await this.git.run(ws.repo, ["worktree", "unlock", ws.worktree], { allowFail: true });
      const r = await this.git.run(ws.repo, ["worktree", "remove", ws.worktree], { allowFail: true });
      if (r.code !== 0) {
        this.ctx.log.warn({ worktree: ws.worktree, err: r.stderr.trim() }, "worktree left in place");
        return false;
      }
    }
    if (deleteMergedBranch) await this.git.run(ws.repo, ["branch", "-d", ws.branch], { allowFail: true });
    ws.removed = true;
    return true;
  }

  /** Archives the branch tip under refs/agentempire/archive/<task>, then removes the workspace. */
  async discard(ws: TaskWorkspace, taskId: string, title: string): Promise<void> {
    await this.ctx.locks.run(`repo:${ws.repo}`, async () => {
      if (existsSync(ws.worktree) && !ws.removed) {
        await this.commitAll(await this.inWorktree(ws), ws.worktree, `AgentEmpire archive: ${title}`);
      }
      const tip = await this.git.run(ws.repo, ["rev-parse", "--verify", "--quiet", `refs/heads/${ws.branch}`], { allowFail: true });
      if (tip.code === 0) {
        const ref = `refs/agentempire/archive/${taskId}`;
        await this.git.run(ws.repo, ["update-ref", ref, tip.stdout.trim()]);
        ws.archived_ref = ref;
      }
      const removed = await this.removeWorktree(ws, false);
      if (removed && ws.archived_ref) await this.git.run(ws.repo, ["branch", "-D", ws.branch], { allowFail: true });
    });
  }
}
