import { execFile, spawn, type ChildProcess, type ChildProcessWithoutNullStreams } from "node:child_process";
import path from "node:path";
import { tailBytes } from "../../security/redact.js";
import type { Env, Launch } from "./exec.js";
import { encodeJsonl, JsonlDecoder } from "./jsonl.js";

const STDERR_TAIL_BYTES = 8 * 1024;
/** How long stdout and stderr may stay open after the harness process itself has exited. */
const DRAIN_MS = 2_000;

export interface ExitInfo {
  code: number | null;
  signal: NodeJS.Signals | null;
  /** Set when the process could not be started at all (for example ENOENT). */
  spawnError: string | null;
}

/** taskkill from System32, never whatever else PATH finds first. */
function taskkillPath(): string {
  return path.join(process.env.SystemRoot ?? process.env.windir ?? "C:\\Windows", "System32", "taskkill.exe");
}

/**
 * Ends a process tree. On Windows `taskkill /T` walks the tree; without /F it only asks
 * (console programs usually refuse), with /F it terminates. On other systems the harness
 * runs in its own process group, which receives SIGTERM or SIGKILL. Callers signal only a
 * process they know is still running: once it has exited, its id can belong to another one.
 */
export function killTree(pid: number | undefined, force: boolean): Promise<void> {
  if (!pid) return Promise.resolve();
  if (process.platform === "win32") {
    return new Promise((resolve) => {
      execFile(taskkillPath(), ["/pid", String(pid), "/T", ...(force ? ["/F"] : [])], { windowsHide: true, timeout: 10_000 }, () => resolve());
    });
  }
  try {
    process.kill(-pid, force ? "SIGKILL" : "SIGTERM");
  } catch {
    try {
      process.kill(pid, force ? "SIGKILL" : "SIGTERM");
    } catch {
      // already gone
    }
  }
  return Promise.resolve();
}

