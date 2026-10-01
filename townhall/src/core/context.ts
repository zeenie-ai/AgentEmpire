import type { Config } from "../config.js";
import type { Db } from "../db/db.js";
import type { Logger } from "../log.js";
import type { ProviderRegistry } from "../providers/registry.js";
import type { PathPolicy } from "../security/path-guard.js";
import type { Redactor } from "../security/redact.js";
import type { AgeService } from "./ages.js";
import type { AgentService } from "./agents.js";
import type { ApprovalService } from "./approvals.js";
import type { BountyService } from "./bounty.js";
import type { Clock } from "./clock.js";
import type { Economy } from "./economy.js";
import type { EventBus } from "./events.js";
import type { Ids } from "./ids.js";
import type { IncidentService } from "./incidents.js";
import type { KeyedLock } from "./locks.js";
import type { ManaService } from "./mana.js";
import type { PartyService } from "./parties.js";
import type { ProgressService } from "./progress.js";
import type { SettingsService } from "./settings.js";
import type { RunSupervisor } from "./tasks/run-supervisor.js";
import type { Scheduler } from "./tasks/scheduler.js";
import type { TaskService } from "./tasks/task-service.js";
import type { ToolService } from "./tools.js";
import type { TownService } from "./town.js";
import type { Treasury } from "./ledger.js";
import type { WorkspaceService } from "./workspace.js";

/** Whether a game client is connected; used by the `work_while_away` setting. */
export interface Presence {
  hasClient(): boolean;
}

/**
 * Every service, wired by the composition root (daemon.ts). Services keep a reference
 * to this object and look each other up at call time, which keeps construction order simple.
 */
export interface Ctx {
  config: Config;
  econ: Economy;
  db: Db;
  clock: Clock;
  ids: Ids;
  log: Logger;
  bus: EventBus;
  redactor: Redactor;
  pathPolicy: PathPolicy;
  locks: KeyedLock;
  presence: Presence;
  settings: SettingsService;
  town: TownService;
  treasury: Treasury;
  mana: ManaService;
  incidents: IncidentService;
  agents: AgentService;
  tools: ToolService;
  approvals: ApprovalService;
  bounty: BountyService;
  ages: AgeService;
  parties: PartyService;
  workspace: WorkspaceService;
  tasks: TaskService;
  scheduler: Scheduler;
  supervisor: RunSupervisor;
  providers: ProviderRegistry;
  progress: ProgressService;
}
