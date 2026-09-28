import type { Rewards } from "../protocol/objects.js";
import type { Ctx } from "./context.js";
import { RESOURCE_KEYS, zeroResources, type Economy, type ResourceKey, type Resources, type Size } from "./economy.js";
import { median } from "./ranks.js";

export interface BountyInput {
  size: Size;
  attempt: number;
  /** Mana used by the task (and its party sub-tasks). */
  manaUsed: number;
  baselineMana: number;
  hasArchive: boolean;
  hasRecommendedTools: boolean;
  ritePassed: boolean;
  /** Rewarded tasks of the same size in the last day, not counting this one. */
  rewardedTodaySameSize: number;
}

export interface BountyBreakdown {
  base: number;
  q: number;
  e: number;
  p: number;
  d: number;
  ceiling: number;
}

const round4 = (n: number) => Math.round(n * 10_000) / 10_000;

/** RP = min(BASE * (1 + Q + E + P) * D, CEIL), with every constant from economy.json. */
export function computeBounty(econ: Economy, input: BountyInput): { rp: number; breakdown: BountyBreakdown } {
  const b = econ.data.bounty;
  const base = b.base_by_size[input.size];
  const qList = b.first_try_bonus_by_attempt;
  const q = qList[Math.min(Math.max(input.attempt, 1) - 1, qList.length - 1)]!;
  const ratio = input.baselineMana > 0 ? (input.baselineMana - input.manaUsed) / input.baselineMana : 0;
  const e = b.efficiency.weight * Math.min(b.efficiency.max_ratio, Math.max(0, ratio));
  const p =
    (input.hasArchive ? b.practice_bonus.archive : 0) +
    (input.hasRecommendedTools ? b.practice_bonus.recommended_tools : 0) +
    (input.ritePassed ? b.practice_bonus.rite_passed : 0);
  const d = input.rewardedTodaySameSize >= b.daily_full_count[input.size] ? b.diminished_multiplier : 1;
  const ceiling = Math.max(b.ceiling.min, b.ceiling.per_mana * input.manaUsed);
  const raw = econ.evaluateBounty({ BASE: base, Q: q, E: e, P: p, D: d, CEIL: ceiling });
  // Clean floating-point noise (180 * 1.95 = 350.99999999999994) before rounding.
  const rp = Math.max(0, Math.round(Math.round(raw * 1e6) / 1e6));
  return { rp, breakdown: { base, q: round4(q), e: round4(e), p: round4(p), d, ceiling: round4(ceiling) } };
}

/**
 * Splits RP into resources by the role's reward_split so the parts add up to RP exactly
 * (largest remainder; ties go to the resource listed first in the split).
 */
export function splitReward(rp: number, split: Partial<Record<ResourceKey, number>>): Resources {
  const out = zeroResources();
  const keys = (Object.keys(split) as ResourceKey[]).filter((k) => RESOURCE_KEYS.includes(k));
  const weights = keys.map((k) => Math.round((split[k] ?? 0) * 1_000_000));
  const total = weights.reduce((a, w) => a + w, 0);
  if (total <= 0 || rp <= 0) return out;
  const floors = weights.map((w) => Math.floor((rp * w) / total));
  const remainders = weights.map((w) => (rp * w) % total);
  let left = rp - floors.reduce((a, f) => a + f, 0);
  const order = keys.map((_, i) => i).sort((a, b) => remainders[b]! - remainders[a]! || a - b);
  for (const i of order) {
    if (left <= 0) break;
    floors[i]! += 1;
    left -= 1;
  }
  keys.forEach((k, i) => (out[k] = floors[i]!));
  return out;
}

/** Splits XP between a party lead and its members (lead share first, members evenly). */
export function splitPartyXp(xp: number, leadShare: number, memberCount: number): { lead: number; members: number[] } {
  if (memberCount <= 0) return { lead: xp, members: [] };
  const lead = Math.round(xp * leadShare);
  const rest = xp - lead;
  const each = Math.floor(rest / memberCount);
  const members = Array.from({ length: memberCount }, (_, i) => each + (i < rest - each * memberCount ? 1 : 0));
  return { lead, members };
}

export type ZeroReason = "duplicate" | "no_deliverable" | "too_short" | "party_subtask";

export function zeroRewards(econ: Economy, size: Size, zeroReason: ZeroReason): Rewards {
  return {
    rp: 0,
    xp: 0,
    resources: zeroResources(),
    breakdown: {
      base: econ.data.bounty.base_by_size[size],
      q: 0,
      e: 0,
      p: 0,
      d: 1,
      ceiling: 0,
      zero_reason: zeroReason,
    },
  };
}

export class BountyService {
  constructor(private readonly ctx: Ctx) {}

  /** Rolling median of Mana used by accepted tasks of this role and size, padded with the seed. */
  baselineMicros(role: string, size: Size): number {
    const b = this.ctx.econ.data.bounty;
    const window = b.baseline_window;
    const rows = this.ctx.db.all<{ mana_used_micros: number }>(
      "SELECT mana_used_micros FROM tasks WHERE accepted_at IS NOT NULL AND parent_task_id IS NULL AND role_at_accept = ? AND size = ? AND mana_used_micros IS NOT NULL AND reward_rp > 0 ORDER BY accepted_at DESC LIMIT ?",
      [role, size, window],
    );
    const seed = this.ctx.econ.manaToMicros(b.baseline_seed_mana[size]);
    const samples = rows.map((r) => r.mana_used_micros);
    while (samples.length < window) samples.push(seed);
    return median(samples) ?? seed;
  }

  rewardedTodaySameSize(size: Size, excludeTaskId: string): number {
    const since = new Date(this.ctx.clock.now() - 24 * 3600 * 1000).toISOString();
    return (
      this.ctx.db.get<{ n: number }>(
        "SELECT COUNT(*) AS n FROM tasks WHERE accepted_at >= ? AND size = ? AND reward_rp > 0 AND parent_task_id IS NULL AND id != ?",
        [since, size, excludeTaskId],
      )?.n ?? 0
    );
  }

  isDuplicate(promptHash: string, excludeTaskId: string): boolean {
    const hours = this.ctx.econ.data.bounty.duplicate_window_h;
    const since = new Date(this.ctx.clock.now() - hours * 3600 * 1000).toISOString();
    return !!this.ctx.db.get(
      "SELECT id FROM tasks WHERE prompt_hash = ? AND id != ? AND accepted_at >= ? AND reward_rp > 0",
      [promptHash, excludeTaskId, since],
    );
  }
}
