import { fromJson, toJson } from "../db/db.js";
import { fail } from "../protocol/errors.js";
import type { Party, TaskState } from "../protocol/objects.js";
import type { ChildResult, DelegateHandle, DelegateRequest } from "../providers/types.js";
import type { AgentRow } from "./agents.js";
import type { Ctx } from "./context.js";
import { rankAtLeast } from "./ranks.js";

interface PartyRow {
  id: string;
  lead_agent_id: string;
  member_ids_json: string;
  created_at: string;
  disbanded_at: string | null;
}

const OPEN_WORK_STATES = "('in_transit','queued','preparing','running','awaiting_approval','paused')";
/** A party cannot disband while any of its tasks is still open, including work under review. */
const UNFINISHED_STATES = "('in_transit','queued','preparing','running','awaiting_approval','paused','awaiting_review','accepting','failed')";
const CHILD_DONE_STATES: TaskState[] = ["awaiting_review", "accepting", "accepted", "rejected", "failed", "cancelled"];

export class PartyService {
  private readonly childWaiters = new Map<string, Array<(r: ChildResult) => void>>();

  constructor(private readonly ctx: Ctx) {}

  private toProtocol(r: PartyRow): Party {
    return {
      id: r.id,
      lead_agent_id: r.lead_agent_id,
      member_ids: fromJson<string[]>(r.member_ids_json, []),
      created_at: r.created_at,
    };
  }

  rowOrNull(id: string): PartyRow | null {
    return this.ctx.db.get<PartyRow>("SELECT * FROM parties WHERE id = ?", [id]) ?? null;
  }

  activeRow(id: string): PartyRow {
    const r = this.rowOrNull(id);
    if (!r || r.disbanded_at) throw fail.notFound("party", id);
    return r;
  }

  list(): Party[] {
    return this.ctx.db
      .all<PartyRow>("SELECT * FROM parties WHERE disbanded_at IS NULL ORDER BY created_at ASC")
      .map((r) => this.toProtocol(r));
  }

  members(partyId: string): AgentRow[] {
    const r = this.activeRow(partyId);
    return fromJson<string[]>(r.member_ids_json, [])
      .map((id) => this.ctx.agents.rowOrNull(id))
      .filter((a): a is AgentRow => !!a && !a.retired_at);
  }

  form(leadId: string, memberIds: string[]): { party_id: string } {
    const econ = this.ctx.econ;
    const rules = econ.data.parties;
    return this.ctx.db.tx(() => {
      const age = this.ctx.ages.current();
      if (age < rules.unlock_age) throw fail.age(`parties open in Age ${rules.unlock_age}`);
      const lead = this.ctx.agents.row(leadId);
      if (lead.retired_at) throw fail.invalidState("the lead is retired");
      if (!rules.lead_providers.includes(lead.provider)) {
        throw fail.badRequest(`party leads must use ${rules.lead_providers.join(" or ")}`);
      }
      if (!rankAtLeast(econ, lead.rank, rules.lead_min_rank)) throw fail.rank(`a party lead needs rank ${rules.lead_min_rank}`);
      if (lead.party_id) throw fail.conflict("the lead is already in a party");
      const unique = [...new Set(memberIds)];
      if (unique.length !== memberIds.length) throw fail.badRequest("members must be distinct");
      if (unique.includes(leadId)) throw fail.badRequest("the lead cannot also be a member");
      const size = econ.partySize(age);
      if (1 + unique.length > size) throw fail.limit(`Age ${age} allows parties of at most ${size}`);
      for (const id of unique) {
        const m = this.ctx.agents.row(id);
        if (m.retired_at) throw fail.invalidState(`agent ${id} is retired`);
        if (m.party_id) throw fail.conflict(`agent ${id} is already in a party`);
      }
      const id = this.ctx.ids.next("pty");
      this.ctx.db.run("INSERT INTO parties (id, lead_agent_id, member_ids_json, created_at) VALUES (?, ?, ?, ?)", [
        id,
        leadId,
        toJson(unique),
        this.ctx.clock.iso(),
      ]);
      this.ctx.agents.setParty(leadId, id);
      for (const m of unique) this.ctx.agents.setParty(m, id);
      this.ctx.bus.emit("party_updated", { party: this.toProtocol(this.activeRow(id)) }, `party/${id}`);
      return { party_id: id };
    });
  }

