import { fromJson } from "../db/db.js";
import { fail } from "../protocol/errors.js";
import type { Age, Milestone, MilestoneKey, TownFacts } from "../protocol/objects.js";
import type { TimerHandle } from "./clock.js";
import type { Ctx } from "./context.js";
import { toResources } from "./economy.js";
import { rankAtLeast } from "./ranks.js";

export type { TownFacts } from "../protocol/objects.js";

interface AgeState {
  current: number;
  research: { target: number; started_at: string; duration_ms: number } | null;
}

/** Player-facing names of the milestones, in the order they are listed. */
const MILESTONE_LABELS: Record<Exclude<MilestoneKey, "agent_rank">, string> = {
  accepted: "tasks accepted",
  accepted_first_try: "accepted on the first try",
  tools_built: "add-ons built",
  rites_passed: "Rites passed",
  party_tasks: "party tasks",
  under_baseline: "tasks under the Mana baseline",
};

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

  /**
   * Every milestone economy.json sets for reaching `target`, with what the town has: met or not,
   * in a fixed order. Empty for an unknown age or one without milestones.
   */
  milestones(target: number, facts: TownFacts = this.facts()): Milestone[] {
    const def = this.ctx.econ.data.ages.find((a) => a.n === target);
    if (!def) return [];
    const m = def.milestones;
    const out: Milestone[] = [];
    const add = (key: MilestoneKey, have: number, want: number | undefined, label: string) => {
      if (want !== undefined) out.push({ key, label, have, want, met: have >= want });
    };
    for (const key of Object.keys(MILESTONE_LABELS) as Array<keyof typeof MILESTONE_LABELS>) {
      add(key, facts[key], m[key], MILESTONE_LABELS[key]);
    }
    if (m.agent_rank) {
      const rank = m.agent_rank.rank;
      const ranked = this.ctx.db
        .all<{ rank: string }>("SELECT rank FROM agents WHERE retired_at IS NULL")
        .filter((a) => rankAtLeast(this.ctx.econ, a.rank, rank)).length;
      add("agent_rank", ranked, m.agent_rank.count, `agents of rank ${rank} or higher`);
    }
    return out;
  }

  /** Unmet milestones for reaching `target`, as readable strings. */
  missingMilestones(target: number): string[] {
    if (!this.ctx.econ.data.ages.some((a) => a.n === target)) return [`unknown age ${target}`];
    return this.milestones(target)
      .filter((m) => !m.met)
      .map((m) => `${m.label}: ${m.have}/${m.want}`);
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
