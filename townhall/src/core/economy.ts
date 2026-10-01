import { readFileSync } from "node:fs";
import { z } from "zod";
import { compileFormula, type Formula } from "./expr.js";

export const RESOURCE_KEYS = ["food", "wood", "stone", "gold"] as const;
export type ResourceKey = (typeof RESOURCE_KEYS)[number];
export type Resources = Record<ResourceKey, number>;
export type Cost = Partial<Resources>;

export const SIZES = ["S", "M", "L", "XL"] as const;
export type Size = (typeof SIZES)[number];

const int = z.number().int();
const nonNegInt = int.min(0);
const fraction = z.number().min(0).max(1);
const costSchema = z.object({
  food: nonNegInt.optional(),
  wood: nonNegInt.optional(),
  stone: nonNegInt.optional(),
  gold: nonNegInt.optional(),
});
const bySize = <T extends z.ZodType>(t: T) => z.object({ S: t, M: t, L: t, XL: t });
const byAge = z.array(nonNegInt).length(4);

const roleSchema = z.looseObject({
  name: z.string(),
  age: int.min(1),
  cost: costSchema,
  train_s: z.number().min(0),
  home: z.string(),
  required_tools: z.array(z.string()),
  recommended_tools: z.array(z.string()),
  default_tools: z.array(z.string()),
  // A string-keyed record keeps the declared key order, which breaks rounding ties in splitReward.
  reward_split: z
    .record(z.string(), fraction)
    .refine((split) => Object.keys(split).every((k) => (RESOURCE_KEYS as readonly string[]).includes(k)), {
      message: "reward_split keys must be resource names",
    }),
});

const toolSchema = z.looseObject({
  name: z.string(),
  cost: costSchema,
  build_s: z.number().min(0),
  age: int.min(1),
  requires: z.array(z.string()),
});

const buildingSchema = z.looseObject({
  name: z.string(),
  cost: costSchema.optional(),
  build_s: z.number().optional(),
  role: z.string().optional(),
});

const milestonesSchema = z.looseObject({
  accepted: nonNegInt.optional(),
  tools_built: nonNegInt.optional(),
  accepted_first_try: nonNegInt.optional(),
  rites_passed: nonNegInt.optional(),
  party_tasks: nonNegInt.optional(),
  under_baseline: nonNegInt.optional(),
  agent_rank: z.object({ rank: z.string(), count: nonNegInt }).optional(),
});

const rankSchema = z.looseObject({
  rank: z.string(),
  xp: nonNegInt,
  accepted: nonNegInt,
  first_try_rate: fraction.optional(),
  rites_passed: nonNegInt.optional(),
  party_tasks: nonNegInt.optional(),
  median_mana_at_or_under_baseline: z.boolean().optional(),
  age: int.optional(),
  unlocks: z.array(z.string()).optional(),
});

export const economySchema = z.looseObject({
  version: int,
  start: z.looseObject({ resources: costSchema, townsfolk: nonNegInt, age: int.min(1).max(4) }),
  resources: z.array(z.enum(RESOURCE_KEYS)),
  storage: z.looseObject({
    capped: z.array(z.enum(RESOURCE_KEYS)),
    cap_by_age: byAge,
    storehouse_bonus: nonNegInt,
  }),
  population: z.looseObject({ agent_limit_by_age: byAge, cap_by_age: byAge }),
  agent_cost_scaling_per_existing: z.number().min(0),
  roles: z.record(z.string(), roleSchema),
  buildings: z.record(z.string(), buildingSchema),
  tools: z.record(z.string(), toolSchema),
  tool_slots_by_age: byAge,
  home_task_queue_by_age: byAge,
  approval_modes: z.record(
    z.string(),
    z.looseObject({
      age: int.min(1),
      min_rank: z.string(),
      providers: z.array(z.string()).optional(),
      default: z.boolean().optional(),
    }),
  ),
  ages: z
    .array(
      z.looseObject({
        n: int,
        id: z.string(),
        name: z.string(),
        /** The wall ring the age raises ("Merchant Ring"). */
        wall: z.string().optional(),
        cost: costSchema,
        research_s: z.number().min(0),
        milestones: milestonesSchema,
      }),
    )
    .length(4),
  bounty: z.looseObject({
    formula: z.string(),
    base_by_size: bySize(z.number().min(0)),
    first_try_bonus_by_attempt: z.array(z.number()).min(1),
    efficiency: z.object({ weight: z.number(), max_ratio: z.number() }),
    baseline_seed_mana: bySize(z.number().positive()),
    baseline_window: int.min(1),
    practice_bonus: z.object({ archive: z.number(), recommended_tools: z.number(), rite_passed: z.number() }),
    daily_full_count: bySize(nonNegInt),
    diminished_multiplier: z.number().min(0),
    ceiling: z.object({ min: z.number().min(0), per_mana: z.number().min(0) }),
    duplicate_window_h: z.number().min(0),
    min_run_s: z.number().min(0),
    party_split: z.object({ lead: fraction, members: fraction }),
    xp_per_rp: z.number().min(0),
  }),
  mana: z.looseObject({
    micros_per_mana: int.positive(),
    default_pool_usd: z.number().min(0),
    default_period: z.enum(["day", "week", "month"]),
    refill_hour_local: int.min(0).max(23),
    seal_by_size: bySize(z.number().positive()),
    start_min_fraction_of_seal: fraction,
    min_reservation_usd: z.number().min(0),
    seal_warning_fraction: fraction,
    extend_fraction: z.number().min(0),
    lights_out_fraction: fraction,
    stages: z.object({ dim: fraction, warning: fraction }),
    kill_after_interrupt_s: z.number().min(0),
  }),
  ranks: z.array(rankSchema).min(1),
  rank_first_try_window: int.min(1),
  levels: z.object({ xp_for_level: z.string(), max: int.min(1) }),
  parties: z.looseObject({
    unlock_age: int.min(1),
    lead_min_rank: z.string(),
    size_by_age: byAge,
    lead_providers: z.array(z.string()),
    max_open_subtasks: int.min(0),
    max_total_subtasks: int.min(0),
    await_timeout_max_s: z.number().min(0),
  }),
  incidents: z.looseObject({
    stuck_minutes_by_size: bySize(z.number().positive()),
    stall_pause_minutes: z.number().positive(),
    repeat_tool_calls: int.min(2),
    approval_louder_after_s: z.number().min(0),
    rift_auto_retry_after_s: z.number().min(0),
    preparing_timeout_s: z.number().positive(),
    transient_retries: nonNegInt,
  }),
  couriers: z.looseObject({ wisp_after_s: z.number().min(0), force_deliver_after_s: z.number().min(0) }),
  anti_deadlock: z.looseObject({
    fonts_grace: z.object({ when_agents: nonNegInt, free: z.array(z.string()) }),
  }),
  quartermaster: z.looseObject({
    age: int.min(1),
    sell_basic: z.object({
      give: z.number().positive(),
      get: z.number().positive(),
      give_from: z.array(z.enum(RESOURCE_KEYS)),
      get_to: z.array(z.enum(RESOURCE_KEYS)),
    }),
    sell_precious: z.object({
      give: z.number().positive(),
      get: z.number().positive(),
      give_from: z.array(z.enum(RESOURCE_KEYS)),
      get_to: z.array(z.enum(RESOURCE_KEYS)),
    }),
    worsen_per_trade: z.number().min(0),
    recover_per_minute: z.number().min(0),
  }),
  refunds: z.object({ cancel: fraction, dismantle: fraction }),
});