/** Waits until the first of `promises` settles or `ms` passes, whichever is sooner, and clears its timer. */
export async function waitAny(promises: Array<Promise<unknown>>, ms: number): Promise<void> {
  let timer: NodeJS.Timeout | undefined;
  try {
    await Promise.race([
      ...promises.map((p) => p.then(() => undefined, () => undefined)),
      new Promise<void>((resolve) => {
        timer = setTimeout(resolve, ms);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function errorText(err: unknown): string {
  if (err instanceof Error) {
    const code = (err as NodeJS.ErrnoException).code;
    return code ? `${code}: ${err.message}` : err.message;
  }
  return String(err);
}

function destroyStdio(child: ChildProcess): void {
  child.stdin?.destroy();
  child.stdout?.destroy();
  child.stderr?.destroy();
}

export interface HarnessProcessOptions {
  cwd: string;
  env: Env;
  onRecord: (record: unknown) => void;
  /** Non-JSON lines on stdout (warnings some harnesses print). */
  onBadLine?: (line: string) => void;
  onStderr?: (text: string) => void;
}

/**
 * A harness child process speaking JSON Lines on stdin and stdout. Spawned directly (never
 * through a shell), with a hidden console on Windows and its own process group elsewhere.
 * Constructing one never throws: a launch that fails shows up in `exited` as a spawnError.
 */
export class HarnessProcess {
  /** Resolves once the process has exited and its output has been read (or given up on). */
  readonly exited: Promise<ExitInfo>;
  private readonly child: ChildProcessWithoutNullStreams | null = null;
  private readonly decoder: JsonlDecoder;
  /** Resolves as soon as the process itself is gone. */
  private readonly gone: Promise<void>;
  private markGone: () => void = () => undefined;
  private settle: (info: ExitInfo) => void = () => undefined;
  private stderr = "";
  private inputOpen = false;
  private alive = false;
  private exitInfo: ExitInfo | null = null;
  private terminated = false;

  constructor(launch: Launch, args: string[], opts: HarnessProcessOptions) {
    this.decoder = new JsonlDecoder(opts.onRecord, opts.onBadLine);
    this.gone = new Promise<void>((resolve) => {
      this.markGone = resolve;
    });
    this.exited = new Promise<ExitInfo>((resolve) => {
      this.settle = (info) => {
        if (this.exitInfo) return;
        this.alive = false;
        this.inputOpen = false;
        this.markGone();
        this.decoder.end();
        this.exitInfo = info;
        resolve(info);
      };
    });

    let child: ChildProcessWithoutNullStreams;
    try {
      child = spawn(launch.file, [...launch.prefix, ...args], {
        cwd: opts.cwd,
        env: opts.env as NodeJS.ProcessEnv,
        stdio: ["pipe", "pipe", "pipe"],
        windowsHide: true,
        detached: process.platform !== "win32",
        shell: false,
      });
    } catch (err) {
      // Some bad launches throw at once (EINVAL, for example) instead of emitting 'error'.
      this.settle({ code: null, signal: null, spawnError: errorText(err) });
      return;
    }
    this.child = child;
    this.alive = true;
    this.inputOpen = true;

    let exit: { code: number | null; signal: NodeJS.Signals | null } | null = null;
    let drain: NodeJS.Timeout | null = null;
    child.on("error", (err) => {
      // Only a failed start ends the process here; any later error (a failed signal) changes nothing.
      if (child.pid === undefined) this.settle({ code: null, signal: null, spawnError: errorText(err) });
    });
    child.once("exit", (code, signal) => {
      exit = { code, signal };
      this.alive = false;
      this.inputOpen = false;
      this.markGone();
      // stdout and stderr normally close right after the exit. On Windows a program the harness
      // started (a dev server, a build server) inherits them and can hold them open long after
      // the harness is gone: read what is left for a moment, then stop waiting for them.
      drain = setTimeout(() => {
        destroyStdio(child);
        this.settle({ code, signal, spawnError: null });
      }, DRAIN_MS);
    });
    child.once("close", (code, signal) => {
      if (drain) clearTimeout(drain);
      this.settle({ code: exit ? exit.code : code, signal: exit ? exit.signal : signal, spawnError: null });
    });
    child.stdout.on("data", (chunk: Buffer) => this.decoder.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => {
      const text = chunk.toString("utf8");
      this.stderr = tailBytes(this.stderr + text, STDERR_TAIL_BYTES);
      opts.onStderr?.(text);
    });
    child.stdout.on("error", () => undefined);
    child.stderr.on("error", () => undefined);
    // A harness that exits early makes writes fail with EPIPE; that surfaces through `exited`.
    child.stdin.on("error", () => {
      this.inputOpen = false;
    });
  }

  get pid(): number | undefined {
    return this.child?.pid;
  }

  /** False once the process has exited (its output may still be draining). */
  get running(): boolean {
    return this.alive;
  }

  get acceptsInput(): boolean {
    return this.inputOpen && this.alive;
  }

  /** The last few KB the harness wrote to stderr (not redacted). */
  stderrTail(): string {
    return this.stderr;
  }

  /** Writes one JSON Lines record. Returns false when stdin is already closed. */
  send(record: unknown): boolean {
    if (!this.acceptsInput || !this.child) return false;
    try {
      this.child.stdin.write(encodeJsonl(record));
      return true;
    } catch {
      this.inputOpen = false;
      return false;
    }
  }

  /** Closes stdin: every harness here treats end of input as a request to finish and exit. */
  endInput(): void {
    if (!this.inputOpen) return;
    this.inputOpen = false;
    try {
      this.child?.stdin.end();
    } catch {
      // already closed
    }
  }

  /** True once the process is gone, false when `ms` passed first. */
  private async waitGone(ms: number): Promise<boolean> {
    if (!this.alive) return true;
    let gone = false;
    await waitAny(
      [
        this.gone.then(() => {
          gone = true;
        }),
      ],
      ms,
    );
    return gone || !this.alive;
  }

  /**
   * Stops the harness gracefully: close stdin and wait, then ask the process tree to end
   * (taskkill /T without /F on Windows, SIGTERM elsewhere), then force it. Resolves on exit.
   */
  async stop(graceMs: number): Promise<ExitInfo> {
    this.endInput();
    if (!(await this.waitGone(graceMs))) {
      if (this.alive) await killTree(this.pid, false);
      if (!(await this.waitGone(2_000))) await this.forceEnd();
    }
    return this.exited;
  }

  /** Ends the whole tree at once, before closing stdin so the harness gets no chance to carry on. */
  async kill(): Promise<void> {
    await this.forceEnd();
    this.endInput();
    await this.exited;
  }

  /**
   * Terminates the process tree if the process is still running. Always ends with the process
   * gone or given up on, so `exited` resolves and the run can finish.
   */
  private async forceEnd(): Promise<void> {
    if (!this.alive) return;
    // Set only when a hard kill really reaches a running process: a harness that exits on its
    // own (even after a polite request) had the chance to save its session.
    this.terminated = true;
    await killTree(this.pid, true);
    if (await this.waitGone(5_000)) return;
    // taskkill could not end it: terminate at least the direct child.
    try {
      this.child?.kill("SIGKILL");
    } catch {
      // nothing more to try
    }
    if (await this.waitGone(2_000)) return;
    // Nothing more can be done from here: stop waiting for it so the run can end.
    if (this.child) destroyStdio(this.child);
    this.settle({ code: null, signal: null, spawnError: null });
  }

  /** True when the process had to be ended with a hard kill rather than exiting on its own. */
  get forced(): boolean {
    return this.terminated;
  }
}

export interface CaptureResult {
  code: number | null;
  stdout: string;
  stderr: string;
  timedOut: boolean;
  error: string | null;
}

/** Runs a short command (a probe) to completion without a shell. Never throws. */
export function runCapture(launch: Launch, args: string[], opts: { env: Env; cwd?: string; timeoutMs: number; input?: string }): Promise<CaptureResult> {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let settled = false;
    let exited = false;
    const timers: NodeJS.Timeout[] = [];
    const finish = (code: number | null, error: string | null) => {
      if (settled) return;
      settled = true;
      for (const t of timers) clearTimeout(t);
      resolve({ code, stdout, stderr, timedOut, error });
    };
    let child: ChildProcess;
    try {
      child = spawn(launch.file, [...launch.prefix, ...args], {
        cwd: opts.cwd,
        env: opts.env as NodeJS.ProcessEnv,
        stdio: ["pipe", "pipe", "pipe"],
        windowsHide: true,
        detached: process.platform !== "win32",
        shell: false,
      });
    } catch (err) {
      resolve({ code: null, stdout, stderr, timedOut, error: err instanceof Error ? err.message : String(err) });
      return;
    }
    timers.push(
      setTimeout(() => {
        timedOut = true;
        if (!exited) void killTree(child.pid, true);
        // Give taskkill a moment, then report regardless of whether 'close' arrives.
        timers.push(
          setTimeout(() => {
            destroyStdio(child);
            finish(null, "timed out");
          }, 1_000),
        );
      }, opts.timeoutMs),
    );
    child.stdout?.on("data", (d: Buffer) => {
      if (stdout.length < 1_000_000) stdout += d.toString("utf8");
    });
    child.stderr?.on("data", (d: Buffer) => {
      if (stderr.length < 100_000) stderr += d.toString("utf8");
    });
    child.stdout?.on("error", () => undefined);
    child.stderr?.on("error", () => undefined);
    child.stdin?.on("error", () => undefined);
    child.on("error", (err) => {
      if (child.pid === undefined) finish(null, err.message);
    });
    child.once("exit", (code) => {
      exited = true;
      // A leftover grandchild can hold the pipes open (Windows): do not wait for it long.
      timers.push(
        setTimeout(() => {
          destroyStdio(child);
          finish(code, null);
        }, 1_000),
      );
    });
    child.once("close", (code) => finish(code, null));
    if (opts.input !== undefined) child.stdin?.end(opts.input);
    else child.stdin?.end();
  });
}
