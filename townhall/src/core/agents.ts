import { fromJson, toJson } from "../db/db.js";
import { fail } from "../protocol/errors.js";
import type {
  Agent,
  AgentActivity,
  AgentLifecycle,
  AgentStats,
  ApprovalMode,
  Billing,
  BlockedReason,
  Provider,
  Role,
  Seals,
  Tile,
  ToolType,
} from "../protocol/objects.js";
import { displayPath, validateWorkFolder } from "../security/path-guard.js";
import type { Ctx } from "./context.js";
import { scaleCost, toResources, zeroResources, type Resources } from "./economy.js";
import type { DirtySet } from "./events.js";
import { computeRank, median, rankAtLeast } from "./ranks.js";

export interface AgentRow {
  id: string;
  name: string;
  provider: Provider;
  model: string;
  role: Role;
  instructions: string;
  approval_mode: ApprovalMode;
  workspace_path: string;
  workspace_mode: "git_worktree" | "plain_folder";
  repo_root: string | null;
  workspace_sub: string;
  mirror_path: string | null;
  workspace_ready: number;
  workspace_error: string | null;
  seals_json: string;
  billing: Billing;
  lifecycle: AgentLifecycle;
  activity: AgentActivity;
  blocked_reason: BlockedReason | null;
  home_tile_json: string | null;
  home_built: number;
  xp: number;
  level: number;
  rank: string;
  stats_json: string;
  party_id: string | null;
  grace: number;
  cost_json: string;
  starting_tools_json: string;
  retire_after_current: number;
  version: number;
  created_at: string;
  retired_at: string | null;
}

export interface CreateAgentSpec {
  name: string;
  provider: Provider;
  model: string;
  role: Role;
  instructions: string;
  approval_mode?: ApprovalMode | undefined;
  workspace: { path: string };
  seals?: Partial<Seals> | undefined;
  billing?: Billing | undefined;
  starting_tools: ToolType[];
}

export interface AgentPatch {
  name?: string | undefined;
  model?: string | undefined;
  instructions?: string | undefined;
  approval_mode?: ApprovalMode | undefined;
  seals?: Partial<Seals> | undefined;
}

const EMPTY_STATS: AgentStats = {
  accepted: 0,
  accepted_first_try: 0,
  sent_back: 0,
  failed: 0,
  rites_passed: 0,
  party_tasks: 0,
  mana_spent_micros: 0,
};

const ACTIVE_TASK_STATES = "('preparing','running','awaiting_approval')";

export class AgentService {
  private readonly dirty: DirtySet;

  constructor(private readonly ctx: Ctx) {
    this.dirty = ctx.bus.newDirtySet();
    ctx.bus.addFlusher(() => this.flush());
  }

  markDirty(agentId: string): void {
    if (this.ctx.db.inTx()) this.dirty.add(agentId);
    else this.ctx.db.tx(() => this.dirty.add(agentId));
  }

  private flush(): boolean {
    const ids = this.dirty.take();
    for (const id of ids) {
      const row = this.rowOrNull(id);
      if (!row) continue;
      const s = this.computeStatus(row);
      this.ctx.db.run(
        "UPDATE agents SET lifecycle = ?, activity = ?, blocked_reason = ?, version = version + 1 WHERE id = ?",
        [s.lifecycle, s.activity, s.blocked_reason, id],
      );
      const agent = this.toProtocol(this.row(id));
      this.ctx.bus.emit("agent_updated", { agent }, `agent/${id}`);
    }
    return ids.length > 0;
  }

  rowOrNull(id: string): AgentRow | null {
    return this.ctx.db.get<AgentRow>("SELECT * FROM agents WHERE id = ?", [id]) ?? null;
  }

  row(id: string): AgentRow {
    const r = this.rowOrNull(id);
    if (!r) throw fail.notFound("agent", id);
    return r;
  }

  seals(r: AgentRow): Seals {
    return fromJson<Seals>(r.seals_json, this.defaultSeals());
  }

  stats(r: AgentRow): AgentStats {
    return { ...EMPTY_STATS, ...fromJson<Partial<AgentStats>>(r.stats_json, {}) };
  }

  private defaultSeals(): Seals {
    const s = this.ctx.econ.data.mana.seal_by_size;
    return { S: s.S, M: s.M, L: s.L, XL: s.XL };
  }

  currentTaskId(agentId: string): string | null {
    return (
      this.ctx.db.get<{ id: string }>(
        `SELECT id FROM tasks WHERE agent_id = ? AND state IN ${ACTIVE_TASK_STATES} ORDER BY started_at LIMIT 1`,
        [agentId],
      )?.id ?? null
    );
  }

