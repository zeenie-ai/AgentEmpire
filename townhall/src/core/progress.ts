import type { EventType } from "../protocol/events.js";
import type { Agent, NextAge, Progress } from "../protocol/objects.js";
import type { TimerHandle } from "./clock.js";
import type { Ctx } from "./context.js";
import { toResources } from "./economy.js";

/** While the Quartermaster's prices recover, progress is checked again this often (and no more). */
export const QUARTERMASTER_RECHECK_MS = 60_000;
/** The last progress sent, kept so a restart only announces what changed while it was away. */
const STATE_KEY = "progress";

/**
 * The town's progression (get_progress, get_state.progress) and its `progress_updated` event.
 *
 * Anything that can move it marks it for a check inside the transaction that made the change:
 * an accepted task, an add-on built or dismantled, an agent's rank or retirement, the age, the
 * treasury (it decides whether the next age is affordable) and Quartermaster trades. Just before
 * COMMIT the object is rebuilt, and the event goes out only when it differs from the last one
 * sent. The Quartermaster's prices recover with time; that is picked up by a check at most once a
 * minute while a price is still recovering.
 */
export class ProgressService {
  /** Startup work (recovery, agent refresh) emits events before start(): nothing is sent until then. */
  private started = false;
  private dirty = false;
  /** JSON of the last progress sent in a committed transaction. */
  private last: string | null = null;
  /** JSON of the progress sent in the open transaction, until it commits. */
  private pending: string | null = null;
  private timer: TimerHandle | null = null;
  private readonly agentSigs = new Map<string, string>();

  constructor(private readonly ctx: Ctx) {
    ctx.bus.observe((type, payload) => this.observe(type, payload));
    ctx.bus.addFlusher(() => this.flush());
    ctx.db.addAfterCommit(() => {
      if (this.pending === null) return;
      this.last = this.pending;
      this.pending = null;
    });
    ctx.db.addAfterRollback(() => {
      this.pending = null;
      this.dirty = false;
      // Signatures seen in the rolled-back transaction may describe changes that never happened.
      this.agentSigs.clear();
    });
  }

  /** The current progression. */
  snapshot(): Progress {
    const ctx = this.ctx;
    const age = ctx.ages.state();
    const facts = ctx.ages.facts();
    const def = ctx.econ.data.ages.find((a) => a.n === age.current + 1);
    let next: NextAge | null = null;
    if (def) {
      const milestones = ctx.ages.milestones(def.n, facts);
      const cost = toResources(def.cost);
      next = {
        n: def.n,
        id: def.id,
        name: def.name,
        wall: def.wall ?? def.name,
        cost,
        research_s: def.research_s,
        // Exactly when advance_age would succeed now.
        ready: age.research === null && milestones.every((m) => m.met) && ctx.treasury.canAfford(cost),
        milestones,
      };
    }
    return { age, facts, next, quartermaster: ctx.treasury.marketRates() };
  }

  /**
   * Called at startup, after the other services: announces the progress once if it changed while
   * the Town Hall was not running (a new economy.json, prices that recovered), else stays quiet.
   */
  start(): void {
    this.started = true;
    const stored = this.ctx.settings.getState<Progress | null>(STATE_KEY, null);
    if (stored) {
      this.last = JSON.stringify(stored);
      this.ctx.db.tx(() => {
        this.dirty = true;
      });
    } else {
      // A new town: the first client gets the progress with its first snapshot.
      const progress = this.snapshot();
      this.ctx.db.tx(() => this.ctx.settings.setState(STATE_KEY, progress));
      this.last = JSON.stringify(progress);
    }
    if (this.ctx.treasury.marketRecovering()) this.armRecheck();
  }

  stop(): void {
    this.ctx.clock.clearTimeout(this.timer);
    this.timer = null;
  }

  private observe(type: EventType, payload: unknown): void {
    switch (type) {
      case "age_updated":
      case "tool_updated":
      case "agent_retired":
        this.dirty = true;
        break;
      case "treasury_updated": {
        this.dirty = true;
        const reason = (payload as { reason?: unknown }).reason;
        if (typeof reason === "string" && reason.startsWith("trade:")) this.armRecheck();
        break;
      }
      case "task_updated":
        // Only accepted work counts towards the milestones.
        if ((payload as { task?: { state?: unknown } }).task?.state === "accepted") this.dirty = true;
        break;
      case "agent_updated": {
        // Agents change often (activity, queues); only rank, retirement and Rites matter here.
        const a = (payload as { agent?: Agent }).agent;
        if (!a) break;
        const sig = `${a.rank}|${a.lifecycle}|${a.stats.rites_passed}`;
        if (this.agentSigs.get(a.id) !== sig) {
          this.agentSigs.set(a.id, sig);
          this.dirty = true;
        }
        break;
      }
      default:
        break;
    }
  }

  private flush(): boolean {
    if (!this.started || !this.dirty) return false;
    this.dirty = false;
    const progress = this.snapshot();
    const json = JSON.stringify(progress);
    if (json === (this.pending ?? this.last)) return false;
    this.ctx.bus.emit("progress_updated", progress, "town/progress");
    this.ctx.settings.setState(STATE_KEY, progress);
    this.pending = json;
    return true;
  }

  private armRecheck(): void {
    if (this.timer) return;
    this.timer = this.ctx.clock.setTimeout(() => {
      this.timer = null;
      try {
        this.ctx.db.tx(() => {
          this.dirty = true;
        });
      } catch (err) {
        this.ctx.log.warn({ err: String(err) }, "progress check failed");
      }
      if (this.ctx.treasury.marketRecovering()) this.armRecheck();
    }, QUARTERMASTER_RECHECK_MS);
  }
}
