import type { Economy } from "./economy.js";

export interface RankFacts {
  xp: number;
  accepted: number;
  /** Share of accepted tasks accepted on the first attempt, over the rank window. */
  firstTryRate: number;
  ritesPassed: number;
  partyTasks: number;
  /** Median of (Mana used / baseline) over the rank window, or null without history. */
  medianManaRatio: number | null;
  townAge: number;
}

/** The highest rank whose requirements, and those of every lower rank, are all met. */
export function computeRank(econ: Economy, facts: RankFacts): string {
  let rank = econ.rankOrder[0]!;
  for (const r of econ.data.ranks) {
    if (facts.xp < r.xp) break;
    if (facts.accepted < r.accepted) break;
    if (r.first_try_rate !== undefined && facts.firstTryRate < r.first_try_rate) break;
    if (r.rites_passed !== undefined && facts.ritesPassed < r.rites_passed) break;
    if (r.party_tasks !== undefined && facts.partyTasks < r.party_tasks) break;
    if (r.median_mana_at_or_under_baseline && !(facts.medianManaRatio !== null && facts.medianManaRatio <= 1)) break;
    if (r.age !== undefined && facts.townAge < r.age) break;
    rank = r.rank;
  }
  return rank;
}

export function rankAtLeast(econ: Economy, rank: string, minimum: string): boolean {
  const a = econ.rankIndex(rank);
  const b = econ.rankIndex(minimum);
  return a >= 0 && b >= 0 && a >= b;
}

export function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const s = [...values].sort((x, y) => x - y);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 === 1 ? s[mid]! : (s[mid - 1]! + s[mid]!) / 2;
}
