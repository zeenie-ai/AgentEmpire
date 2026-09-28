import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { makeRepo } from "../helpers/git.js";
import { summonAgent, TestTown, type TestClient } from "../helpers/harness.js";

describe("couriers", () => {
  let town: TestTown;
  let c: TestClient;
  let agentId: string;

  beforeAll(async () => {
    town = await TestTown.start("courier");
    c = await town.client();
    agentId = await summonAgent(c, { workspace: makeRepo(town.work, "app") });
  });

  afterAll(async () => {
    await c.close();
    await town.stop();
  });

  it("delivers the scroll itself after couriers.force_deliver_after_s", async () => {
    const forceMs = town.ctx.econ.data.couriers.force_deliver_after_s * 1000;
    const { task_id: taskId } = await c.ok("assign_task", {
      agent_id: agentId,
      title: "Write a note",
      prompt: "[fake:basic] Write a note",
      size: "S",
      courier: { mode: "human", human_id: "h7" },
    });
    await c.waitTask(taskId, "in_transit");
    town.clock.advance(forceMs - 1_000);
    expect(town.ctx.tasks.row(taskId).state).toBe("in_transit");
    town.clock.advance(1_000);
    await c.waitTask(taskId, "queued");
    await c.waitTask(taskId, "awaiting_review");
    expect(town.ctx.tasks.row(taskId).delivered_at).not.toBeNull();
  });

  it("starts express tasks queued, and task_delivered on a delivered task is harmless", async () => {
    const { task_id: taskId } = await c.ok("assign_task", {
      agent_id: agentId,
      title: "Write another note",
      prompt: "[fake:basic] Write another note",
      size: "S",
      courier: { mode: "express" },
    });
    const first = await c.waitEvent((e) => e.type === "task_updated" && e.payload.task.id === taskId);
    expect(first.payload.task.state).toBe("queued");
    await c.ok("task_delivered", { task_id: taskId });
    await c.waitTask(taskId, "awaiting_review");
  });

  it("limits each home's queue by age", async () => {
    const limit = town.ctx.econ.queueLimit(1);
    const ids: string[] = [];
    for (let i = 0; i < limit; i++) {
      const r = await c.ok("assign_task", {
        agent_id: agentId,
        title: `Waiting ${i}`,
        prompt: "[fake:basic] wait",
        size: "S",
        courier: { mode: "human" },
      });
      ids.push(r.task_id);
    }
    const over = await c.send("assign_task", {
      agent_id: agentId,
      title: "One too many",
      prompt: "[fake:basic] wait",
      size: "S",
      courier: { mode: "human" },
    });
    expect(over.error?.code).toBe("LIMIT_REACHED");
    for (const id of ids) await c.ok("cancel_task", { task_id: id });
  });
});
