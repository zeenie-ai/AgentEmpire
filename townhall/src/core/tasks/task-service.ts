import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { fromJson, toJson } from "../../db/db.js";
import { fail } from "../../protocol/errors.js";
import type {
  ActivityEntry,
  ActivityKind,
  DiffFile,
  Integrate,
  MergeBlockedReason,
  PauseReason,
  Rewards,
  Task,
  TaskResult,
  TaskSize,
  TaskState,
} from "../../protocol/objects.js";
import { ACTIVITY_TEXT_MAX_BYTES, DIFF_PATCH_MAX_BYTES, RECENT_TASKS_IN_STATE } from "../../protocol/version.js";
import { capBytes } from "../../security/redact.js";
import { computeBounty, splitPartyXp, splitReward, zeroRewards, type ZeroReason } from "../bounty.js";
import type { TimerHandle } from "../clock.js";
import type { Ctx } from "../context.js";
import type { Size } from "../economy.js";
import type { DirtySet } from "../events.js";
import { incidentKey } from "../incidents.js";
import type { TaskWorkspace } from "../workspace.js";
import { assertTransition, isTerminal } from "./state-machine.js";

export interface TaskRow {
  id: string;
  agent_id: string;
  party_id: string | null;
  parent_task_id: string | null;
  depth: number;
  title: string;
  prompt: string;
  prompt_hash: string;
  size: TaskSize;
  acceptance_json: string;
  rite: string | null;
  state: TaskState;
  state_reason: string | null;
  attempt: number;
  seal_micros: number;
  reserved_micros: number;
  spent_micros: number;
  spent_is_estimate: number;
  seal_warned: number;
  courier_json: string;
  queue_pos: number;
  created_at: string;
  delivered_at: string | null;
  started_at: string | null;
  finished_at: string | null;
  updated_at: string;
  run_ms: number;
  run_started_at: string | null;
  result_json: string | null;
  rewards_json: string | null;
  session_id: string | null;
  provider_state_json: string | null;
  pending_feedback: string | null;
  workspace_json: string | null;
  rift_retries: number;
  subtasks_total: number;
  accepted_at: string | null;
  reward_rp: number | null;
  role_at_accept: string | null;
  mana_used_micros: number | null;
  baseline_micros: number | null;
  version: number;
}

export interface AssignInput {
  agent_id?: string | undefined;
  party_id?: string | undefined;
  title: string;
  prompt: string;
  size: TaskSize;
  acceptance?: string[] | undefined;
  rite?: string | null | undefined;
  seal_mana?: number | undefined;
  courier: { mode: "human" | "wisp" | "express"; human_id?: string | null | undefined };
}

const OPEN_STATES: TaskState[] = [
  "in_transit",
  "queued",
  "preparing",
  "running",
  "awaiting_approval",
  "awaiting_review",
  "accepting",
  "paused",
  "failed",
];

function normalizeText(s: string): string {
  return s.trim().replace(/\s+/g, " ").toLowerCase();
}

export function promptHash(title: string, prompt: string): string {
  return createHash("sha256").update(`${normalizeText(title)}\n${normalizeText(prompt)}`).digest("hex");
}

export class TaskService {
  private readonly dirty: DirtySet;
  private readonly courierTimers = new Map<string, TimerHandle>();
  private readonly riftTimers = new Map<string, TimerHandle>();

  constructor(private readonly ctx: Ctx) {
    this.dirty = ctx.bus.newDirtySet();
    ctx.bus.addFlusher(() => {
      const ids = this.dirty.take();
      for (const id of ids) {
        this.ctx.db.run("UPDATE tasks SET version = version + 1, updated_at = ? WHERE id = ?", [this.ctx.clock.iso(), id]);
        const row = this.rowOrNull(id);
        if (row) this.ctx.bus.emit("task_updated", { task: this.toProtocol(row) }, `task/${id}`);
      }
      return ids.length > 0;
    });
  }

  // ---------- reads ----------

  markDirty(taskId: string): void {
    const mark = () => {
      this.dirty.add(taskId);
      const agentId = this.ctx.db.get<{ agent_id: string }>("SELECT agent_id FROM tasks WHERE id = ?", [taskId])?.agent_id;
      if (agentId) this.ctx.agents.markDirty(agentId);
    };
    if (this.ctx.db.inTx()) mark();
    else this.ctx.db.tx(mark);
  }

  rowOrNull(id: string): TaskRow | null {
    return this.ctx.db.get<TaskRow>("SELECT * FROM tasks WHERE id = ?", [id]) ?? null;
  }

