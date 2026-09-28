import fc from "fast-check";
import { describe, expect, it } from "vitest";
import { computeBounty, splitPartyXp, splitReward, zeroRewards, type BountyInput } from "../../src/core/bounty.js";
import { Economy } from "../../src/core/economy.js";
import { defaultEconomyPath } from "../../src/paths.js";

const econ = Economy.load(defaultEconomyPath());

const workedExample: BountyInput = {
  size: "M",
  attempt: 1,
  manaUsed: 60,
  baselineMana: 80,
  hasArchive: true,
  hasRecommendedTools: true,
  ritePassed: true,
  rewardedTodaySameSize: 0,
};

describe("bounty", () => {
  it("pays 180 x 1.95 = 351 RP for the worked example", () => {
    const { rp, breakdown } = computeBounty(econ, workedExample);
    expect(rp).toBe(351);
    expect(breakdown).toEqual({ base: 180, q: 0.5, e: 0.15, p: 0.3, d: 1, ceiling: 1200 });
  });

  it("splits the Artificer's 351 RP by reward_split so the parts add up exactly", () => {
    const parts = splitReward(351, econ.data.roles.artificer!.reward_split);
    expect(parts).toEqual({ gold: 123, stone: 123, wood: 53, food: 52 });
    expect(parts.food + parts.wood + parts.stone + parts.gold).toBe(351);
  });

  it("reads Q from the attempt number", () => {
    expect(computeBounty(econ, { ...workedExample, attempt: 2 }).breakdown.q).toBe(0.2);
    expect(computeBounty(econ, { ...workedExample, attempt: 3 }).breakdown.q).toBe(0);
    expect(computeBounty(econ, { ...workedExample, attempt: 9 }).breakdown.q).toBe(0);
  });

  it("clamps E between 0 and weight x max_ratio", () => {
    expect(computeBounty(econ, { ...workedExample, manaUsed: 0.5 }).breakdown.e).toBe(0.3);
    expect(computeBounty(econ, { ...workedExample, manaUsed: 200 }).breakdown.e).toBe(0);
    expect(computeBounty(econ, { ...workedExample, manaUsed: 80 }).breakdown.e).toBe(0);
  });

  it("adds P only for Archive, recommended tools and a passed Rite", () => {
    expect(computeBounty(econ, { ...workedExample, hasArchive: false }).breakdown.p).toBe(0.2);
    expect(computeBounty(econ, { ...workedExample, hasArchive: false, hasRecommendedTools: false, ritePassed: false }).breakdown.p).toBe(0);
  });

  it("halves the reward after the daily count for the size", () => {
    const full = econ.data.bounty.daily_full_count.M;
    expect(computeBounty(econ, { ...workedExample, rewardedTodaySameSize: full - 1 }).breakdown.d).toBe(1);
    const halved = computeBounty(econ, { ...workedExample, rewardedTodaySameSize: full });
    expect(halved.breakdown.d).toBe(0.5);
    expect(halved.rp).toBe(Math.round(351 / 2));
  });

  it("caps the reward at max(60, 20 x Mana used) so over-labelled cheap tasks pay little", () => {
    const cheapXL = computeBounty(econ, { ...workedExample, size: "XL", manaUsed: 1, baselineMana: 700 });
    expect(cheapXL.breakdown.ceiling).toBe(60);
    expect(cheapXL.rp).toBe(60);
    const cheapM = computeBounty(econ, { ...workedExample, manaUsed: 5 });
    expect(cheapM.rp).toBe(100);
  });

  it("never pays negative RP and never exceeds the ceiling", () => {
    fc.assert(
      fc.property(
        fc.constantFrom("S", "M", "L", "XL" as const),
        fc.integer({ min: 1, max: 10 }),
        fc.double({ min: 0, max: 5000, noNaN: true }),
        fc.double({ min: 0.01, max: 5000, noNaN: true }),
        fc.boolean(),
        fc.boolean(),
        fc.boolean(),
        fc.integer({ min: 0, max: 30 }),
        (size, attempt, manaUsed, baselineMana, a, r, rite, today) => {
          const { rp, breakdown } = computeBounty(econ, {
            size,
            attempt,
            manaUsed,
            baselineMana,
            hasArchive: a,
            hasRecommendedTools: r,
            ritePassed: rite,
            rewardedTodaySameSize: today,
          });
          return rp >= 0 && rp <= Math.round(breakdown.ceiling) + 1 && Number.isInteger(rp);
        },
      ),
    );
  });

  it("splits any RP into parts that add up exactly for every role", () => {
    fc.assert(
      fc.property(fc.constantFrom(...Object.keys(econ.data.roles)), fc.integer({ min: 0, max: 100_000 }), (role, rp) => {
        const split = econ.data.roles[role]!.reward_split;
        const parts = splitReward(rp, split);
        const sum = parts.food + parts.wood + parts.stone + parts.gold;
        const close = Object.entries(split).every(([k, w]) => Math.abs(parts[k as keyof typeof parts] - rp * w) < 1);
        return sum === rp && close;
      }),
    );
  });

  it("splits party XP 40/60 and loses nothing", () => {
    expect(splitPartyXp(280, 0.4, 1)).toEqual({ lead: 112, members: [168] });
    expect(splitPartyXp(100, 0.4, 0)).toEqual({ lead: 100, members: [] });
    fc.assert(
      fc.property(fc.integer({ min: 0, max: 50_000 }), fc.integer({ min: 0, max: 6 }), (xp, n) => {
        const s = splitPartyXp(xp, econ.data.bounty.party_split.lead, n);
        return s.lead + s.members.reduce((a, b) => a + b, 0) === xp;
      }),
    );
  });

  it("describes zero rewards with a reason", () => {
    const z = zeroRewards(econ, "M", "duplicate");
    expect(z.rp).toBe(0);
    expect(z.resources).toEqual({ food: 0, wood: 0, stone: 0, gold: 0 });
    expect(z.breakdown.zero_reason).toBe("duplicate");
  });
});
