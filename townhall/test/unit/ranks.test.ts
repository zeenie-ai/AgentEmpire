import { describe, expect, it } from "vitest";
import { Economy } from "../../src/core/economy.js";
import { computeRank, median, rankAtLeast, type RankFacts } from "../../src/core/ranks.js";
import { defaultEconomyPath } from "../../src/paths.js";

const econ = Economy.load(defaultEconomyPath());

const base: RankFacts = {
  xp: 0,
  accepted: 0,
  firstTryRate: 0,
  ritesPassed: 0,
  partyTasks: 0,
  medianManaRatio: null,
  townAge: 1,
};

describe("levels", () => {
  it("follows xp_for_level = 50 * L * (L - 1)", () => {
    expect(econ.xpForLevel(1)).toBe(0);
    expect(econ.xpForLevel(2)).toBe(100);
    expect(econ.xpForLevel(4)).toBe(600);
    expect(econ.levelForXp(0)).toBe(1);
    expect(econ.levelForXp(99)).toBe(1);
    expect(econ.levelForXp(100)).toBe(2);
    expect(econ.levelForXp(351)).toBe(3);
    expect(econ.levelForXp(10_000_000)).toBe(econ.data.levels.max);
  });
});

describe("ranks", () => {
  it("starts at F", () => {
    expect(computeRank(econ, base)).toBe("F");
  });

  it("needs both XP and accepted tasks for E", () => {
    expect(computeRank(econ, { ...base, xp: 150, accepted: 1 })).toBe("F");
    expect(computeRank(econ, { ...base, xp: 149, accepted: 2 })).toBe("F");
    expect(computeRank(econ, { ...base, xp: 150, accepted: 2 })).toBe("E");
  });

  it("needs the first-try rate for D", () => {
    expect(computeRank(econ, { ...base, xp: 600, accepted: 6, firstTryRate: 0.49 })).toBe("E");
    expect(computeRank(econ, { ...base, xp: 600, accepted: 6, firstTryRate: 0.5 })).toBe("D");
  });

  it("needs passed Rites for C (the v1 ceiling)", () => {
    const c = { ...base, xp: 1800, accepted: 15, firstTryRate: 0.6 };
    expect(computeRank(econ, { ...c, ritesPassed: 1 })).toBe("D");
    expect(computeRank(econ, { ...c, ritesPassed: 2 })).toBe("C");
  });

  it("needs the median Mana at or under the baseline for B, and Age IV for S", () => {
    const b = { ...base, xp: 4500, accepted: 35, firstTryRate: 0.65, ritesPassed: 2 };
    expect(computeRank(econ, { ...b, medianManaRatio: 1.1 })).toBe("C");
    expect(computeRank(econ, { ...b, medianManaRatio: null })).toBe("C");
    expect(computeRank(econ, { ...b, medianManaRatio: 1 })).toBe("B");
    const s = { ...b, xp: 22_000, accepted: 120, firstTryRate: 0.8, partyTasks: 5, medianManaRatio: 0.8 };
    expect(computeRank(econ, { ...s, townAge: 3 })).toBe("A");
    expect(computeRank(econ, { ...s, townAge: 4 })).toBe("S");
  });

  it("compares ranks in order", () => {
    expect(rankAtLeast(econ, "E", "E")).toBe(true);
    expect(rankAtLeast(econ, "D", "E")).toBe(true);
    expect(rankAtLeast(econ, "F", "E")).toBe(false);
    expect(rankAtLeast(econ, "Z", "F")).toBe(false);
  });

  it("computes medians", () => {
    expect(median([])).toBeNull();
    expect(median([3, 1, 2])).toBe(2);
    expect(median([4, 1, 2, 3])).toBe(2.5);
  });
});