  row(id: string): TaskRow {
    const r = this.rowOrNull(id);
    if (!r) throw fail.notFound("task", id);
    return r;
  }

  toProtocol(r: TaskRow): Task {
    return {
      id: r.id,
      agent_id: r.agent_id,
      party_id: r.party_id,
      parent_task_id: r.parent_task_id,
      title: r.title,
      prompt: r.prompt,
      size: r.size,
      acceptance: fromJson<string[]>(r.acceptance_json, []),
      rite: r.rite,
      state: r.state,
      state_reason: r.state_reason,
      attempt: r.attempt,
      seal_micros: r.seal_micros,
      reserved_micros: r.reserved_micros,
      spent_micros: r.spent_micros,
      spent_is_estimate: r.spent_is_estimate === 1,
      courier: fromJson(r.courier_json, { mode: "human" as const }),
      created_at: r.created_at,
      started_at: r.started_at,
      finished_at: r.finished_at,
      result: fromJson<TaskResult | null>(r.result_json, null),
      rewards: fromJson<Rewards | null>(r.rewards_json, null),
      version: r.version,
    };
  }

  get(id: string): Task {
    return this.toProtocol(this.row(id));
  }

  /** Open tasks plus the most recent finished ones, for get_state. */
  listForState(): Task[] {
    const placeholders = OPEN_STATES.map(() => "?").join(",");
    const open = this.ctx.db.all<TaskRow>(`SELECT * FROM tasks WHERE state IN (${placeholders}) ORDER BY created_at ASC`, OPEN_STATES);
    const recent = this.ctx.db.all<TaskRow>(
      `SELECT * FROM tasks WHERE state NOT IN (${placeholders}) ORDER BY updated_at DESC LIMIT ?`,
      [...OPEN_STATES, RECENT_TASKS_IN_STATE],
    );
    return [...open, ...recent].map((r) => this.toProtocol(r));
  }

  nextQueued(agentId: string): TaskRow | null {
    return (
      this.ctx.db.get<TaskRow>(
        "SELECT * FROM tasks WHERE agent_id = ? AND state = 'queued' ORDER BY queue_pos ASC, created_at ASC LIMIT 1",
        [agentId],
      ) ?? null
    );
  }

  workspaceOf(r: TaskRow): TaskWorkspace | null {
    return this.ctx.workspace.taskWorkspace(r.workspace_json);
  }

  saveWorkspace(taskId: string, ws: TaskWorkspace): void {
    this.ctx.db.run("UPDATE tasks SET workspace_json = ? WHERE id = ?", [toJson(ws), taskId]);
  }

  // ---------- state changes ----------

  setState(taskId: string, to: TaskState, reason: string | null = null): TaskRow {
    return this.ctx.db.tx(() => {
      const r = this.row(taskId);
      assertTransition(r.state, to);
      this.ctx.db.run("UPDATE tasks SET state = ?, state_reason = ? WHERE id = ?", [to, reason, taskId]);
      this.markDirty(taskId);
      return this.row(taskId);
    });
  }

  private frontOfQueue(agentId: string): number {
    const min = this.ctx.db.get<{ pos: number | null }>(
      "SELECT MIN(queue_pos) AS pos FROM tasks WHERE agent_id = ? AND state IN ('in_transit','queued')",
      [agentId],
    )?.pos;
    return (min ?? 0) - 1;
  }

  private backOfQueue(agentId: string): number {
    const max = this.ctx.db.get<{ pos: number | null }>("SELECT MAX(queue_pos) AS pos FROM tasks WHERE agent_id = ?", [agentId])?.pos;
    return (max ?? 0) + 1;
  }

  /** Puts a task back in its agent's queue, ahead of new work. */
  private requeueFront(taskId: string): void {
    const r = this.row(taskId);
    this.setState(taskId, "queued");
    this.ctx.db.run("UPDATE tasks SET queue_pos = ? WHERE id = ?", [this.frontOfQueue(r.agent_id), taskId]);
  }

  appendActivity(taskId: string, kind: ActivityKind, text: string, broadcast: boolean): ActivityEntry {
    const entry: ActivityEntry = {
      time: this.ctx.clock.iso(),
      kind,
      text: capBytes(this.ctx.redactor.redact(text), ACTIVITY_TEXT_MAX_BYTES),
    };
    this.ctx.db.tx(() => {
      this.ctx.db.run("INSERT INTO task_events (task_id, time, kind, text) VALUES (?, ?, ?, ?)", [
        taskId,
        entry.time,
        entry.kind,
        entry.text,
      ]);
      if (broadcast) this.ctx.bus.emit("task_activity", { task_id: taskId, entry }, `task/${taskId}`);
    });
    return entry;
  }