  disband(partyId: string, force = false): void {
    this.ctx.db.tx(() => {
      const r = this.activeRow(partyId);
      if (!force) {
        const open = this.ctx.db.get(`SELECT id FROM tasks WHERE party_id = ? AND state IN ${UNFINISHED_STATES} LIMIT 1`, [partyId]);
        if (open) throw fail.invalidState("the party still has unfinished work; finish, accept or cancel it first");
      }
      this.ctx.db.run("UPDATE parties SET disbanded_at = ? WHERE id = ?", [this.ctx.clock.iso(), partyId]);
      this.ctx.agents.setParty(r.lead_agent_id, null);
      for (const m of fromJson<string[]>(r.member_ids_json, [])) this.ctx.agents.setParty(m, null);
      this.ctx.bus.emit("party_disbanded", { party_id: partyId }, `party/${partyId}`);
    });
  }

  onAgentRetired(agentId: string): void {
    const parties = this.ctx.db.all<PartyRow>("SELECT * FROM parties WHERE disbanded_at IS NULL");
    for (const p of parties) {
      if (p.lead_agent_id === agentId) {
        this.disband(p.id, true);
        continue;
      }
      const members = fromJson<string[]>(p.member_ids_json, []);
      if (!members.includes(agentId)) continue;
      const rest = members.filter((m) => m !== agentId);
      this.ctx.db.run("UPDATE parties SET member_ids_json = ? WHERE id = ?", [toJson(rest), p.id]);
      this.ctx.bus.emit("party_updated", { party: this.toProtocol(this.activeRow(p.id)) }, `party/${p.id}`);
    }
  }