  queue(agentId: string): string[] {
    return this.ctx.db
      .all<{ id: string }>(
        "SELECT id FROM tasks WHERE agent_id = ? AND state IN ('in_transit','queued') ORDER BY queue_pos ASC, created_at ASC",
        [agentId],
      )
      .map((r) => r.id);
  }

  toProtocol(r: AgentRow): Agent {
    const tile = fromJson<Tile | null>(r.home_tile_json, null);
    return {
      id: r.id,
      name: r.name,
      provider: r.provider,
      model: r.model,
      role: r.role,
      instructions: r.instructions,
      approval_mode: r.approval_mode,
      workspace: {
        path: displayPath(r.workspace_path),
        mode: r.workspace_mode,
        repo_root: r.repo_root ? displayPath(r.repo_root) : null,
      },
      seals: this.seals(r),
      billing: r.billing,
      lifecycle: r.lifecycle,
      activity: r.activity,
      blocked_reason: r.blocked_reason,
      home: tile ? { tile, built: r.home_built === 1 } : null,
      tool_ids: this.ctx.tools.idsForAgent(r.id),
      starting_tools: fromJson<ToolType[]>(r.starting_tools_json, []),
      current_task_id: this.currentTaskId(r.id),
      queue: this.queue(r.id),
      xp: r.xp,
      level: r.level,
      rank: r.rank,
      stats: this.stats(r),
      party_id: r.party_id,
      version: r.version,
      created_at: r.created_at,
    };
  }

  get(id: string): Agent {
    return this.toProtocol(this.row(id));
  }

  list(): Agent[] {
    return this.ctx.db.all<AgentRow>("SELECT * FROM agents ORDER BY created_at ASC").map((r) => this.toProtocol(r));
  }

  nonRetiredCount(): number {
    return this.ctx.db.get<{ n: number }>("SELECT COUNT(*) AS n FROM agents WHERE retired_at IS NULL")?.n ?? 0;
  }

  /** Lifecycle, activity and blocked reason derived from tools, tasks, Mana and the provider. */
  private computeStatus(r: AgentRow): { lifecycle: AgentLifecycle; activity: AgentActivity; blocked_reason: BlockedReason | null } {
    if (r.retired_at) return { lifecycle: "retired", activity: "idle", blocked_reason: null };
    if (r.lifecycle === "training") return { lifecycle: "training", activity: "idle", blocked_reason: null };
    const toolsOk = this.ctx.tools.requiredToolsActive(r.id, r.role);
    let lifecycle: AgentLifecycle = r.lifecycle;
    if (lifecycle === "settling" && r.home_built === 1 && toolsOk && r.workspace_ready === 1) lifecycle = "active";
    const currentId = this.currentTaskId(r.id);
    if (currentId) {
      const state = this.ctx.db.get<{ state: string }>("SELECT state FROM tasks WHERE id = ?", [currentId])?.state;
      return { lifecycle, activity: state === "awaiting_approval" ? "awaiting_approval" : "working", blocked_reason: null };
    }
    if (r.home_built !== 1) return { lifecycle, activity: "idle", blocked_reason: null };
    if (!toolsOk) return { lifecycle, activity: "blocked", blocked_reason: "missing_tools" };
    if (r.workspace_error) return { lifecycle, activity: "blocked", blocked_reason: "workspace_error" };
    if (r.workspace_ready !== 1) return { lifecycle, activity: "idle", blocked_reason: null };
    if (!this.ctx.providers.isOnline(r.provider)) return { lifecycle, activity: "blocked", blocked_reason: "provider_offline" };
    const next = this.ctx.tasks.nextQueued(r.id);
    if (next && !this.ctx.mana.canStart(next).ok) return { lifecycle, activity: "blocked", blocked_reason: "no_mana" };
    return { lifecycle, activity: "idle", blocked_reason: null };
  }

  /** True when the agent can be given a new run right now (lifecycle and blockers only). */
  isDispatchable(r: AgentRow): boolean {
    if (r.retired_at || r.lifecycle !== "active") return false;
    if (r.workspace_ready !== 1 || r.workspace_error) return false;
    if (!this.ctx.tools.requiredToolsActive(r.id, r.role)) return false;
    return this.ctx.providers.isOnline(r.provider);
  }

  private checkApprovalMode(mode: ApprovalMode, provider: Provider, rank: string): void {
    const def = this.ctx.econ.data.approval_modes[mode];
    if (!def) throw fail.badRequest(`unknown approval mode ${mode}`);
    const age = this.ctx.ages.current();
    if (def.age > age) throw fail.age(`${mode} needs Age ${def.age}`);
    if (!rankAtLeast(this.ctx.econ, rank, def.min_rank)) throw fail.rank(`${mode} needs rank ${def.min_rank}`);
    if (def.providers && !def.providers.includes(provider)) {
      throw fail.badRequest(`${mode} is only available for ${def.providers.join(", ")}`);
    }
  }