  // ---------- commands ----------

  assign(input: AssignInput): { task_id: string } {
    if ((input.agent_id ? 1 : 0) + (input.party_id ? 1 : 0) !== 1) {
      throw fail.badRequest("give exactly one of agent_id or party_id");
    }
    const id = this.ctx.db.tx(() => {
      let agentId = input.agent_id ?? "";
      let partyId: string | null = null;
      if (input.party_id) {
        const party = this.ctx.parties.activeRow(input.party_id);
        agentId = party.lead_agent_id;
        partyId = party.id;
      }
      const agent = this.ctx.agents.row(agentId);
      if (agent.retired_at) throw fail.invalidState("the agent is retired");
      const age = this.ctx.ages.current();
      const waiting =
        this.ctx.db.get<{ n: number }>(
          "SELECT COUNT(*) AS n FROM tasks WHERE agent_id = ? AND state IN ('in_transit','queued') AND parent_task_id IS NULL",
          [agentId],
        )?.n ?? 0;
      const limit = this.ctx.econ.queueLimit(age);
      if (waiting >= limit) throw fail.limit(`Age ${age} homes hold ${limit} waiting task(s)`);
      const seals = this.ctx.agents.seals(agent);
      const sealMicros = this.ctx.econ.manaToMicros(input.seal_mana ?? seals[input.size]);
      const express = input.courier.mode === "express" || this.ctx.settings.get().express_dispatch;
      const taskId = this.ctx.ids.next("tsk");
      const now = this.ctx.clock.iso();
      const rite = input.rite && input.rite.trim() ? input.rite.trim() : null;
      this.ctx.db.run(
        `INSERT INTO tasks (id, agent_id, party_id, parent_task_id, depth, title, prompt, prompt_hash, size, acceptance_json, rite,
           state, attempt, seal_micros, spent_is_estimate, courier_json, queue_pos, created_at, delivered_at, updated_at)
         VALUES (?, ?, ?, NULL, 0, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?)`,
        [
          taskId,
          agentId,
          partyId,
          input.title,
          input.prompt,
          promptHash(input.title, input.prompt),
          input.size,
          toJson(input.acceptance ?? []),
          rite,
          express ? "queued" : "in_transit",
          sealMicros,
          agent.billing === "subscription" ? 1 : 0,
          toJson({ mode: input.courier.mode, human_id: input.courier.human_id ?? null }),
          this.backOfQueue(agentId),
          now,
          express ? now : null,
          now,
        ],
      );
      this.markDirty(taskId);
      return { taskId, express };
    });
    if (!id.express) this.armCourier(id.taskId);
    this.ctx.scheduler.kick();
    return { task_id: id.taskId };
  }

  private armCourier(taskId: string): void {
    const r = this.rowOrNull(taskId);
    if (!r || r.state !== "in_transit") return;
    this.ctx.clock.clearTimeout(this.courierTimers.get(taskId));
    const due = Date.parse(r.created_at) + this.ctx.econ.data.couriers.force_deliver_after_s * 1000;
    this.courierTimers.set(
      taskId,
      this.ctx.clock.setTimeout(() => this.onCourierTimeout(taskId), Math.max(0, due - this.ctx.clock.now())),
    );
  }

  private onCourierTimeout(taskId: string): void {
    this.courierTimers.delete(taskId);
    const r = this.rowOrNull(taskId);
    if (!r || r.state !== "in_transit") return;
    const level = this.ctx.mana.level();
    if (level === "warning" || level === "depleted") {
      // Automatic dispatch pauses while Mana is low; only a walking courier delivers.
      const retry = this.ctx.econ.data.couriers.wisp_after_s * 1000;
      this.courierTimers.set(taskId, this.ctx.clock.setTimeout(() => this.onCourierTimeout(taskId), retry));
      return;
    }
    try {
      this.delivered(taskId);
    } catch (err) {
      this.ctx.log.warn({ taskId, err: String(err) }, "forced delivery failed");
    }
  }

