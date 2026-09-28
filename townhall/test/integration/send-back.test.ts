import { readFileSync } from "node:fs";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { makeRepo } from "../helpers/git.js";
import { summonAgent, TestTown, type TestClient } from "../helpers/harness.js";

describe("send back", () => {
  let town: TestTown;
  let c: TestClient;
  let agentId: string;

  beforeAll(async () => {
    town = await TestTown.start("sendback");
    c = await town.client();
    agentId = await summonAgent(c, { workspace: makeRepo(town.work, "app") });
  });

  afterAll(async () => {
    await c.close();
    await town.stop();
  });

  it("starts a new attempt that resumes the same session with the feedback", async () => {
    const { task_id: taskId } = await c.ok("assign_task", {
      agent_id: agentId,
      title: "Greet",
      prompt: "[fake:full_loop] Greet",
      size: "M",
      courier: { mode: "express" },
    });
    const req = await c.waitEvent((e) => e.type === "approval_requested" && e.payload.approval.task_id === taskId);
    town.clock.advance(31_000);
    // Scope "task" remembers the answer for the rest of this task.
    await c.ok("respond_approval", { approval_id: req.payload.approval.id, decision: "allow", scope: "task" });
    const first = await c.waitTask(taskId, "awaiting_review");
    expect(first.payload.task.attempt).toBe(1);
    const sessionBefore = town.ctx.tasks.row(taskId).session_id;
    expect(sessionBefore).toBe(`fake-${taskId}`);

    await c.ok("send_back", { task_id: taskId, feedback: "Please mention the harbour too." });
    const requeued = await c.waitEvent(
      (e) => e.type === "task_updated" && e.payload.task.id === taskId && e.payload.task.attempt === 2 && e.payload.task.state === "queued",
    );
    expect(requeued.payload.task.result).toBeNull();
    const second = await c.waitEvent(
      (e) => e.type === "task_updated" && e.payload.task.id === taskId && e.payload.task.attempt === 2 && e.payload.task.state === "awaiting_review",
    );
    expect(second.payload.task.spent_micros).toBe(700_000);
    expect(town.ctx.tasks.row(taskId).session_id).toBe(sessionBefore);
    const ws = JSON.parse(town.ctx.tasks.row(taskId).workspace_json!);
    expect(readFileSync(path.join(ws.worktree, "src", "greeting.txt"), "utf8")).toContain("Please mention the harbour too.");
    await c.waitEvent((e) => e.type === "task_activity" && e.payload.entry.text.includes("Resuming with feedback"));

    const accepted = await c.ok("accept_result", { task_id: taskId, integrate: "keep_branch" });
    expect(accepted.rewards.breakdown.q).toBe(0.2);
    const agent = (await c.ok("get_state")).agents.find((a: { id: string }) => a.id === agentId);
    expect(agent.stats.sent_back).toBe(1);
    expect(agent.stats.accepted_first_try).toBe(0);
  });

  it("pays nothing for an abandoned result, and discarding keeps an archive ref", async () => {
    const { task_id: taskId } = await c.ok("assign_task", {
      agent_id: agentId,
      title: "Throwaway",
      prompt: "[fake:basic] Throwaway",
      size: "S",
      courier: { mode: "express" },
    });
    await c.waitTask(taskId, "awaiting_review");
    const treasury = (await c.ok("get_state")).treasury;
    await c.ok("abandon_task", { task_id: taskId });
    await c.waitTask(taskId, "rejected");
    expect((await c.ok("get_state")).treasury).toEqual(treasury);
    const noConfirm = await c.send("discard_workspace", { task_id: taskId });
    expect(noConfirm.error?.code).toBe("BAD_REQUEST");
    await c.ok("discard_workspace", { task_id: taskId, confirm: true });
    const ws = JSON.parse(town.ctx.tasks.row(taskId).workspace_json!);
    expect(ws.archived_ref).toBe(`refs/aurelhaven/archive/${taskId}`);
    expect(ws.removed).toBe(true);
  });
});
