import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import WebSocket from "ws";
import { loadConfig, type Config } from "../../src/config.js";
import { TestClock } from "../../src/core/clock.js";
import { Daemon } from "../../src/daemon.js";
import { silentLogger } from "../../src/log.js";
import type { Provider } from "../../src/protocol/objects.js";
import type { ProviderAdapter } from "../../src/providers/types.js";

export interface Reply {
  v: 1;
  type: string;
  request_id: string;
  ok: boolean;
  payload?: any;
  error?: { code: string; message: string; retryable: boolean };
}

export interface Ev {
  v: 1;
  type: string;
  seq: number;
  id: string;
  time: string;
  subject: string | null;
  causation_id: string | null;
  payload: any;
}

export function tempRoot(label: string): string {
  return mkdtempSync(path.join(os.tmpdir(), `aurelhaven-${label}-`));
}

export function removeRoot(root: string): void {
  try {
    rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  } catch {
    // Windows may still hold a handle for a moment; temp folders are cleaned by the OS eventually.
  }
}

export class TestClient {
  readonly events: Ev[] = [];
  private readonly pending = new Map<string, (r: Reply) => void>();
  private readonly waiters = new Set<{ pred: (e: Ev) => boolean; resolve: (e: Ev) => void }>();
  private counter = 0;
  closeInfo: { code: number; reason: string } | null = null;
  readonly closed: Promise<{ code: number; reason: string }>;