export type EconomyData = z.infer<typeof economySchema>;
export type QuartermasterKind = "basic" | "precious";

export class Economy {
  readonly rankOrder: string[];
  private readonly xpForLevelFormula: Formula;
  private readonly bountyFormula: Formula;

  constructor(readonly data: EconomyData) {
    this.rankOrder = data.ranks.map((r) => r.rank);
    this.xpForLevelFormula = compileFormula(data.levels.xp_for_level);
    this.bountyFormula = compileFormula(data.bounty.formula);
  }

  static load(filePath: string): Economy {
    const raw = JSON.parse(readFileSync(filePath, "utf8")) as unknown;
    const parsed = economySchema.safeParse(raw);
    if (!parsed.success) {
      const first = parsed.error.issues
        .slice(0, 5)
        .map((i) => `${i.path.join(".")}: ${i.message}`)
        .join("; ");
      throw new Error(`economy.json is invalid: ${first}`);
    }
    return new Economy(parsed.data);
  }

  private byAge(list: number[], age: number): number {
    const idx = Math.min(Math.max(age, 1), list.length) - 1;
    return list[idx]!;
  }

  agentLimit(age: number): number {
    return this.byAge(this.data.population.agent_limit_by_age, age);
  }

  toolSlots(age: number): number {
    return this.byAge(this.data.tool_slots_by_age, age);
  }

  queueLimit(age: number): number {
    return this.byAge(this.data.home_task_queue_by_age, age);
  }

  storageCap(age: number, storehouses: number): number {
    return this.byAge(this.data.storage.cap_by_age, age) + storehouses * this.data.storage.storehouse_bonus;
  }

  partySize(age: number): number {
    return this.byAge(this.data.parties.size_by_age, age);
  }

  rankIndex(rank: string): number {
    return this.rankOrder.indexOf(rank);
  }

  xpForLevel(level: number): number {
    return this.xpForLevelFormula({ L: level });
  }

  levelForXp(xp: number): number {
    let level = 1;
    for (let l = 2; l <= this.data.levels.max; l++) {
      if (this.xpForLevel(l) <= xp) level = l;
      else break;
    }
    return level;
  }

  evaluateBounty(vars: { BASE: number; Q: number; E: number; P: number; D: number; CEIL: number }): number {
    return this.bountyFormula(vars);
  }

  manaToMicros(mana: number): number {
    return Math.round(mana * this.data.mana.micros_per_mana);
  }

  microsToMana(micros: number): number {
    return micros / this.data.mana.micros_per_mana;
  }

  usdToMicros(usd: number): number {
    return Math.round(usd * 1_000_000);
  }
}

export function zeroResources(): Resources {
  return { food: 0, wood: 0, stone: 0, gold: 0 };
}

export function toResources(cost: Cost): Resources {
  return {
    food: cost.food ?? 0,
    wood: cost.wood ?? 0,
    stone: cost.stone ?? 0,
    gold: cost.gold ?? 0,
  };
}

export function scaleCost(cost: Cost, factor: number, round: (n: number) => number = Math.round): Resources {
  const r = toResources(cost);
  return {
    food: round(r.food * factor),
    wood: round(r.wood * factor),
    stone: round(r.stone * factor),
    gold: round(r.gold * factor),
  };
}

export function isZero(r: Resources): boolean {
  return RESOURCE_KEYS.every((k) => r[k] === 0);
}

export function negate(r: Resources): Resources {
  return { food: -r.food, wood: -r.wood, stone: -r.stone, gold: -r.gold };
}