  delivered(taskId: string): void {
    this.ctx.db.tx(() => {
      const r = this.row(taskId);
      if (r.state !== "in_transit") {
        if (r.state === "cancelled") throw fail.invalidState("the task was cancelled");
        return;
      }
      this.setState(taskId, "queued");
      this.ctx.db.run("UPDATE tasks SET delivered_at = ? WHERE id = ?", [this.ctx.clock.iso(), taskId]);
    });
    this.ctx.clock.clearTimeout(this.courierTimers.get(taskId));
    this.courierTimers.delete(taskId);
    this.ctx.scheduler.kick();
  }

  cancel(taskId: string): void {
    const r = this.row(taskId);
    if (isTerminal(r.state)) throw fail.invalidState(`the task is already ${r.state}`);
    if (r.state === "awaiting_review" || r.state === "accepting") throw fail.invalidState("use abandon_task for work under review");
    for (const child of this.ctx.db.all<{ id: string }>(
      "SELECT id FROM tasks WHERE parent_task_id = ? AND state IN ('in_transit','queued','preparing','running','awaiting_approval','paused','failed')",
      [taskId],
    )) {
      this.cancel(child.id);
    }
    if (this.ctx.supervisor.interrupt(taskId, { kind: "cancel" })) return;
    this.finishCancelled(taskId);
  }

  /** Marks a task cancelled once no run is active for it. */
  finishCancelled(taskId: string): void {
    this.ctx.clock.clearTimeout(this.courierTimers.get(taskId));
    this.courierTimers.delete(taskId);
    this.ctx.clock.clearTimeout(this.riftTimers.get(taskId));
    this.riftTimers.delete(taskId);
    this.ctx.approvals.cancelForTask(taskId, "cancelled");
    this.ctx.db.tx(() => {
      const r = this.row(taskId);
      if (r.state === "cancelled") return;
      this.setState(taskId, "cancelled");
      this.ctx.db.run("UPDATE tasks SET finished_at = COALESCE(finished_at, ?) WHERE id = ?", [this.ctx.clock.iso(), taskId]);
      this.ctx.mana.release(taskId);
      this.ctx.incidents.resolveForTask(taskId, ["alarm_bell", "hand_bell", "rift", "smoke"]);
    });
    if (this.row(taskId).parent_task_id) this.ctx.parties.notifyChildFinished(taskId);
    this.ctx.scheduler.kick();
  }

  resume(taskId: string, extendSealMana?: number): void {
    const r = this.row(taskId);
    if (r.state === "failed") {
      this.ctx.db.tx(() => {
        this.requeueFront(taskId);
        this.ctx.db.run("UPDATE tasks SET rift_retries = 0 WHERE id = ?", [taskId]);
        this.ctx.incidents.resolveForTask(taskId, ["smoke", "rift"]);
      });
      this.ctx.clock.clearTimeout(this.riftTimers.get(taskId));
      this.riftTimers.delete(taskId);
      this.ctx.scheduler.kick();
      return;
    }
    if (r.state !== "paused") throw fail.invalidState(`only paused or failed tasks can be resumed (the task is ${r.state})`);
    this.ctx.db.tx(() => {
      if (extendSealMana) this.ctx.mana.extendSeal(taskId, extendSealMana);
      const cur = this.row(taskId);
      if (cur.spent_micros >= cur.seal_micros) {
        throw fail.mana("the Mana Seal is spent: extend it or stop and review");
      }
      this.ctx.approvals.supersedeOrphaned(taskId);
      this.requeueFront(taskId);
      this.ctx.incidents.resolve(incidentKey.handSeal(taskId));
      this.ctx.incidents.resolve(incidentKey.alarm(taskId));
      const agent = this.ctx.agents.row(cur.agent_id);
      this.ctx.incidents.resolve(incidentKey.fontDarkProvider(agent.provider));
    });
    this.ctx.scheduler.kick();
  }

  /** Answering the last orphaned approval of a restarted task resumes its session. */
  resumeAfterOrphan(taskId: string): void {
    const r = this.rowOrNull(taskId);
    if (!r || r.state !== "paused" || r.state_reason !== "restart") return;
    this.ctx.db.tx(() => this.requeueFront(taskId));
    this.ctx.scheduler.kick();
  }

  /** Re-queues tasks that were paused for a reason that has now cleared (for example Mana refilled). */
  autoResume(reason: PauseReason): void {
    const rows = this.ctx.db.all<{ id: string }>("SELECT id FROM tasks WHERE state = 'paused' AND state_reason = ?", [reason]);
    for (const r of rows) {
      try {
        this.ctx.db.tx(() => this.requeueFront(r.id));
      } catch (err) {
        this.ctx.log.warn({ taskId: r.id, err: String(err) }, "auto-resume failed");
      }
    }
    this.ctx.scheduler.kick();
  }