  private defaultApprovalMode(): ApprovalMode {
    const entry = Object.entries(this.ctx.econ.data.approval_modes).find(([, v]) => v.default === true);
    return (entry?.[0] ?? "trusted_edits") as ApprovalMode;
  }

  agentCost(role: Role): Resources {
    const def = this.ctx.econ.data.roles[role];
    if (!def) throw fail.badRequest(`unknown role ${role}`);
    const existing = this.nonRetiredCount();
    return scaleCost(def.cost, 1 + this.ctx.econ.data.agent_cost_scaling_per_existing * existing);
  }

  private graceApplies(): boolean {
    return this.nonRetiredCount() === this.ctx.econ.data.anti_deadlock.fonts_grace.when_agents;
  }

  graceFrees(r: AgentRow, what: "agent" | "home" | "required_tools"): boolean {
    return r.grace === 1 && this.ctx.econ.data.anti_deadlock.fonts_grace.free.includes(what);
  }

  async create(spec: CreateAgentSpec): Promise<{ agent_id: string; cost: Resources; free: boolean; training: { duration_ms: number } }> {
    const econ = this.ctx.econ;
    const role = econ.data.roles[spec.role];
    if (!role) throw fail.badRequest(`unknown role ${spec.role}`);
    const age = this.ctx.ages.current();
    if (role.age > age) throw fail.age(`${role.name} can be summoned from Age ${role.age}`);
    const mode = spec.approval_mode ?? this.defaultApprovalMode();
    this.checkApprovalMode(mode, spec.provider, econ.rankOrder[0]!);
    if (this.nonRetiredCount() >= econ.agentLimit(age)) {
      throw fail.limit(`Age ${age} allows at most ${econ.agentLimit(age)} agents`);
    }
    if (!this.ctx.providers.isOnline(spec.provider)) throw fail.provider(`${spec.provider} is not available`);
    const checked = validateWorkFolder(spec.workspace.path, this.ctx.pathPolicy);
    if (!checked.ok) throw fail.workspace(checked.reason);
    const detected = await this.ctx.workspace.detect(checked.path);

    return this.ctx.db.tx(() => {
      // Re-check limits inside the transaction: another create may have finished meanwhile.
      if (this.nonRetiredCount() >= econ.agentLimit(age)) {
        throw fail.limit(`Age ${age} allows at most ${econ.agentLimit(age)} agents`);
      }
      const grace = this.graceApplies();
      const free = grace && econ.data.anti_deadlock.fonts_grace.free.includes("agent");
      const cost = free ? zeroResources() : this.agentCost(spec.role);
      const id = this.ctx.ids.next("agt");
      const seals = { ...this.defaultSeals(), ...(spec.seals ?? {}) };
      const billing = spec.billing ?? this.ctx.mana.defaultBilling(spec.provider);
      this.ctx.treasury.charge(cost, "agent", id, `agent:${id}`);
      this.ctx.db.run(
        `INSERT INTO agents (id, name, provider, model, role, instructions, approval_mode, workspace_path, workspace_mode,
           repo_root, workspace_sub, seals_json, billing, lifecycle, activity, stats_json, grace, cost_json,
           starting_tools_json, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'training', 'idle', ?, ?, ?, ?, ?)`,
        [
          id,
          spec.name,
          spec.provider,
          spec.model,
          spec.role,
          spec.instructions,
          mode,
          checked.path,
          detected.mode,
          detected.repoRoot,
          detected.sub,
          toJson(seals),
          billing,
          toJson(EMPTY_STATS),
          grace ? 1 : 0,
          toJson(cost),
          toJson(spec.starting_tools),
          this.ctx.clock.iso(),
        ],
      );
      this.markDirty(id);
      this.ctx.mana.markDirty();
      return { agent_id: id, cost, free, training: { duration_ms: Math.round(role.train_s * 1000) } };
    });
  }

  trained(agentId: string): void {
    this.ctx.db.tx(() => {
      const r = this.row(agentId);
      if (r.lifecycle !== "training") {
        if (r.lifecycle === "retired") throw fail.invalidState("the agent is retired");
        return;
      }
      this.ctx.db.run("UPDATE agents SET lifecycle = 'settling' WHERE id = ?", [agentId]);
      this.markDirty(agentId);
    });
  }

