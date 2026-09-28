import type { AgentRow } from "../agents.js";
import type { Ctx } from "../context.js";

/**
 * Starts the next queued task for every idle, unblocked agent when the Mana rules allow it.
 * Kicks are coalesced into one pass per event-loop turn.
 */
export class Scheduler {
  private scheduled = false;
  private stopped = false;

  constructor(private readonly ctx: Ctx) {}

  kick(): void {
    if (this.scheduled || this.stopped) return;
    this.scheduled = true;
    setImmediate(() => {
      this.scheduled = false;
      try {
        this.tick();
      } catch (err) {
        this.ctx.log.error({ err: String(err) }, "scheduler pass failed");
      }
    });
  }

  stop(): void {
    this.stopped = true;
  }

  tick(): void {
    if (this.stopped) return;
    const awayAllowed = this.ctx.settings.get().work_while_away || this.ctx.presence.hasClient();
    const agents = this.ctx.db.all<AgentRow>("SELECT * FROM agents WHERE retired_at IS NULL ORDER BY created_at ASC");
    for (const agent of agents) {
      this.ctx.agents.maybeRetireAfterCurrent(agent.id);
      if (!this.ctx.agents.isDispatchable(agent) || this.ctx.agents.currentTaskId(agent.id)) {
        this.ctx.agents.refreshIfChanged(agent.id);
        continue;
      }
      const next = this.ctx.tasks.nextQueued(agent.id);
      if (!next || !awayAllowed || !this.ctx.mana.canStart(next).ok) {
        this.ctx.agents.refreshIfChanged(agent.id);
        continue;
      }
      const started = this.ctx.db.tx(() => {
        const cur = this.ctx.tasks.row(next.id);
        if (cur.state !== "queued" || this.ctx.agents.currentTaskId(agent.id)) return false;
        this.ctx.mana.reserve(next.id);
        this.ctx.tasks.setState(next.id, "preparing");
        return true;
      });
      if (started) void this.ctx.supervisor.start(next.id);
    }
  }
}