  stopAndReview(taskId: string): void {
    const r = this.row(taskId);
    if (r.state === "running" || r.state === "awaiting_approval") {
      if (this.ctx.supervisor.interrupt(taskId, { kind: "stop_review" })) return;
    }
    if (r.state !== "paused") throw fail.invalidState(`only running or paused tasks can be stopped for review (the task is ${r.state})`);
    const ws = this.workspaceOf(r);
    if (!ws || ws.removed || !existsSync(ws.worktree)) throw fail.invalidState("the task has no work to review yet");
    void this.ctx.supervisor.finalize(taskId, ws, "Stopped for review before the agent finished.");
  }

  nudge(taskId: string, message: string): void {
    if (!this.ctx.supervisor.nudge(taskId, message)) throw fail.invalidState("the task is not running");
  }

  async detail(taskId: string, include: Array<"activity" | "diff">): Promise<{ task: Task; activity: ActivityEntry[]; diff?: { files: DiffFile[]; patch?: string } }> {
    const r = this.row(taskId);
    const activity = include.includes("activity")
      ? this.ctx.db
          .all<ActivityEntry>(
            "SELECT time, kind, text FROM (SELECT id, time, kind, text FROM task_events WHERE task_id = ? ORDER BY id DESC LIMIT 200) ORDER BY id ASC",
            [taskId],
          )
          .map((e) => ({ time: e.time, kind: e.kind, text: e.text }))
      : [];
    let diff: { files: DiffFile[]; patch?: string } | undefined;
    if (include.includes("diff")) {
      const ws = this.workspaceOf(r);
      if (ws) {
        const cwd = !ws.removed && existsSync(ws.worktree) ? ws.worktree : ws.repo;
        const to = ws.snapshot_sha ?? (cwd === ws.worktree ? null : ws.base_sha);
        const { files } = await this.ctx.workspace.diffFiles(cwd, ws.base_sha, to);
        diff = { files, patch: await this.ctx.workspace.patch(ws, DIFF_PATCH_MAX_BYTES) };
      } else {
        diff = { files: [] };
      }
    }
    return { task: this.toProtocol(r), activity, ...(diff ? { diff } : {}) };
  }

  async accept(taskId: string, integrate: Integrate): Promise<{ rewards: Rewards | null; merge?: { commit?: string; blocked_reason?: MergeBlockedReason } }> {
    const first = this.row(taskId);
    if (first.parent_task_id) throw fail.invalidState("party sub-tasks are reviewed through their parent task");
    if (first.state !== "awaiting_review" && first.state !== "accepting") {
      throw fail.invalidState(`only work under review can be accepted (the task is ${first.state})`);
    }
    return this.ctx.locks.run(`task:${taskId}`, async () => {
      const r = this.row(taskId);
      if (r.state !== "awaiting_review" && r.state !== "accepting") throw fail.invalidState(`the task is ${r.state}`);
      const ws = this.workspaceOf(r);
      if (!ws) throw fail.invalidState("the task has no workspace");
      if (integrate === "export" && ws.mode !== "plain_folder") {
        throw fail.badRequest("export is for plain folders; use merge or keep_branch for a git repository");
      }
      if (r.state === "awaiting_review") this.setState(taskId, "accepting");
      let commit: string | undefined;
      let blocked: MergeBlockedReason | undefined;
      if (integrate === "merge") {
        const m = await this.ctx.workspace.merge(ws, r.title, r.id);
        commit = m.commit;
        blocked = m.blocked;
      } else if (integrate === "keep_branch") {
        await this.ctx.workspace.keepBranch(ws);
      } else {
        const e = await this.ctx.workspace.exportPlain(ws);
        blocked = e.blocked;
      }
      if (blocked) {
        this.ctx.db.tx(() => {
          this.saveWorkspace(taskId, ws);
          this.ctx.incidents.open("merge_blocked", incidentKey.merge(taskId), {
            severity: "warn",
            message: `The result could not be integrated (${blocked}); fix it and accept again, or keep the branch`,
            agentId: r.agent_id,
            taskId,
          });
          this.markDirty(taskId);
        });
        return { rewards: null, merge: { blocked_reason: blocked } };
      }
      const children = await this.integrateChildren(taskId, integrate);
      const rewards = this.ctx.db.tx(() => {
        this.saveWorkspace(taskId, ws);
        const paid = this.payRewards(taskId, children);
        this.setState(taskId, "accepted");
        this.ctx.incidents.resolve(incidentKey.merge(taskId));
        return paid;
      });
      this.ctx.scheduler.kick();
      return { rewards, ...(commit ? { merge: { commit } } : {}) };
    });
  }

