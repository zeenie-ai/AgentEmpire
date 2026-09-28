import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { makeRepo } from "../helpers/git.js";
import { summonAgent, TestTown, type TestClient } from "../helpers/harness.js";

describe("incidents and zero-reward rules", () => {
  let town: TestTown;
  let c: TestClient;
  let agentId: string;

  beforeEach(async () => {
    town = await TestTown.start("incidents");
    c = await town.client();
    agentId = await summonAgent(c, { workspace: makeRepo(town.work, "app") });
  });

  afterEach(async () => {
    await c.close();
    await town.stop();
  });

  const assign = async (prompt: string, title = "Task", size = "S") =>
    (await c.ok("assign_task", { agent_id: agentId, title, prompt, size, courier: { mode: "express" } })).task_id as string;

  it("rings the alarm bell after the stuck time for the size and pauses after stall_pause_minutes", async () => {
    const inc = town.ctx.econ.data.incidents;
    const taskId = await assign("[fake:hang] Think forever");
    await c.waitTask(taskId, "running");
    await c.waitEvent((e) => e.type === "task_activity" && e.payload.task_id === taskId);
    town.clock.advance(inc.stuck_minutes_by_size.S * 60_000 - 1_000);
    expect(c.events.some((e) => e.type === "incident_opened" && e.payload.incident.kind === "alarm_bell")).toBe(false);
    town.clock.advance(1_000);
    const alarm = await c.waitEvent((e) => e.type === "incident_opened" && e.payload.incident.kind === "alarm_bell");
    expect(alarm.payload.incident.subject.task_id).toBe(taskId);
    town.clock.advance((inc.stall_pause_minutes - inc.stuck_minutes_by_size.S) * 60_000);
    const paused = await c.waitTask(taskId, "paused");
    expect(paused.payload.task.state_reason).toBe("stalled");

    const mark = c.lastSeq();
    await c.ok("resume_task", { task_id: taskId });
    await c.waitEvent((e) => e.type === "incident_resolved" && e.payload.incident_id === alarm.payload.incident.id);
    await c.waitEvent((e) => e.seq > mark && e.type === "task_updated" && e.payload.task.id === taskId && e.payload.task.state === "running");
    await c.ok("cancel_task", { task_id: taskId });
    await c.waitTask(taskId, "cancelled");
  });

  it("opens a rift for a transient crash, retries once after 30 s, then shows smoke", async () => {
    const taskId = await assign("[fake:crash] Fall over");
    const failed = await c.waitTask(taskId, "failed");
    expect(failed.payload.task.state_reason).toBe("PROVIDER_UNAVAILABLE");
    const rift = await c.waitEvent((e) => e.type === "incident_opened" && e.payload.incident.kind === "rift");
    expect(rift.payload.incident.subject.task_id).toBe(taskId);

    const mark = c.lastSeq();
    town.clock.advance(town.ctx.econ.data.incidents.rift_auto_retry_after_s * 1000);
    await c.waitEvent((e) => e.seq > mark && e.type === "task_updated" && e.payload.task.id === taskId && e.payload.task.state === "running");
    const smoke = await c.waitEvent((e) => e.type === "incident_opened" && e.payload.incident.kind === "smoke");
    expect(smoke.payload.incident.subject.task_id).toBe(taskId);
    await c.waitEvent((e) => e.type === "incident_resolved" && e.payload.incident_id === rift.payload.incident.id);
    expect(town.ctx.tasks.row(taskId).state).toBe("failed");
    expect(town.ctx.agents.get(agentId).stats.failed).toBe(1);

    await c.ok("cancel_task", { task_id: taskId });
    await c.waitEvent((e) => e.type === "incident_resolved" && e.payload.incident_id === smoke.payload.incident.id);
  });

  it("pays nothing for a result without a deliverable", async () => {
    const taskId = await assign("[fake:talk_only] Just think", "Think", "M");
    await c.waitEvent((e) => e.type === "task_activity" && e.payload.task_id === taskId && e.payload.entry.text.includes("long think"));
    await c.waitEvent((e) => e.type === "task_updated" && e.payload.task.id === taskId && e.payload.task.state === "running");
    await new Promise((r) => setTimeout(r, 50));
    town.clock.advance(31_000);
    const review = await c.waitTask(taskId, "awaiting_review");
    expect(review.payload.task.result.deliverable).toBe(false);
    const accepted = await c.ok("accept_result", { task_id: taskId, integrate: "keep_branch" });
    expect(accepted.rewards.rp).toBe(0);
    expect(accepted.rewards.breakdown.zero_reason).toBe("no_deliverable");
  });

  it("pays nothing for the same task repeated within 24 h", async () => {
    const run = async () => {
      const taskId = await assign("[fake:long] Write the long note", "Long note", "S");
      await c.waitEvent((e) => e.type === "task_activity" && e.payload.task_id === taskId && e.payload.entry.text.includes("long think"));
      await new Promise((r) => setTimeout(r, 50));
      town.clock.advance(31_000);
      await c.waitTask(taskId, "awaiting_review");
      return (await c.ok("accept_result", { task_id: taskId, integrate: "keep_branch" })).rewards;
    };
    const first = await run();
    expect(first.rp).toBeGreaterThan(0);
    const second = await run();
    expect(second.rp).toBe(0);
    expect(second.breakdown.zero_reason).toBe("duplicate");
    town.clock.advance(25 * 3600 * 1000);
    const third = await run();
    expect(third.rp).toBeGreaterThan(0);
  });
});