  private constructor(readonly ws: WebSocket) {
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as Reply & Ev;
      if (typeof msg.seq === "number" && msg.request_id === undefined) {
        this.events.push(msg);
        for (const w of [...this.waiters]) {
          if (w.pred(msg)) {
            this.waiters.delete(w);
            w.resolve(msg);
          }
        }
      } else if (typeof msg.request_id === "string") {
        const resolve = this.pending.get(msg.request_id);
        if (resolve) {
          this.pending.delete(msg.request_id);
          resolve(msg);
        }
      }
    });
    this.closed = new Promise((resolve) => {
      ws.on("close", (code, reason) => {
        this.closeInfo = { code, reason: reason.toString() };
        resolve(this.closeInfo);
      });
    });
  }

  static connect(port: number, opts: { origin?: string; host?: string } = {}): Promise<TestClient> {
    const headers: Record<string, string> = {};
    if (opts.origin !== undefined) headers.Origin = opts.origin;
    if (opts.host !== undefined) headers.Host = opts.host;
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`, { headers });
    return new Promise((resolve, reject) => {
      ws.once("open", () => resolve(new TestClient(ws)));
      ws.once("error", reject);
    });
  }

  send(type: string, payload: unknown, requestId?: string, timeoutMs = 30_000): Promise<Reply> {
    const id = requestId ?? `t-${++this.counter}`;
    this.ws.send(JSON.stringify({ v: 1, type, request_id: id, payload }));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`no reply to ${type} within ${timeoutMs} ms`));
      }, timeoutMs);
      this.pending.set(id, (r) => {
        clearTimeout(timer);
        resolve(r);
      });
    });
  }

  async ok<T = any>(type: string, payload: unknown = {}, requestId?: string): Promise<T> {
    const r = await this.send(type, payload, requestId);
    if (!r.ok) throw new Error(`${type} failed: ${r.error?.code} ${r.error?.message}`);
    return r.payload as T;
  }

  hello(token: string, extra: Record<string, unknown> = {}): Promise<Reply> {
    return this.send("hello", {
      token,
      protocol: { major: 1, minor: 0 },
      client: { name: "vitest", version: "0.0.0", platform: "desktop" },
      ...extra,
    });
  }

  /** Resolves with the first buffered or future event matching `pred`. */
  waitEvent(pred: (e: Ev) => boolean, timeoutMs = 20_000, label = "event"): Promise<Ev> {
    const found = this.events.find(pred);
    if (found) return Promise.resolve(found);
    return new Promise((resolve, reject) => {
      const waiter = {
        pred,
        resolve: (e: Ev) => {
          clearTimeout(timer);
          resolve(e);
        },
      };
      const timer = setTimeout(() => {
        this.waiters.delete(waiter);
        reject(new Error(`timed out waiting for ${label}`));
      }, timeoutMs);
      this.waiters.add(waiter);
    });
  }

  /** Waits for an event matching `pred` that arrives after the current last event. */
  nextEvent(pred: (e: Ev) => boolean, timeoutMs = 20_000, label = "event"): Promise<Ev> {
    const after = this.lastSeq();
    return this.waitEvent((e) => e.seq > after && pred(e), timeoutMs, label);
  }

  waitTask(taskId: string, state: string, timeoutMs = 20_000): Promise<Ev> {
    return this.waitEvent(
      (e) => e.type === "task_updated" && e.payload.task.id === taskId && e.payload.task.state === state,
      timeoutMs,
      `task ${taskId} -> ${state}`,
    );
  }

  lastSeq(): number {
    return this.events.length ? this.events[this.events.length - 1]!.seq : 0;
  }

  close(): Promise<{ code: number; reason: string }> {
    this.ws.close();
    return this.closed;
  }
}

export interface TownOptions {
  root?: string;
  clock?: TestClock;
  config?: Partial<Config>;
  /** Real (or custom) provider adapters instead of the scripted ones; built once the paths are known. */
  adapters?: (paths: { root: string; dataDir: string; work: string }) => Record<Provider, ProviderAdapter>;
}

export class TestTown {
  private constructor(
    public daemon: Daemon,
    readonly root: string,
    readonly work: string,
    readonly clock: TestClock,
    readonly config: Config,
  ) {}

  static async start(label: string, opts: TownOptions = {}): Promise<TestTown> {
    const root = opts.root ?? tempRoot(label);
    const work = path.join(root, "work");
    mkdirSync(work, { recursive: true });
    const clock = opts.clock ?? new TestClock();
    const config = loadConfig(
      {},
      {
        dataDir: path.join(root, "data"),
        webDir: path.join(root, "web"),
        port: 0,
        workRoots: [work],
        logLevel: "silent",
        riteTimeoutMs: 60_000,
        ...opts.config,
      },
    );
    const adapters = opts.adapters?.({ root, dataDir: config.dataDir, work });
    const daemon = await Daemon.start({ config, clock, log: silentLogger(), ...(adapters ? { adapters } : {}) });
    return new TestTown(daemon, root, work, clock, config);
  }

  get port(): number {
    return this.daemon.port;
  }

  get token(): string {
    return this.daemon.token;
  }

  get ctx() {
    return this.daemon.ctx;
  }

  async client(extra: Record<string, unknown> = {}): Promise<TestClient> {
    const c = await TestClient.connect(this.port);
    const r = await c.hello(this.token, extra);
    if (!r.ok) throw new Error(`hello failed: ${r.error?.code}`);
    return c;
  }

  /** Stops the daemon (as a crash would leave it) and starts a new one on the same data. */
  async restart(): Promise<void> {
    await this.daemon.stop();
    this.daemon = await Daemon.start({ config: this.config, clock: this.clock, log: silentLogger() });
  }

  async stop(remove = true): Promise<void> {
    await this.daemon.stop();
    if (remove) removeRoot(this.root);
  }
}

export interface AgentSetup {
  name?: string;
  role?: string;
  provider?: "claude" | "codex" | "pi";
  model?: string;
  workspace: string;
  approval_mode?: string;
  tools?: string[];
  tile?: { x: number; y: number };
}

/** Summons an agent through the protocol and waits until it is active. */
export async function summonAgent(c: TestClient, spec: AgentSetup): Promise<string> {
  const role = spec.role ?? "artificer";
  const created = await c.ok("create_agent", {
    spec: {
      name: spec.name ?? "Mira",
      provider: spec.provider ?? "claude",
      model: spec.model ?? (spec.provider === "pi" ? "fake/pi" : "fake-claude"),
      role,
      instructions: "Be careful.",
      approval_mode: spec.approval_mode ?? "trusted_edits",
      workspace: { path: spec.workspace },
      starting_tools: spec.tools ?? ["lectern", "quillworks"],
    },
  });
  const agentId = created.agent_id as string;
  await c.ok("agent_trained", { agent_id: agentId });
  await c.ok("place_home", { agent_id: agentId, tile: spec.tile ?? { x: 40, y: 52 } });
  await c.ok("home_built", { agent_id: agentId });
  let i = 0;
  for (const type of spec.tools ?? ["lectern", "quillworks"]) {
    const t = await c.ok("attach_tool", { agent_id: agentId, type, tile: { x: 42 + i, y: 50 } });
    await c.ok("tool_built", { tool_id: t.tool_id });
    i++;
  }
  await c.waitEvent(
    (e) => e.type === "agent_updated" && e.payload.agent.id === agentId && e.payload.agent.lifecycle === "active",
    20_000,
    `agent ${agentId} active`,
  );
  return agentId;
}

export function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