  /** Integrates finished party sub-tasks; a blocked merge falls back to keeping the branch. */
  private async integrateChildren(parentId: string, integrate: Integrate): Promise<string[]> {
    const children = this.ctx.db.all<TaskRow>(
      "SELECT * FROM tasks WHERE parent_task_id = ? AND state IN ('awaiting_review','accepting')",
      [parentId],
    );
    const accepted: string[] = [];
    for (const c of children) {
      if (c.state === "awaiting_review") this.setState(c.id, "accepting");
      const ws = this.workspaceOf(c);
      if (ws) {
        let blocked: MergeBlockedReason | undefined;
        if (integrate === "merge" && ws.mode === "git_worktree") blocked = (await this.ctx.workspace.merge(ws, c.title, c.id)).blocked;
        else if (integrate === "export" && ws.mode === "plain_folder") blocked = (await this.ctx.workspace.exportPlain(ws)).blocked;
        else blocked = "not_a_repo";
        if (blocked) await this.ctx.workspace.keepBranch(ws);
        this.ctx.db.tx(() => this.saveWorkspace(c.id, ws));
      }
      accepted.push(c.id);
    }
    return accepted;
  }

  private runMs(r: TaskRow): number {
    const open = r.run_started_at ? Math.max(0, this.ctx.clock.now() - Date.parse(r.run_started_at)) : 0;
    return r.run_ms + open;
  }

  /** Computes and pays the bounty; party sub-tasks pay only through this parent. */
  private payRewards(taskId: string, childIds: string[]): Rewards {
    const econ = this.ctx.econ;
    const r = this.row(taskId);
    const agent = this.ctx.agents.row(r.agent_id);
    const role = econ.data.roles[agent.role]!;
    const result = fromJson<TaskResult | null>(r.result_json, null);
    const children = childIds.map((id) => this.row(id));
    const manaUsedMicros = r.spent_micros + children.reduce((a, c) => a + c.spent_micros, 0);
    const baselineMicros = this.ctx.bounty.baselineMicros(agent.role, r.size as Size);
    let zero: ZeroReason | null = null;
    if (this.ctx.bounty.isDuplicate(r.prompt_hash, r.id)) zero = "duplicate";
    else if (!result?.deliverable) zero = "no_deliverable";
    else if (this.runMs(r) < econ.data.bounty.min_run_s * 1000) zero = "too_short";

    let rewards: Rewards;
    if (zero) {
      rewards = zeroRewards(econ, r.size as Size, zero);
    } else {
      const active = this.ctx.tools.activeTypes(agent.id);
      const { rp, breakdown } = computeBounty(econ, {
        size: r.size as Size,
        attempt: r.attempt,
        manaUsed: econ.microsToMana(manaUsedMicros),
        baselineMana: econ.microsToMana(baselineMicros),
        hasArchive: active.has("archive"),
        hasRecommendedTools: this.ctx.tools.hasRecommendedTools(agent.id, agent.role),
        ritePassed: result?.rite?.passed === true,
        rewardedTodaySameSize: this.ctx.bounty.rewardedTodaySameSize(r.size as Size, r.id),
      });
      const resources = splitReward(rp, role.reward_split);
      rewards = { rp, xp: Math.round(rp * econ.data.bounty.xp_per_rp), resources, breakdown };
    }

    const now = this.ctx.clock.iso();
    this.ctx.db.run(
      "UPDATE tasks SET accepted_at = ?, reward_rp = ?, role_at_accept = ?, mana_used_micros = ?, baseline_micros = ?, rewards_json = ? WHERE id = ?",
      [now, rewards.rp, agent.role, manaUsedMicros, baselineMicros, toJson(rewards), taskId],
    );
    for (const c of children) {
      this.ctx.db.run("UPDATE tasks SET accepted_at = ?, reward_rp = 0, rewards_json = ? WHERE id = ?", [
        now,
        toJson(zeroRewards(econ, c.size as Size, "party_subtask")),
        c.id,
      ]);
      this.setState(c.id, "accepted");
    }
    if (rewards.rp > 0) {
      this.ctx.treasury.credit(rewards.resources, "reward", "reward", taskId, `reward:${taskId}`);
      const participants = [...new Set(children.map((c) => c.agent_id).filter((id) => id !== agent.id))];
      this.ctx.agents.bumpStats(agent.id, {
        accepted: 1,
        accepted_first_try: r.attempt === 1 ? 1 : 0,
        rites_passed: result?.rite?.passed ? 1 : 0,
        party_tasks: r.party_id ? 1 : 0,
      });
      if (r.party_id) {
        for (const p of participants) this.ctx.agents.bumpStats(p, { party_tasks: 1 });
        const split = splitPartyXp(rewards.xp, econ.data.bounty.party_split.lead, participants.length);
        this.ctx.agents.addXp(agent.id, split.lead);
        participants.forEach((p, i) => this.ctx.agents.addXp(p, split.members[i]!));
      } else {
        this.ctx.agents.addXp(agent.id, rewards.xp);
      }
    }
    return rewards;
  }