  placeHome(agentId: string, tile: Tile): { cost: Resources } {
    return this.ctx.db.tx(() => {
      const r = this.row(agentId);
      if (r.lifecycle === "training") throw fail.invalidState("the agent is still training");
      if (r.lifecycle === "retired") throw fail.invalidState("the agent is retired");
      if (r.home_tile_json) throw fail.invalidState("the agent already has a home");
      const home = this.ctx.econ.data.buildings[this.ctx.econ.data.roles[r.role]!.home];
      const cost = this.graceFrees(r, "home") ? zeroResources() : toResources(home?.cost ?? {});
      this.ctx.treasury.charge(cost, "home", agentId, `home:${agentId}`);
      this.ctx.db.run("UPDATE agents SET home_tile_json = ? WHERE id = ?", [toJson(tile), agentId]);
      this.markDirty(agentId);
      return { cost };
    });
  }

  homeBuilt(agentId: string): void {
    const shouldSetup = this.ctx.db.tx(() => {
      const r = this.row(agentId);
      if (!r.home_tile_json) throw fail.invalidState("the home has not been placed");
      if (r.retired_at) throw fail.invalidState("the agent is retired");
      if (r.home_built === 1) return false;
      this.ctx.db.run("UPDATE agents SET home_built = 1 WHERE id = ?", [agentId]);
      this.markDirty(agentId);
      return true;
    });
    if (shouldSetup) void this.setupWorkspace(agentId);
  }

  /** Prepares the agent's workspace (repo check or versioned plain-folder copy) in the background. */
  async setupWorkspace(agentId: string): Promise<void> {
    const r = this.row(agentId);
    try {
      const mirror = await this.ctx.workspace.setupAgent(r);
      this.ctx.db.tx(() => {
        this.ctx.db.run("UPDATE agents SET workspace_ready = 1, workspace_error = NULL, mirror_path = ? WHERE id = ?", [
          mirror,
          agentId,
        ]);
        this.markDirty(agentId);
      });
      this.ctx.scheduler.kick();
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      this.ctx.log.warn({ agentId, err: message }, "workspace setup failed");
      this.ctx.db.tx(() => {
        this.ctx.db.run("UPDATE agents SET workspace_error = ? WHERE id = ?", [message.slice(0, 500), agentId]);
        this.markDirty(agentId);
      });
    }
  }

  update(agentId: string, patch: AgentPatch, expectedVersion: number): Agent {
    this.ctx.db.tx(() => {
      const r = this.row(agentId);
      if (r.version !== expectedVersion) throw fail.conflict(`agent version is ${r.version}, not ${expectedVersion}`);
      if (r.retired_at) throw fail.invalidState("the agent is retired");
      if (patch.approval_mode) this.checkApprovalMode(patch.approval_mode, r.provider, r.rank);
      const seals = patch.seals ? { ...this.seals(r), ...patch.seals } : this.seals(r);
      this.ctx.db.run(
        "UPDATE agents SET name = ?, model = ?, instructions = ?, approval_mode = ?, seals_json = ? WHERE id = ?",
        [
          patch.name ?? r.name,
          patch.model ?? r.model,
          patch.instructions ?? r.instructions,
          patch.approval_mode ?? r.approval_mode,
          toJson(seals),
          agentId,
        ],
      );
      this.markDirty(agentId);
    });
    return this.get(agentId);
  }

  retire(agentId: string, when: "now" | "after_current"): void {
    const r = this.row(agentId);
    if (r.retired_at) return;
    if (when === "after_current" && this.currentTaskId(agentId)) {
      this.ctx.db.tx(() => {
        this.ctx.db.run("UPDATE agents SET retire_after_current = 1 WHERE id = ?", [agentId]);
        this.ctx.tasks.cancelQueuedForAgent(agentId);
        this.markDirty(agentId);
      });
      return;
    }
    this.retireNow(agentId);
  }

  retireNow(agentId: string): void {
    this.ctx.tasks.cancelAllForAgent(agentId);
    this.ctx.db.tx(() => {
      const r = this.row(agentId);
      if (r.retired_at) return;
      if (r.lifecycle === "training") {
        const paid = toResources(fromJson(r.cost_json, {}));
        const factor = this.ctx.econ.data.refunds.cancel;
        const refund = scaleCost(paid, factor, Math.floor);
        this.ctx.treasury.credit(refund, "cancel_refund", "agent_cancelled", agentId, `agent_cancel:${agentId}`);
      }
      this.ctx.tools.removeAllForAgent(agentId);
      this.ctx.parties.onAgentRetired(agentId);
      this.ctx.db.run("UPDATE agents SET retired_at = ?, lifecycle = 'retired', party_id = NULL WHERE id = ?", [
        this.ctx.clock.iso(),
        agentId,
      ]);
      this.markDirty(agentId);
      this.ctx.bus.emit("agent_retired", { agent_id: agentId }, `agent/${agentId}`);
      this.ctx.mana.markDirty();
    });
  }

