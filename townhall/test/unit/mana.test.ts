import fc from "fast-check";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Economy } from "../../src/core/economy.js";
import { levelFor, periodBounds } from "../../src/core/mana.js";
import { defaultEconomyPath } from "../../src/paths.js";
import { TestTown } from "../helpers/harness.js";

const econ = Economy.load(defaultEconomyPath());
const stages = econ.data.mana.stages;
const lightsOut = econ.data.mana.lights_out_fraction;

describe("Mana periods", () => {
  it("starts a day at the refill hour", () => {
    const now = new Date(2026, 8, 28, 10, 30).getTime();
    const b = periodBounds("day", 0, now);
    expect(b.start).toBe(new Date(2026, 8, 28, 0, 0).getTime());
    expect(b.end).toBe(new Date(2026, 8, 29, 0, 0).getTime());
    const early = periodBounds("day", 6, new Date(2026, 8, 28, 3, 0).getTime());
    expect(early.start).toBe(new Date(2026, 8, 27, 6, 0).getTime());
    expect(early.end).toBe(new Date(2026, 8, 28, 6, 0).getTime());
  });

  it("starts a week on Monday and a month on the 1st", () => {
    const now = new Date(2026, 9, 1, 12, 0).getTime();
    const week = periodBounds("week", 0, now);
    expect(new Date(week.start).getDay()).toBe(1);
    const month = periodBounds("month", 5, now);
    expect(month.start).toBe(new Date(2026, 9, 1, 5, 0).getTime());
    expect(month.end).toBe(new Date(2026, 10, 1, 5, 0).getTime());
    const beforeRefill = periodBounds("month", 5, new Date(2026, 9, 1, 4, 0).getTime());
    expect(beforeRefill.start).toBe(new Date(2026, 8, 1, 5, 0).getTime());
  });

  it("always contains now", () => {
    fc.assert(
      fc.property(
        fc.constantFrom("day", "week", "month" as const),
        fc.integer({ min: 0, max: 23 }),
        fc.integer({ min: Date.UTC(2020, 0, 1), max: Date.UTC(2035, 0, 1) }),
        (kind, hour, now) => {
          const b = periodBounds(kind, hour, now);
          return b.start <= now && now < b.end;
        },
      ),
    );
  });
});

describe("Mana levels", () => {
  it("dims at 25%, warns at 10% and goes dark at the last 2%", () => {
    const cap = 1_000_000;
    expect(levelFor(cap, 0, stages, lightsOut)).toBe("normal");
    expect(levelFor(cap, 740_000, stages, lightsOut)).toBe("normal");
    expect(levelFor(cap, 750_000, stages, lightsOut)).toBe("dim");
    expect(levelFor(cap, 900_000, stages, lightsOut)).toBe("warning");
    expect(levelFor(cap, 979_000, stages, lightsOut)).toBe("warning");
    expect(levelFor(cap, 980_000, stages, lightsOut)).toBe("depleted");
    expect(levelFor(0, 0, stages, lightsOut)).toBe("depleted");
  });
});