  /**
   * RunHost.delegate for party leads: creates a depth-1 sub-task on a member's queue with a
   * budget carved out of the parent's seal. Sub-tasks cannot delegate, so cycles are impossible;
   * the target is still checked against every ancestor's agent.
   */
  delegate(parentTaskId: string, fromAgentId: string, req: DelegateRequest): DelegateHandle {
    const rules = this.ctx.econ.data.parties;
    const childId = this.ctx.db.tx(() => {
      const parent = this.ctx.tasks.row(parentTaskId);
      if (parent.depth > 0) throw fail.badRequest("party sub-tasks cannot delegate further");
      if (!parent.party_id) throw fail.invalidState("only party tasks can delegate");
      const party = this.activeRow(parent.party_id);
      if (party.lead_agent_id !== fromAgentId) throw fail.invalidState("only the party lead can delegate");
      const members = this.members(party.id);
      let target: AgentRow | undefined;
      const indexMatch = /^member:(\d+)$/.exec(req.to);
      if (indexMatch) target = members[Number(indexMatch[1])];
      else if (req.to === "any") target = members.find((m) => !this.ctx.agents.currentTaskId(m.id)) ?? members[0];
      else target = members.find((m) => m.id === req.to);
      if (!target) throw fail.badRequest(`no party member matches "${req.to}"`);
      const ancestors = new Set<string>([fromAgentId]);
      let cursor: string | null = parent.parent_task_id;
      ancestors.add(parent.agent_id);
      while (cursor) {
        const t = this.ctx.tasks.row(cursor);
        ancestors.add(t.agent_id);
        cursor = t.parent_task_id;
      }
      if (ancestors.has(target.id)) throw fail.badRequest("delegation would form a cycle");
      // A resumed session may re-issue a delegation it already made: hand back the same sub-task.
      const same = this.ctx.db.get<{ id: string }>(
        `SELECT id FROM tasks WHERE parent_task_id = ? AND agent_id = ? AND title = ? AND prompt = ?
           AND state IN ('queued','preparing','running','awaiting_approval','paused','awaiting_review') LIMIT 1`,
        [parentTaskId, target.id, req.title, req.prompt],
      );
      if (same) return same.id;
      const open =
        this.ctx.db.get<{ n: number }>(
          `SELECT COUNT(*) AS n FROM tasks WHERE parent_task_id = ? AND state IN ${OPEN_WORK_STATES}`,
          [parentTaskId],
        )?.n ?? 0;
      if (open >= rules.max_open_subtasks) throw fail.limit(`at most ${rules.max_open_subtasks} open sub-tasks`);
      if (parent.subtasks_total >= rules.max_total_subtasks) throw fail.limit(`at most ${rules.max_total_subtasks} sub-tasks per task`);
      const childSeal = this.ctx.econ.manaToMicros(req.budgetMana);
      if (childSeal <= 0) throw fail.badRequest("the sub-task needs a budget");
      if (parent.seal_micros - parent.spent_micros < childSeal) {
        throw fail.mana("the parent task's seal cannot cover that budget");
      }
      this.ctx.db.run("UPDATE tasks SET seal_micros = seal_micros - ?, subtasks_total = subtasks_total + 1 WHERE id = ?", [
        childSeal,
        parentTaskId,
      ]);
      this.ctx.tasks.markDirty(parentTaskId);
      const id = this.ctx.tasks.createSubtask({
        parent,
        agentId: target.id,
        title: req.title,
        prompt: req.prompt,
        size: req.size,
        sealMicros: childSeal,
      });
      this.ctx.mana.transferReservation(parentTaskId, id, childSeal);
      this.ctx.bus.emit(
        "subtask_delegated",
        { parent_task_id: parentTaskId, task_id: id, from_agent_id: fromAgentId, to_agent_id: target.id },
        `task/${parentTaskId}`,
      );
      return id;
    });
    this.ctx.scheduler.kick();
    const maxWait = rules.await_timeout_max_s * 1000;
    return {
      taskId: childId,
      wait: (timeoutMs?: number) => this.waitForChild(childId, Math.min(timeoutMs ?? maxWait, maxWait)),
    };
  }

  private childResult(childId: string, timedOut = false): ChildResult {
    const t = this.ctx.tasks.row(childId);
    const result = this.ctx.tasks.get(childId).result;
    let status: ChildResult["status"] = "done";
    if (timedOut) status = "timeout";
    else if (t.state === "failed") status = "failed";
    else if (t.state === "cancelled" || t.state === "rejected") status = "cancelled";
    return { taskId: childId, status, summary: result?.summary ?? "", diffStat: result?.diff_stat ?? null };
  }

  waitForChild(childId: string, timeoutMs: number): Promise<ChildResult> {
    const t = this.ctx.tasks.row(childId);
    if (CHILD_DONE_STATES.includes(t.state)) return Promise.resolve(this.childResult(childId));
    return new Promise<ChildResult>((resolve) => {
      let settled = false;
      const timer = this.ctx.clock.setTimeout(() => {
        if (settled) return;
        settled = true;
        resolve(this.childResult(childId, true));
      }, timeoutMs);
      const list = this.childWaiters.get(childId) ?? [];
      list.push((r) => {
        if (settled) return;
        settled = true;
        this.ctx.clock.clearTimeout(timer);
        resolve(r);
      });
      this.childWaiters.set(childId, list);
    });
  }

  /** Called when a sub-task reaches review or a final state. */
  notifyChildFinished(childId: string): void {
    const list = this.childWaiters.get(childId);
    if (!list) return;
    this.childWaiters.delete(childId);
    const result = this.childResult(childId);
    for (const w of list) w(result);
  }
}
