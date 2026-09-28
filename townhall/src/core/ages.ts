import { fromJson } from "../db/db.js";
import { fail } from "../protocol/errors.js";
import type { Age } from "../protocol/objects.js";
import type { TimerHandle } from "./clock.js";
import type { Ctx } from "./context.js";
import { toResources } from "./economy.js";
import { rankAtLeast } from "./ranks.js";

interface AgeState {
  current: number;
  research: { target: number; started_at: string; duration_ms: number } | null;
}

export interface TownFacts {
  accepted: number;
  accepted_first_try: number;
  tools_built: number;
  rites_passed: number;
  party_tasks: number;
  under_baseline: number;
}

export class AgeService {
  private timer: TimerHandle | null = null;

  constructor(private readonly ctx: Ctx) {}

  private load(): AgeState {
    return this.ctx.settings.getState<AgeState>("age", { current: this.ctx.econ.data.start.age, research: null });
  }

  current(): number {
    return this.load().current;
  }

  state(): Age {
    const s = this.load();
    return { current: s.current, research: s.research };
  }

  start(): void {
    this.armTimer();
  }

  stop(): void {
    this.ctx.clock.clearTimeout(this.timer);
    this.timer = null;
  }

  private armTimer(): void {
    this.ctx.clock.clearTimeout(this.timer);
    this.timer = null;
    const s = this.load();
    if (!s.research) return;
    const due = Date.parse(s.research.started_at) + s.research.duration_ms;
    this.timer = this.ctx.clock.setTimeout(() => {
      this.timer = null;
      this.complete();
    }, Math.max(0, due - this.ctx.clock.now()));
  }

  facts(): TownFacts {
    const count = (sql: string) => this.ctx.db.get<{ n: number }>(sql)?.n ?? 0;
    const stats = this.ctx.db
      .all<{ stats_json: string }>("SELECT stats_json FROM agents")
      .map((r) => fromJson<{ rites_passed?: number }>(r.stats_json, {}));
    // Only verified outcomes count: accepted work that earned a reward.
    const rewarded = "state = 'accepted' AND parent_task_id IS NULL AND reward_rp > 0";
    return {
      accepted: count(`SELECT COUNT(*) AS n FROM tasks WHERE ${rewarded}`),
      accepted_first_try: count(`SELECT COUNT(*) AS n FROM tasks WHERE ${rewarded} AND attempt = 1`),
      tools_built: this.ctx.tools.builtCount(),
      rites_passed: stats.reduce((a, s) => a + (s.rites_passed ?? 0), 0),
      party_tasks: count(`SELECT COUNT(*) AS n FROM tasks WHERE ${rewarded} AND party_id IS NOT NULL`),
      under_baseline: count(`SELECT COUNT(*) AS n FROM tasks WHERE ${rewarded} AND mana_used_micros < baseline_micros`),
    };
  }

  /** Unmet milestones for reaching `target`, as readable strings. */
  missingMilestones(target: number): string[] {
    const def = this.ctx.econ.data.ages.find((a) => a.n === target);
    if (!def) return [`unknown age ${target}`];
    const m = def.milestones;
    const f = this.facts();
    const missing: string[] = [];
    const need = (have: number, want: number | undefined, label: string) => {
      if (want !== undefined && have < want) missing.push(`${label}: ${have}/${want}`);
    };
    need(f.accepted, m.accepted, "tasks accepted");
    need(f.accepted_first_try, m.accepted_first_try, "accepted on the first try");
    need(f.tools_built, m.tools_built, "add-ons built");
    need(f.rites_passed, m.rites_passed, "Rites passed");
    need(f.party_tasks, m.party_tasks, "party tasks");
    need(f.under_baseline, m.under_baseline, "tasks under the Mana baseline");
    if (m.agent_rank) {
      const ranked = this.ctx.db
        .all<{ rank: string }>("SELECT rank FROM agents WHERE retired_at IS NULL")
        .filter((a) => rankAtLeast(this.ctx.econ, a.rank, m.agent_rank!.rank)).length;
      need(ranked, m.agent_rank.count, `agents of rank ${m.agent_rank.rank} or higher`);
    }
    return missing;
  }

  advance(): { research: { target: number; started_at: string; duration_ms: number } } {
    const research = this.ctx.db.tx(() => {
      const s = this.load();
      if (s.research) throw fail.invalidState(`research of Age ${s.research.target} is already under way`);
      const target = s.current + 1;
      const def = this.ctx.econ.data.ages.find((a) => a.n === target);
      if (!def) throw fail.limit("the town has reached the last age");
      const missing = this.missingMilestones(target);
      if (missing.length > 0) throw fail.invalidState(`milestones not met for Age ${target}: ${missing.join("; ")}`);
      this.ctx.treasury.charge(toResources(def.cost), `age:${def.id}`, null, `age:${target}`);
      const r = { target, started_at: this.ctx.clock.iso(), duration_ms: Math.round(def.research_s * 1000) };
      this.ctx.settings.setState("age", { current: s.current, research: r } satisfies AgeState);
      this.ctx.bus.emit("age_updated", { age: this.state() }, "town/age");
      return r;
    });
    this.armTimer();
    return { research };
  }

  private complete(): void {
    this.ctx.db.tx(() => {
      const s = this.load();
      if (!s.research) return;
      this.ctx.settings.setState("age", { current: s.research.target, research: null } satisfies AgeState);
      this.ctx.bus.emit("age_updated", { age: this.state() }, "town/age");
      for (const a of this.ctx.db.all<{ id: string }>("SELECT id FROM agents WHERE retired_at IS NULL")) {
        this.ctx.agents.recomputeRank(a.id);
      }
    });
    this.ctx.scheduler.kick();
  }
}
