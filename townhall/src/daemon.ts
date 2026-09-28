import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
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
import { ClaudeAdapter } from "./providers/claude/adapter.js";
import { CodexAdapter } from "./providers/codex/adapter.js";
import { FakeProvider } from "./providers/fake/adapter.js";
import { ScenarioLibrary } from "./providers/fake/scenarios.js";
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
}

export interface RuntimeInfo {
  pid: number;
  port: number;
  token: string;
  url: string;
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === "EPERM";
  }
}

function writeRuntime(file: string, info: RuntimeInfo): void {
  const tmp = `${file}.tmp`;
  writeFileSync(tmp, JSON.stringify(info, null, 2), { mode: 0o600 });
  renameSync(tmp, file);
}

export class Daemon {
  private constructor(
    readonly ctx: Ctx,
    readonly port: number,
    readonly token: string,
    readonly url: string,
    readonly runtimeFile: string,
    private readonly server: Server,
    private readonly wss: WebSocketServer,
    private readonly connections: ConnectionManager,
  ) {}

  static async start(opts: DaemonOptions): Promise<Daemon> {
    const config = opts.config;
    const log = opts.log ?? createLogger(config.logLevel);
    mkdirSync(config.dataDir, { recursive: true });
    const runtimeFile = path.join(config.dataDir, "runtime.json");
    if (existsSync(runtimeFile)) {
      try {
        const prev = JSON.parse(readFileSync(runtimeFile, "utf8")) as Partial<RuntimeInfo>;
        if (typeof prev.pid === "number" && prev.pid !== process.pid && pidAlive(prev.pid)) {
          throw new Error(`another Town Hall (pid ${prev.pid}) is using ${config.dataDir}`);
        }
      } catch (err) {
        if (err instanceof Error && err.message.startsWith("another Town Hall")) throw err;
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

    let adapters = opts.adapters;
    if (!adapters) {
      if (config.providerMode === "fake") {
        const library = new ScenarioLibrary(opts.scenarioDir ?? srcPath("providers", "fake", "scenarios"));
        const fakeOpts = {
          library,
          defaultScenario: config.fakeDefaultScenario,
          microsPerMana: econ.data.mana.micros_per_mana,
        };
        adapters = { claude: new FakeProvider("claude", fakeOpts), codex: new FakeProvider("codex", fakeOpts) };
      } else {
        adapters = { claude: new ClaudeAdapter(), codex: new CodexAdapter() };
      }
    }
    ctx.providers = new ProviderRegistry(adapters, bus);

    ctx.treasury.init();
    await ctx.providers.refresh();
    ctx.mana.start();
    ctx.ages.start();
    ctx.tasks.recoverAfterRestart();
    ctx.agents.refreshAll();

    const broadcaster = new Broadcaster(bus, ids, clock, log);
    const router = new Router(ctx, buildHandlers(ctx));
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
    writeRuntime(runtimeFile, { pid: process.pid, port, token, url });
    log.info({ port, dataDir: config.dataDir, provider: config.providerMode }, "Town Hall listening");

    const daemon = new Daemon(ctx, port, token, url, runtimeFile, server, wss, connections);
    ctx.scheduler.kick();
    return daemon;
  }

  private stopped = false;

  async stop(): Promise<void> {
    if (this.stopped) return;
    this.stopped = true;
    const ctx = this.ctx;
    ctx.scheduler.stop();
    this.connections.closeAll();
    await ctx.supervisor.shutdown();
    ctx.tasks.stop();
    ctx.mana.stop();
    ctx.ages.stop();
    for (const client of this.wss.clients) client.terminate();
    this.wss.close();
    await new Promise<void>((resolve) => {
      this.server.close(() => resolve());
      this.server.closeAllConnections();
    });
    // Let in-flight async work (git, finalisation) settle before closing the database.
    await new Promise((r) => setTimeout(r, 50));
    ctx.db.close();
    try {
      const current = JSON.parse(readFileSync(this.runtimeFile, "utf8")) as Partial<RuntimeInfo>;
      if (current.pid === process.pid && current.port === this.port) unlinkSync(this.runtimeFile);
    } catch {
      // already gone
    }
  }
}