describe("Mana accounting against the real service", () => {
  let town: TestTown;

  beforeAll(async () => {
    town = await TestTown.start("mana");
    const ctx = town.ctx;
    ctx.db.tx(() => {
      ctx.db.run(
        `INSERT INTO agents (id, name, provider, model, role, instructions, approval_mode, workspace_path, workspace_mode, seals_json,
           billing, lifecycle, activity, stats_json, cost_json, starting_tools_json, created_at)
         VALUES ('agt_test', 'T', 'claude', 'm', 'artificer', '', 'trusted_edits', 'x', 'plain_folder', '{"S":40,"M":150,"L":450,"XL":1200}',
           'api_key', 'training', 'idle', '{}', '{}', '[]', ?)`,
        [ctx.clock.iso()],
      );
      for (let i = 0; i < 4; i++) {
        ctx.db.run(
          `INSERT INTO tasks (id, agent_id, title, prompt, prompt_hash, size, acceptance_json, state, seal_micros, courier_json, created_at, updated_at)
           VALUES (?, 'agt_test', 't', 'p', ?, 'M', '[]', 'running', ?, '{"mode":"express"}', ?, ?)`,
          [`tsk_m${i}`, `h${i}`, 1_500_000, ctx.clock.iso(), ctx.clock.iso()],
        );
      }
    });
  });

  afterAll(async () => {
    await town.stop();
  });

  const op = fc.oneof(
    fc.record({ kind: fc.constant("reserve" as const), task: fc.integer({ min: 0, max: 3 }) }),
    fc.record({ kind: fc.constant("charge" as const), task: fc.integer({ min: 0, max: 3 }), micros: fc.integer({ min: 0, max: 900_000 }) }),
    fc.record({ kind: fc.constant("release" as const), task: fc.integer({ min: 0, max: 3 }) }),
    fc.record({ kind: fc.constant("extend" as const), task: fc.integer({ min: 0, max: 3 }), mana: fc.integer({ min: 1, max: 100 }) }),
    fc.record({ kind: fc.constant("budget" as const), usd: fc.integer({ min: 0, max: 12 }) }),
  );

  it("keeps spent + reserved <= cap under any sequence of operations", () => {
    const ctx = town.ctx;
    fc.assert(
      fc.property(fc.array(op, { minLength: 1, maxLength: 40 }), (ops) => {
        for (const o of ops) {
          if (o.kind === "reserve") ctx.mana.reserve(`tsk_m${o.task}`);
          else if (o.kind === "charge") ctx.mana.charge(`tsk_m${o.task}`, "claude", o.micros, false);
          else if (o.kind === "release") ctx.mana.release(`tsk_m${o.task}`);
          else if (o.kind === "extend") ctx.mana.extendSeal(`tsk_m${o.task}`, o.mana);
          else ctx.mana.setBudget({ period: "day", pool_usd: o.usd, billing: { claude: "api_key", codex: "api_key" }, confirm_raise: true });
          const p = ctx.mana.current();
          const reserved = ctx.mana.reservedTotal();
          if (p.spent_micros + reserved > p.cap_micros) return false;
          if (p.spent_micros < 0 || reserved < 0) return false;
          const state = ctx.mana.state();
          if (state.remaining_micros !== Math.max(0, p.cap_micros - p.spent_micros - reserved)) return false;
        }
        return true;
      }),
      { numRuns: 60 },
    );
  });

  it("starts a task only with 25% of its seal and the minimum reservation free", () => {
    const ctx = town.ctx;
    for (let i = 0; i < 4; i++) ctx.mana.release(`tsk_m${i}`);
    ctx.mana.setBudget({ period: "day", pool_usd: 100, billing: { claude: "api_key", codex: "api_key" }, confirm_raise: true });
    const task = { seal_micros: 1_500_000, spent_micros: 0, reserved_micros: 0 };
    const p = ctx.mana.current();
    const free = p.cap_micros - p.spent_micros - ctx.mana.reservedTotal();
    expect(free).toBeGreaterThan(0);
    expect(ctx.mana.canStart({ ...task, seal_micros: free * 4 }).ok).toBe(true);
    expect(ctx.mana.canStart({ ...task, seal_micros: free * 4 + 8 }).ok).toBe(false);
    expect(ctx.mana.canStart({ seal_micros: 100, spent_micros: 100, reserved_micros: 0 }).ok).toBe(false);
  });

  it("requires confirm_raise to raise the pool mid-period", () => {
    const ctx = town.ctx;
    ctx.mana.charge("tsk_m0", "claude", 1, false);
    const cap = ctx.mana.current().cap_micros;
    expect(() =>
      ctx.mana.setBudget({ period: "day", pool_usd: cap / 1_000_000 + 1, billing: { claude: "api_key", codex: "api_key" } }),
    ).toThrow(/confirm_raise/);
    expect(() => ctx.mana.setBudget({ period: "day", pool_usd: 1, billing: { claude: "api_key", codex: "api_key" } })).not.toThrow();
  });
});
