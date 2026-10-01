import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import type { Server } from "node:http";
import net, { type AddressInfo } from "node:net";
import path from "node:path";
import { WebSocketServer } from "ws";
import type { Config } from "./config.js";
import { AgeService } from "./core/ages.js";
import { AgentService } from "./core/agents.js";
import { ApprovalService } from "./core/approvals.js";
import { BountyService } from "./core/bounty.js";
import { SystemClock, type Clock } from "./core/clock.js";
import type { Ctx } from "./core/context.js";
import { Economy } from "./core/economy.js";
import { EventBus } from "./core/events.js";
import { Ids } from "./core/ids.js";
import { IncidentService } from "./core/incidents.js";
import { Treasury } from "./core/ledger.js";
import { KeyedLock } from "./core/locks.js";
import { ManaService } from "./core/mana.js";
import { PartyService } from "./core/parties.js";
import { ProgressService } from "./core/progress.js";
import { SettingsService } from "./core/settings.js";
import { RunSupervisor } from "./core/tasks/run-supervisor.js";
import { Scheduler } from "./core/tasks/scheduler.js";
import { TaskService } from "./core/tasks/task-service.js";
import { ToolService } from "./core/tools.js";
import { TownService } from "./core/town.js";
import { WorkspaceService } from "./core/workspace.js";
import { openDb } from "./db/db.js";
import { createLogger, type Logger } from "./log.js";
import { srcPath } from "./paths.js";
import { MAX_FRAME_BYTES } from "./protocol/version.js";
import { FakeProvider } from "./providers/fake/adapter.js";
import { ScenarioLibrary } from "./providers/fake/scenarios.js";
import { harnessDeps, realAdapters } from "./providers/real.js";
import { ProviderRegistry } from "./providers/registry.js";
import type { ProviderAdapter } from "./providers/types.js";
import type { Provider } from "./protocol/objects.js";
import { buildPathPolicy } from "./security/path-guard.js";
import { Redactor } from "./security/redact.js";
import { generateToken } from "./security/token.js";
import { Broadcaster } from "./server/broadcaster.js";
import { buildHandlers } from "./server/handlers.js";
import { createHttpServer } from "./server/http.js";
import { Router } from "./server/router.js";
import { ConnectionManager } from "./server/ws.js";

export interface DaemonOptions {
  config: Config;
  clock?: Clock;
  log?: Logger;
  /** Overrides the scenario folder (tests). */
  scenarioDir?: string;
  /** Overrides the provider adapters (tests). */
  adapters?: Record<Provider, ProviderAdapter>;
  /**
   * Called once the `shutdown` command has stopped the Town Hall (main.ts exits the process).
   * Without it the daemon just stops.
   */
  onShutdown?: () => void;
}

export interface RuntimeInfo {
  pid: number;
  port: number;
  token: string;
  url: string;
  data_dir: string;
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === "EPERM";
  }
}

/** Whether something accepts connections on 127.0.0.1:`port` within `timeoutMs`. */
function portAnswers(port: unknown, timeoutMs = 1000): Promise<boolean> {
  return new Promise((resolve) => {
    if (typeof port !== "number" || !Number.isInteger(port) || port <= 0 || port > 65535) {
      resolve(false);
      return;
    }
    const socket = net.connect({ host: "127.0.0.1", port });
    const done = (answered: boolean) => {
      socket.destroy();
      resolve(answered);
    };
    socket.setTimeout(timeoutMs, () => done(false));
    socket.once("connect", () => done(true));
    socket.once("error", () => done(false));
  });
}

/**
 * Whether the Town Hall that wrote an existing runtime file still runs. Its process must be alive
 * and its port must answer: a Town Hall that was killed (or died with the computer) leaves its
 * runtime file behind, and the system may since have given its process id to another program.
 */
async function previousStillRuns(prev: Partial<RuntimeInfo>): Promise<boolean> {
  if (typeof prev.pid !== "number" || prev.pid === process.pid || !pidAlive(prev.pid)) return false;
  return portAnswers(prev.port);
}