  /** Called when an agent's run ends: honours `retire_agent{when:"after_current"}`. */
  maybeRetireAfterCurrent(agentId: string): void {
    const r = this.rowOrNull(agentId);
    if (!r || r.retired_at || r.retire_after_current !== 1) return;
    if (this.currentTaskId(agentId)) return;
    this.retireNow(agentId);
  }

  setParty(agentId: string, partyId: string | null): void {
    this.ctx.db.run("UPDATE agents SET party_id = ? WHERE id = ?", [partyId, agentId]);
    this.markDirty(agentId);
  }

  addManaSpent(agentId: string, micros: number): void {
    this.bumpStats(agentId, { mana_spent_micros: micros });
  }

  bumpStats(agentId: string, delta: Partial<AgentStats>): void {
    this.ctx.db.tx(() => {
      const r = this.row(agentId);
      const s = this.stats(r);
      for (const [k, v] of Object.entries(delta) as Array<[keyof AgentStats, number]>) s[k] += v;
      this.ctx.db.run("UPDATE agents SET stats_json = ? WHERE id = ?", [toJson(s), agentId]);
      this.markDirty(agentId);
    });
  }

  /** Adds XP, then recomputes level and rank. */
  addXp(agentId: string, xp: number): void {
    this.ctx.db.tx(() => {
      const r = this.row(agentId);
      const total = r.xp + Math.max(0, Math.round(xp));
      this.ctx.db.run("UPDATE agents SET xp = ?, level = ? WHERE id = ?", [total, this.ctx.econ.levelForXp(total), agentId]);
      this.recomputeRank(agentId);
    });
  }

  recomputeRank(agentId: string): void {
    this.ctx.db.tx(() => {
      const r = this.row(agentId);
      const stats = this.stats(r);
      const window = this.ctx.econ.data.rank_first_try_window;
      const recent = this.ctx.db.all<{ attempt: number; mana_used_micros: number | null; baseline_micros: number | null }>(
        "SELECT attempt, mana_used_micros, baseline_micros FROM tasks WHERE agent_id = ? AND accepted_at IS NOT NULL AND parent_task_id IS NULL ORDER BY accepted_at DESC LIMIT ?",
        [agentId, window],
      );
      const firstTry = recent.filter((t) => t.attempt === 1).length;
      const ratios = recent
        .filter((t) => t.mana_used_micros !== null && t.baseline_micros)
        .map((t) => t.mana_used_micros! / t.baseline_micros!);
      const rank = computeRank(this.ctx.econ, {
        xp: r.xp,
        accepted: stats.accepted,
        firstTryRate: recent.length ? firstTry / recent.length : 0,
        ritesPassed: stats.rites_passed,
        partyTasks: stats.party_tasks,
        medianManaRatio: median(ratios),
        townAge: this.ctx.ages.current(),
      });
      if (rank !== r.rank) this.ctx.db.run("UPDATE agents SET rank = ? WHERE id = ?", [rank, agentId]);
      this.markDirty(agentId);
    });
  }

  applyBillingDefaults(billing: { claude: Billing; codex: Billing }): void {
    for (const provider of ["claude", "codex"] as const) {
      const rows = this.ctx.db.all<{ id: string }>(
        "SELECT id FROM agents WHERE provider = ? AND retired_at IS NULL AND billing != ?",
        [provider, billing[provider]],
      );
      for (const row of rows) {
        this.ctx.db.run("UPDATE agents SET billing = ? WHERE id = ?", [billing[provider], row.id]);
        this.markDirty(row.id);
      }
    }
  }

  /** Marks every non-retired agent dirty (after Mana or provider changes that affect blockers). */
  refreshAll(): void {
    this.ctx.db.tx(() => {
      for (const r of this.ctx.db.all<{ id: string }>("SELECT id FROM agents WHERE retired_at IS NULL")) this.markDirty(r.id);
    });
  }

  /** Recompute the stored status of agents and emit only if something visible changed. */
  refreshIfChanged(agentId: string): void {
    const r = this.rowOrNull(agentId);
    if (!r) return;
    const s = this.computeStatus(r);
    if (s.lifecycle !== r.lifecycle || s.activity !== r.activity || s.blocked_reason !== r.blocked_reason) {
      this.markDirty(agentId);
    }
  }
}
