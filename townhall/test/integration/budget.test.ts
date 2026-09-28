import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { makeRepo } from "../helpers/git.js";
import { summonAgent, TestTown, type Ev, type TestClient } from "../helpers/harness.js";

function assertInvariant(events: Ev[]): void {
  for (const e of events) {
    if (e.type !== "mana_updated") continue;
    const m = e.payload.mana;
    expect(m.spent_micros + m.reserved_micros).toBeLessThanOrEqual(m.cap_micros);
  }
}

describe("Mana budget", () => {
  let town: TestTown;
  let c: TestClient;
  let agentId: string;

  beforeEach(async () => {
    town = await TestTown.start("budget");
    c = await town.client();
    agentId = await summonAgent(c, { workspace: makeRepo(town.work, "app") });
  });

  afterEach(async () => {
    await c.close();
    await town.stop();
  });

  it("interrupts a run at 100% of its seal, then resumes after an extension", async () => {
    const { task_id: taskId } = await c.ok("assign_task", {
      agent_id: agentId,
      title: "Burn the seal",
      prompt: "[fake:seal_burn] Burn",
      size: "S",
      seal_mana: 10,
      courier: { mode: "express" },
    });
    const paused = await c.waitTask(taskId, "paused");
    expect(paused.payload.task.state_reason).toBe("budget");
    expect(paused.payload.task.spent_micros).toBe(120_000);
    expect(paused.payload.task.reserved_micros).toBe(0);
    await c.waitEvent((e) => e.type === "task_activity" && e.payload.task_id === taskId && e.payload.entry.text.includes("80%"));
    await c.waitEvent((e) => e.type === "incident_opened" && e.payload.incident.kind === "hand_bell");

    // Controls stay free: resuming without an extension is refused only because the seal is spent.
    const refused = await c.send("resume_task", { task_id: taskId });
    expect(refused.error?.code).toBe("INSUFFICIENT_MANA");

    await c.ok("resume_task", { task_id: taskId, extend_seal_mana: 5 });
    const review = await c.waitTask(taskId, "awaiting_review");
    expect(review.payload.task.seal_micros).toBe(150_000);
    expect(review.payload.task.spent_micros).toBe(130_000);
    await c.waitEvent((e) => e.type === "incident_resolved");
    assertInvariant(c.events);
  });

  it("offers stop-and-review for a budget-paused task", async () => {
    const { task_id: taskId } = await c.ok("assign_task", {
      agent_id: agentId,
      title: "Burn and stop",
      prompt: "[fake:seal_burn] Burn and stop",
      size: "S",
      seal_mana: 10,
      courier: { mode: "express" },
    });
    await c.waitTask(taskId, "paused");
    await c.ok("stop_and_review", { task_id: taskId });
    const review = await c.waitTask(taskId, "awaiting_review");
    expect(review.payload.task.result.diff_stat.files).toBe(1);
    expect(review.payload.task.result.summary).toMatch(/Stopped for review/);
  });

  it("turns the lights out at the pool's last 2% and recovers when the pool is raised", async () => {
    const lowered = await c.ok("set_budget", { period: "day", pool_usd: 1, billing: { claude: "subscription", codex: "subscription" } });
    expect(lowered.mana.cap_micros).toBe(1_000_000);

    const { task_id: taskId } = await c.ok("assign_task", {
      agent_id: agentId,
      title: "Drain the pool",
      prompt: "[fake:pool_burn] Drain",
      size: "M",
      courier: { mode: "express" },
    });
    const paused = await c.waitTask(taskId, "paused");
    expect(paused.payload.task.state_reason).toBe("mana_depleted");
    await c.waitEvent((e) => e.type === "incident_opened" && e.payload.incident.kind === "font_dark");
    await c.waitEvent((e) => e.type === "incident_opened" && e.payload.incident.kind === "dim_lanterns");
    const mana = (await c.ok("get_state")).mana;
    expect(mana.level).toBe("depleted");
    expect(mana.spent_micros).toBe(990_000);
    expect(mana.estimates).toBe(true);

    // Nothing new starts while the Font is dark.
    const { task_id: waiting } = await c.ok("assign_task", {
      agent_id: agentId,
      title: "Wait for Mana",
      prompt: "[fake:basic] Wait",
      size: "S",
      courier: { mode: "express" },
    });
    await c.waitEvent((e) => e.type === "agent_updated" && e.payload.agent.blocked_reason === "no_mana");
    expect(town.ctx.tasks.row(waiting).state).toBe("queued");

    // Raising the pool mid-period needs confirm_raise.
    const refused = await c.send("set_budget", { period: "day", pool_usd: 5, billing: { claude: "subscription", codex: "subscription" } });
    expect(refused.error?.code).toBe("CONFLICT");
    await c.ok("set_budget", {
      period: "day",
      pool_usd: 5,
      billing: { claude: "subscription", codex: "subscription" },
      confirm_raise: true,
    });
    await c.waitEvent((e) => e.type === "incident_resolved");
    await c.waitTask(taskId, "running", 20_000);
    expect(town.ctx.tasks.row(taskId).state_reason).toBeNull();
    await c.ok("cancel_task", { task_id: taskId });
    await c.waitTask(taskId, "cancelled");
    await c.waitTask(waiting, "awaiting_review", 20_000);
    assertInvariant(c.events);
  });

  it("carries an overshoot into the next period as overdraft", async () => {
    await c.ok("set_budget", { period: "day", pool_usd: 1, billing: { claude: "api_key", codex: "api_key" } });
    const { task_id: taskId } = await c.ok("assign_task", {
      agent_id: agentId,
      title: "Overshoot",
      prompt: "[fake:pool_burn] Overshoot",
      size: "S",
      seal_mana: 200,
      courier: { mode: "express" },
    });
    await c.waitTask(taskId, "paused");
    const period = town.ctx.mana.current();
    // The task could reserve at most the free pool (100 Mana); 99 was used, so no overshoot yet.
    expect(period.spent_micros + town.ctx.mana.reservedTotal()).toBeLessThanOrEqual(period.cap_micros);
    // Charge beyond the cap directly, as a late usage report would.
    town.ctx.mana.charge(taskId, "claude", 50_000, false);
    const after = town.ctx.mana.current();
    expect(after.spent_micros).toBe(after.cap_micros);
    expect(after.overdraft_micros).toBe(40_000);
    town.clock.advance(Date.parse(after.period_end) - town.clock.now() + 1_000);
    const next = town.ctx.mana.current();
    expect(next.id).toBe(after.id + 1);
    expect(next.carried_in_micros).toBe(40_000);
    expect(next.cap_micros).toBe(1_000_000 - 40_000);
    expect(next.spent_micros).toBe(0);
  });
});