function writeRuntime(file: string, info: RuntimeInfo): void {
  const tmp = `${file}.tmp`;
  writeFileSync(tmp, JSON.stringify(info, null, 2), { mode: 0o600 });
  renameSync(tmp, file);
}

export class Daemon {
  private stopping: Promise<void> | null = null;
  private shutdownRequested = false;
  private resolveStopped: () => void = () => undefined;
  /** Resolves once the Town Hall has stopped (by stop() or the `shutdown` command). */
  readonly stopped: Promise<void> = new Promise((resolve) => {
    this.resolveStopped = resolve;
  });

  private constructor(
    readonly ctx: Ctx,
    readonly port: number,
    readonly token: string,
    readonly url: string,
    readonly runtimeFile: string,
    private readonly server: Server,
    private readonly wss: WebSocketServer,
    private readonly connections: ConnectionManager,
    private readonly onShutdown: (() => void) | undefined,
  ) {}

  static async start(opts: DaemonOptions): Promise<Daemon> {
    const config = opts.config;
    const log = opts.log ?? createLogger(config.logLevel);
    mkdirSync(config.dataDir, { recursive: true });
    const runtimeFile = path.join(config.dataDir, "runtime.json");
    if (existsSync(runtimeFile)) {
      let prev: Partial<RuntimeInfo> | null = null;
      try {
        prev = JSON.parse(readFileSync(runtimeFile, "utf8")) as Partial<RuntimeInfo>;
      } catch {
        prev = null; // unreadable: a leftover, overwritten below
      }
      if (prev && (await previousStillRuns(prev))) {
        throw new Error(`another Town Hall (pid ${prev.pid}) is using ${config.dataDir}`);
      }
    }

    const econ = Economy.load(config.economyPath);
    const db = openDb(path.join(config.dataDir, "townhall.db"));
    const clock = opts.clock ?? new SystemClock();
    const ids = new Ids(clock);
    const bus = new EventBus(db, ids, clock);
    const token = generateToken();
    const redactor = new Redactor([token]);

    const ctx = {
      config,
      econ,
      db,
      clock,
      ids,
      log,
      bus,
      redactor,
      pathPolicy: buildPathPolicy({ workRoots: config.workRoots, dataDir: config.dataDir }),
      locks: new KeyedLock(),
      presence: { hasClient: () => false },
    } as Ctx;
    ctx.settings = new SettingsService(ctx);
    ctx.town = new TownService(ctx);
    ctx.treasury = new Treasury(ctx);
    ctx.mana = new ManaService(ctx);
    ctx.incidents = new IncidentService(ctx);
    ctx.tools = new ToolService(ctx);
    ctx.agents = new AgentService(ctx);
    ctx.approvals = new ApprovalService(ctx);
    ctx.bounty = new BountyService(ctx);
    ctx.ages = new AgeService(ctx);
    ctx.parties = new PartyService(ctx);
    ctx.workspace = new WorkspaceService(ctx);
    ctx.tasks = new TaskService(ctx);
    ctx.scheduler = new Scheduler(ctx);
    ctx.supervisor = new RunSupervisor(ctx);
    // Last, so its check runs after the other services' flushers in each round.
    ctx.progress = new ProgressService(ctx);

    let adapters = opts.adapters;
    if (!adapters) {
      if (config.providerMode === "fake") {
        const library = new ScenarioLibrary(opts.scenarioDir ?? srcPath("providers", "fake", "scenarios"));
        const fakeOpts = {
          library,
          defaultScenario: config.fakeDefaultScenario,
          microsPerMana: econ.data.mana.micros_per_mana,
        };
        adapters = {
          claude: new FakeProvider("claude", fakeOpts),
          codex: new FakeProvider("codex", fakeOpts),
          pi: new FakeProvider("pi", fakeOpts),
        };
      } else {
        // The installed harnesses: Claude Code, the Codex CLI and pi, each launched as a child process.
        adapters = realAdapters(
          harnessDeps({ econ: econ.data, dataDir: config.dataDir, pricingPath: config.pricingPath, log, redactor }),
        );
      }
    }
    ctx.providers = new ProviderRegistry(adapters, bus);

    ctx.treasury.init();
    await ctx.providers.refresh();
    ctx.mana.start();
    ctx.ages.start();
    ctx.tasks.recoverAfterRestart();
    ctx.agents.refreshAll();
    ctx.progress.start();

    const broadcaster = new Broadcaster(bus, ids, clock, log);
    let daemon: Daemon | null = null;
    const router = new Router(ctx, buildHandlers(ctx, { requestShutdown: () => daemon?.requestShutdown() }));
    const connections = new ConnectionManager(ctx, router, broadcaster, token);
    ctx.presence = { hasClient: () => connections.hasActiveClient() };
    const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME_BYTES, perMessageDeflate: false });

    let port = config.port;
    const server = createHttpServer({
      webDir: config.webDir,
      crossOriginIsolation: config.crossOriginIsolation,
      devOrigins: config.devOrigins,
      log,
      port: () => port,
      onUpgrade: (req, socket, head) => wss.handleUpgrade(req, socket, head, (ws) => connections.handle(ws, req)),
    });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(config.port, config.host, () => {
        server.off("error", reject);
        resolve();
      });
    });
    port = (server.address() as AddressInfo).port;
    const url = `http://127.0.0.1:${port}/#t=${token}`;
    const runtime: RuntimeInfo = { pid: process.pid, port, token, url, data_dir: config.dataDir };
    writeRuntime(runtimeFile, runtime);
    if (config.discoveryFile) {
      try {
        mkdirSync(path.dirname(config.discoveryFile), { recursive: true });
        writeRuntime(config.discoveryFile, runtime);
      } catch (err) {
        log.warn({ file: config.discoveryFile, err: String(err) }, "could not write the discovery file");
      }
    }
    log.info({ port, dataDir: config.dataDir, provider: config.providerMode }, "Town Hall listening");

    daemon = new Daemon(ctx, port, token, url, runtimeFile, server, wss, connections, opts.onShutdown);
    ctx.scheduler.kick();
    return daemon;
  }

  /**
   * The `shutdown` command: once the reply has gone out, stop as a clean exit does (running tasks
   * pause and resume on the next start), then tell the owner, which exits the process.
   */
  requestShutdown(): void {
    if (this.shutdownRequested) return;
    this.shutdownRequested = true;
    this.ctx.log.info("shutdown requested by the client");
    setImmediate(() => {
      this.stop().then(
        () => this.onShutdown?.(),
        (err: unknown) => {
          this.ctx.log.error({ err: String(err) }, "shutdown failed");
          this.onShutdown?.();
        },
      );
    });
  }

  /** Stops the Town Hall. Calling it again returns the same promise. */
  stop(): Promise<void> {
    this.stopping ??= this.doStop().finally(() => this.resolveStopped());
    return this.stopping;
  }

  private async doStop(): Promise<void> {
    const ctx = this.ctx;
    ctx.scheduler.stop();
    // Tells every client (daemon_shutdown), closes their sockets and refuses new ones.
    this.connections.closeAll();
    await ctx.supervisor.shutdown();
    ctx.tasks.stop();
    ctx.mana.stop();
    ctx.ages.stop();
    ctx.progress.stop();
    // Give the clients a moment to complete the close handshake before cutting what is left.
    await this.connections.waitClosed(1_000);
    for (const client of this.wss.clients) client.terminate();
    this.wss.close();
    await new Promise<void>((resolve) => {
      this.server.close(() => resolve());
      this.server.closeAllConnections();
    });
    // Let in-flight async work (git, finalisation) settle before closing the database.
    await new Promise((r) => setTimeout(r, 50));
    ctx.db.close();
    for (const file of [this.runtimeFile, ctx.config.discoveryFile]) {
      if (!file) continue;
      try {
        const current = JSON.parse(readFileSync(file, "utf8")) as Partial<RuntimeInfo>;
        if (current.pid === process.pid && current.port === this.port) unlinkSync(file);
      } catch {
        // already gone
      }
    }
  }
}
