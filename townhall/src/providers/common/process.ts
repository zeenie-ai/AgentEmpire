import { execFile, spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { tailBytes } from "../../security/redact.js";
import type { Env, Launch } from "./exec.js";
import { encodeJsonl, JsonlDecoder } from "./jsonl.js";

const STDERR_TAIL_BYTES = 8 * 1024;

export interface ExitInfo {
  code: number | null;
  signal: NodeJS.Signals | null;
  /** Set when the process could not be started at all (for example ENOENT). */
  spawnError: string | null;
}

/**
 * Ends a process tree. On Windows `taskkill /T` walks the tree; without /F it only asks
 * (console programs usually refuse), with /F it terminates. On other systems the harness
 * runs in its own process group, which receives SIGTERM or SIGKILL.
 */
export function killTree(pid: number | undefined, force: boolean): Promise<void> {
  if (!pid) return Promise.resolve();
  if (process.platform === "win32") {
    return new Promise((resolve) => {
      execFile("taskkill", ["/pid", String(pid), "/T", ...(force ? ["/F"] : [])], { windowsHide: true }, () => resolve());
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

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
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
 */
export class HarnessProcess {
  readonly exited: Promise<ExitInfo>;
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly decoder: JsonlDecoder;
  private stderr = "";
  private inputOpen = true;
  private exitInfo: ExitInfo | null = null;

  constructor(launch: Launch, args: string[], opts: HarnessProcessOptions) {
    this.decoder = new JsonlDecoder(opts.onRecord, opts.onBadLine);
    this.child = spawn(launch.file, [...launch.prefix, ...args], {
      cwd: opts.cwd,
      env: opts.env as NodeJS.ProcessEnv,
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
      detached: process.platform !== "win32",
      shell: false,
    });
    let spawnError: string | null = null;
    this.exited = new Promise<ExitInfo>((resolve) => {
      this.child.once("error", (err: NodeJS.ErrnoException) => {
        spawnError = err.code ? `${err.code}: ${err.message}` : err.message;
        // 'close' may never follow a failed spawn.
        if (this.child.pid === undefined) {
          this.exitInfo = { code: null, signal: null, spawnError };
          resolve(this.exitInfo);
        }
      });
      this.child.once("close", (code, signal) => {
        this.decoder.end();
        this.inputOpen = false;
        this.exitInfo = { code, signal, spawnError };
        resolve(this.exitInfo);
      });
    });
    this.child.stdout.on("data", (chunk: Buffer) => this.decoder.push(chunk));
    this.child.stderr.on("data", (chunk: Buffer) => {
      const text = chunk.toString("utf8");
      this.stderr = tailBytes(this.stderr + text, STDERR_TAIL_BYTES);
      opts.onStderr?.(text);
    });
    // A harness that exits early makes writes fail with EPIPE; that surfaces through `exited`.
    this.child.stdin.on("error", () => {
      this.inputOpen = false;
    });
  }

  get pid(): number | undefined {
    return this.child.pid;
  }

  get running(): boolean {
    return this.exitInfo === null;
  }

  get acceptsInput(): boolean {
    return this.inputOpen && this.exitInfo === null;
  }

  /** The last few KB the harness wrote to stderr (not redacted). */
  stderrTail(): string {
    return this.stderr;
  }

  /** Writes one JSON Lines record. Returns false when stdin is already closed. */
  send(record: unknown): boolean {
    if (!this.acceptsInput) return false;
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
      this.child.stdin.end();
    } catch {
      // already closed
    }
  }

  private async waitExit(ms: number): Promise<boolean> {
    if (!this.running) return true;
    return Promise.race([this.exited.then(() => true), delay(ms).then(() => false)]);
  }

  /**
   * Stops the harness gracefully: close stdin and wait, then ask the process tree to end
   * (taskkill /T without /F on Windows, SIGTERM elsewhere), then force it. Resolves on exit.
   */
  async stop(graceMs: number): Promise<ExitInfo> {
    this.endInput();
    if (await this.waitExit(graceMs)) return this.exited;
    this.terminated = true;
    await killTree(this.pid, false);
    if (await this.waitExit(2_000)) return this.exited;
    await killTree(this.pid, true);
    await this.waitExit(5_000);
    return this.exitInfo ?? { code: null, signal: null, spawnError: null };
  }

  /** Ends the whole tree at once, before closing stdin so the harness gets no chance to carry on. */
  async kill(): Promise<void> {
    if (this.running) {
      this.terminated = true;
      await killTree(this.pid, true);
    }
    this.endInput();
    await this.waitExit(5_000);
  }

  /** True when the process had to be ended from outside rather than exiting on its own. */
  get forced(): boolean {
    return this.terminated;
  }

  private terminated = false;
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
    const finish = (code: number | null, error: string | null) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ code, stdout, stderr, timedOut, error });
    };
    let child: ReturnType<typeof spawn>;
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
    const timer = setTimeout(() => {
      timedOut = true;
      void killTree(child.pid, true);
      // Give taskkill a moment, then report regardless of whether 'close' arrives.
      setTimeout(() => finish(null, "timed out"), 1_000);
    }, opts.timeoutMs);
    child.stdout?.on("data", (d: Buffer) => {
      if (stdout.length < 1_000_000) stdout += d.toString("utf8");
    });
    child.stderr?.on("data", (d: Buffer) => {
      if (stderr.length < 100_000) stderr += d.toString("utf8");
    });
    child.stdin?.on("error", () => undefined);
    child.once("error", (err) => finish(null, err.message));
    child.once("close", (code) => finish(code, null));
    if (opts.input !== undefined) child.stdin?.end(opts.input);
    else child.stdin?.end();
  });
}