  sendBack(taskId: string, feedback: string): void {
    this.ctx.db.tx(() => {
      const r = this.row(taskId);
      if (r.parent_task_id) throw fail.invalidState("party sub-tasks are reviewed through their parent task");
      if (r.state !== "awaiting_review" && r.state !== "accepting") {
        throw fail.invalidState(`only work under review can be sent back (the task is ${r.state})`);
      }
      const agent = this.ctx.agents.row(r.agent_id);
      if (agent.retired_at) throw fail.invalidState("the agent is retired");
      this.requeueFront(taskId);
      this.ctx.db.run(
        "UPDATE tasks SET attempt = attempt + 1, pending_feedback = ?, result_json = NULL, finished_at = NULL, rift_retries = 0 WHERE id = ?",
        [feedback, taskId],
      );
      this.ctx.agents.bumpStats(r.agent_id, { sent_back: 1 });
      this.ctx.incidents.resolve(incidentKey.merge(taskId));
      this.appendActivity(taskId, "system", `Sent back: ${feedback}`, true);
    });
    this.ctx.scheduler.kick();
  }

  abandon(taskId: string): void {
    this.ctx.db.tx(() => {
      const r = this.row(taskId);
      if (r.parent_task_id) throw fail.invalidState("party sub-tasks are reviewed through their parent task");
      if (r.state !== "awaiting_review" && r.state !== "accepting") {
        throw fail.invalidState(`only work under review can be abandoned (the task is ${r.state})`);
      }
      this.setState(taskId, "rejected");
      for (const c of this.ctx.db.all<{ id: string }>(
        "SELECT id FROM tasks WHERE parent_task_id = ? AND state IN ('awaiting_review','accepting')",
        [taskId],
      )) {
        this.setState(c.id, "rejected");
      }
      this.ctx.incidents.resolve(incidentKey.merge(taskId));
    });
  }

  async discard(taskId: string): Promise<void> {
    const r = this.row(taskId);
    if (!["rejected", "cancelled", "failed"].includes(r.state)) {
      throw fail.invalidState("abandon or cancel the task before discarding its workspace");
    }
    if (r.parent_task_id === null) {
      for (const c of this.ctx.db.all<{ id: string; state: TaskState }>(
        "SELECT id, state FROM tasks WHERE parent_task_id = ?",
        [taskId],
      )) {
        if (["rejected", "cancelled", "failed"].includes(c.state)) await this.discard(c.id);
      }
    }
    await this.ctx.locks.run(`task:${taskId}`, async () => {
      const cur = this.row(taskId);
      const ws = this.workspaceOf(cur);
      if (ws && !(ws.removed && ws.archived_ref)) await this.ctx.workspace.discard(ws, taskId, cur.title);
      this.ctx.db.tx(() => {
        if (ws) this.saveWorkspace(taskId, ws);
        if (cur.state === "failed") this.setState(taskId, "cancelled");
        this.ctx.incidents.resolveForTask(taskId, ["smoke", "rift", "alarm_bell"]);
        this.markDirty(taskId);
      });
    });
  }

  // ---------- hooks used by other services ----------

  onApprovalPending(taskId: string): void {
    const r = this.row(taskId);
    if (r.state === "running") this.setState(taskId, "awaiting_approval");
  }

  onApprovalResolved(taskId: string): void {
    const r = this.row(taskId);
    if (r.state === "awaiting_approval" && this.ctx.approvals.pendingCount(taskId) === 0) this.setState(taskId, "running");
  }

