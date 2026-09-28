import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { makeRepo } from "../helpers/git.js";
import { summonAgent, TestTown, type TestClient } from "../helpers/harness.js";

describe("restart recovery", () => {
  let town: TestTown;
  let c: TestClient;
  let agentId: string;

  beforeAll(async () => {
    town = await TestTown.start("restart");
    c = await town.client();
    agentId = await summonAgent(c, { workspace: makeRepo(town.work, "app") });
  });

  afterAll(async () => {
    await town.stop();
  });

  it("orphans a pending approval, and answering it resumes the session with a pre-approval", async () => {
    const { task_id: taskId } = await c.ok("assign_task", {
      agent_id: agentId,
      title: "Greet",
      prompt: "[fake:full_loop] Greet the town",
      size: "M",
      courier: { mode: "express" },
    });
    const requested = await c.waitEvent((e) => e.type === "approval_requested" && e.payload.approval.task_id === taskId);
    const approvalId: string = requested.payload.approval.id;
    await c.waitTask(taskId, "awaiting_approval");
    const spentBefore = town.ctx.tasks.row(taskId).spent_micros;
    expect(spentBefore).toBe(300_000);

    await c.close();
    await town.restart();

    const c2 = await town.client();
    const state = await c2.ok("get_state");
    const task = state.tasks.find((t: { id: string }) => t.id === taskId);
    expect(task.state).toBe("paused");
    expect(task.state_reason).toBe("restart");
    expect(task.reserved_micros).toBe(0);
    const orphan = state.approvals.find((a: { id: string }) => a.id === approvalId);
    expect(orphan.status).toBe("orphaned");
    expect(state.incidents.some((i: { kind: string }) => i.kind === "hand_bell")).toBe(true);

    town.clock.advance(31_000);
    await c2.ok("respond_approval", { approval_id: approvalId, decision: "allow", scope: "once" });
    const resolved = await c2.waitEvent((e) => e.type === "approval_resolved" && e.payload.approval_id === approvalId);
    expect(resolved.payload.by).toBe("player");

    // The resumed session re-issues the same call; the single-use pre-approval answers it.
    const pre = await c2.waitEvent((e) => e.type === "approval_resolved" && e.payload.by === "pre_approval", 20_000, "pre-approval");
    expect(pre.payload.decision).toBe("allow");
    const review = await c2.waitTask(taskId, "awaiting_review", 30_000);
    expect(review.payload.task.attempt).toBe(1);
    // Usage before the restart is not charged twice.
    expect(review.payload.task.spent_micros).toBe(600_000);
    expect(c2.events.filter((e) => e.type === "approval_requested" && e.payload.approval.status === "pending")).toHaveLength(0);
    const used = town.ctx.db.get<{ uses_left: number }>("SELECT uses_left FROM approval_rules WHERE kind = 'pre_approval'");
    expect(used?.uses_left).toBe(0);
    await c2.close();
  });

  it("resumes an interrupted run on its own when no approval was waiting", async () => {
    const c3 = await town.client();
    const { task_id: taskId } = await c3.ok("assign_task", {
      agent_id: agentId,
      title: "Think",
      prompt: "[fake:nudge] Think about it",
      size: "S",
      courier: { mode: "express" },
    });
    await c3.waitTask(taskId, "running");
    const seen = c3.lastSeq();
    await c3.close();
    await town.restart();
    // Recovery runs during startup, so ask for a replay of everything since the last event seen.
    const c4 = await town.client({ last_seq: seen });
    const paused = await c4.waitTask(taskId, "paused");
    expect(paused.payload.task.state_reason).toBe("restart");
    await c4.waitTask(taskId, "running", 20_000);
    expect(town.ctx.tasks.row(taskId).state_reason).toBeNull();
    await c4.ok("nudge_task", { task_id: taskId, message: "Here is your hint." });
    await c4.waitTask(taskId, "awaiting_review");
    await c4.close();
  });
});