  createSubtask(input: { parent: TaskRow; agentId: string; title: string; prompt: string; size: TaskSize; sealMicros: number }): string {
    const id = this.ctx.ids.next("tsk");
    const now = this.ctx.clock.iso();
    const agent = this.ctx.agents.row(input.agentId);
    this.ctx.db.run(
      `INSERT INTO tasks (id, agent_id, party_id, parent_task_id, depth, title, prompt, prompt_hash, size, acceptance_json, rite,
         state, attempt, seal_micros, spent_is_estimate, courier_json, queue_pos, created_at, delivered_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, '[]', NULL, 'queued', 1, ?, ?, ?, ?, ?, ?, ?)`,
      [
        id,
        input.agentId,
        input.parent.party_id,
        input.parent.id,
        input.parent.depth + 1,
        input.title,
        input.prompt,
        promptHash(input.title, input.prompt),
        input.size,
        input.sealMicros,
        agent.billing === "subscription" ? 1 : 0,
        toJson({ mode: "express", human_id: null }),
        this.frontOfQueue(input.agentId),
        now,
        now,
        now,
      ],
    );
    this.markDirty(id);
    return id;
  }

  cancelQueuedForAgent(agentId: string): void {
    const rows = this.ctx.db.all<{ id: string }>("SELECT id FROM tasks WHERE agent_id = ? AND state IN ('in_transit','queued')", [
      agentId,
    ]);
    for (const r of rows) this.finishCancelled(r.id);
  }

  cancelAllForAgent(agentId: string): void {
    const rows = this.ctx.db.all<{ id: string }>(
      "SELECT id FROM tasks WHERE agent_id = ? AND state IN ('in_transit','queued','preparing','running','awaiting_approval','paused','failed')",
      [agentId],
    );
    for (const r of rows) {
      if (!this.ctx.supervisor.interrupt(r.id, { kind: "cancel" })) this.finishCancelled(r.id);
    }
  }

  scheduleRiftRetry(taskId: string): void {
    const delay = this.ctx.econ.data.incidents.rift_auto_retry_after_s * 1000;
    this.ctx.clock.clearTimeout(this.riftTimers.get(taskId));
    this.riftTimers.set(
      taskId,
      this.ctx.clock.setTimeout(() => {
        this.riftTimers.delete(taskId);
        const r = this.rowOrNull(taskId);
        if (!r || r.state !== "failed") return;
        this.ctx.db.tx(() => this.requeueFront(taskId));
        this.ctx.scheduler.kick();
      }, delay),
    );
  }

  /**
   * Startup recovery: runs that were live become paused(restart), pending approvals become
   * orphaned, courier timers are re-armed. Sessions without an unanswered approval resume.
   */
  recoverAfterRestart(): void {
    this.ctx.db.tx(() => {
      this.ctx.approvals.orphanAllPending();
      const live = this.ctx.db.all<TaskRow>("SELECT * FROM tasks WHERE state IN ('preparing','running','awaiting_approval')");
      for (const r of live) {
        const segment = r.run_started_at ? Math.max(0, Date.parse(r.updated_at) - Date.parse(r.run_started_at)) : 0;
        this.ctx.db.run("UPDATE tasks SET run_ms = run_ms + ?, run_started_at = NULL WHERE id = ?", [segment, r.id]);
        this.setState(r.id, "paused", "restart");
        this.ctx.mana.release(r.id);
        this.ctx.incidents.resolve(incidentKey.alarm(r.id));
      }
    });
    for (const r of this.ctx.db.all<{ id: string }>("SELECT id FROM tasks WHERE state = 'in_transit'")) this.armCourier(r.id);
    for (const r of this.ctx.db.all<{ id: string; rift_retries: number }>(
      "SELECT id, rift_retries FROM tasks WHERE state = 'failed' AND state_reason = 'PROVIDER_UNAVAILABLE'",
    )) {
      this.scheduleRiftRetry(r.id);
    }
    const resumable = this.ctx.db.all<{ id: string }>("SELECT id FROM tasks WHERE state = 'paused' AND state_reason = 'restart'");
    for (const r of resumable) {
      if (this.ctx.approvals.orphanedCount(r.id) === 0) this.ctx.db.tx(() => this.requeueFront(r.id));
    }
  }

  stop(): void {
    for (const t of this.courierTimers.values()) this.ctx.clock.clearTimeout(t);
    for (const t of this.riftTimers.values()) this.ctx.clock.clearTimeout(t);
    this.courierTimers.clear();
    this.riftTimers.clear();
  }
}
