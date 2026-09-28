import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { makeRepo } from "../helpers/git.js";
import { summonAgent, TestTown, type TestClient } from "../helpers/harness.js";

describe("approval modes, scopes and rules", () => {
  let town: TestTown;
  let c: TestClient;
  let agentId: string;

  beforeAll(async () => {
    town = await TestTown.start("approvals");
    c = await town.client();
    agentId = await summonAgent(c, { workspace: makeRepo(town.work, "app"), approval_mode: "ask_every_time" });
  });

  afterAll(async () => {
    await c.close();
    await town.stop();
  });

  const assign = async (prompt: string, size = "S") =>
    (await c.ok("assign_task", { agent_id: agentId, title: prompt, prompt, size, courier: { mode: "express" } })).task_id as string;

  it("asks for every write in ask_every_time mode; an agent-scope answer becomes a rule", async () => {
    const first = await assign("[fake:basic] Note one");
    const req = await c.waitEvent((e) => e.type === "approval_requested" && e.payload.approval.task_id === first);
    expect(req.payload.approval.category).toBe("write");
    expect(req.payload.approval.scopes).toEqual(["once", "task", "agent"]);
    await c.ok("respond_approval", { approval_id: req.payload.approval.id, decision: "allow", scope: "agent" });
    await c.waitTask(first, "awaiting_review");
    const rules = town.ctx.db.all<{ kind: string; tool: string }>("SELECT kind, tool FROM approval_rules");
    expect(rules).toEqual([{ kind: "agent", tool: "Write" }]);

    const second = await assign("[fake:basic] Note two");
    const byRule = await c.waitEvent((e) => e.type === "approval_resolved" && e.payload.by === "rule");
    expect(byRule.payload.decision).toBe("allow");
    await c.waitTask(second, "awaiting_review");
    expect(c.events.some((e) => e.type === "approval_requested" && e.payload.approval.task_id === second)).toBe(false);
  });

  it("runs the onDeny branch when the player denies, and the first reply wins", async () => {
    const taskId = await assign("[fake:full_loop] Greet", "M");
    const req = await c.waitEvent(
      (e) => e.type === "approval_requested" && e.payload.approval.task_id === taskId && e.payload.approval.tool === "Bash",
    );
    await c.ok("respond_approval", { approval_id: req.payload.approval.id, decision: "deny", scope: "once", message: "Not now" });
    const late = await c.send("respond_approval", { approval_id: req.payload.approval.id, decision: "allow", scope: "once" });
    expect(late.ok).toBe(true);
    await c.waitEvent((e) => e.type === "task_activity" && e.payload.task_id === taskId && e.payload.entry.text.includes("Skipping the tests"));
    await c.waitTask(taskId, "awaiting_review");
    const resolutions = c.events.filter((e) => e.type === "approval_resolved" && e.payload.approval_id === req.payload.approval.id);
    expect(resolutions).toHaveLength(1);
    expect(resolutions[0]!.payload.decision).toBe("deny");
  });

  it("refuses scopes that are not offered", async () => {
    const taskId = await assign("[fake:full_loop] Greet again", "M");
    const req = await c.waitEvent(
      (e) => e.type === "approval_requested" && e.payload.approval.task_id === taskId && e.payload.approval.tool === "Bash",
    );
    const bogus = await c.send("respond_approval", { approval_id: req.payload.approval.id, decision: "allow", scope: "forever" });
    expect(bogus.error?.code).toBe("BAD_REQUEST");
    await c.ok("cancel_task", { task_id: taskId });
    const cancelled = await c.waitEvent((e) => e.type === "approval_resolved" && e.payload.approval_id === req.payload.approval.id);
    expect(cancelled.payload.by).toBe("cancelled");
    await c.waitTask(taskId, "cancelled");
  });

  it("waits for a client before starting work when work_while_away is off", async () => {
    await c.ok("set_setting", { key: "work_while_away", value: false });
    const seen = c.lastSeq();
    await c.close();
    const { task_id: taskId } = town.ctx.tasks.assign({
      agent_id: agentId,
      title: "While away",
      prompt: "[fake:long] While away",
      size: "S",
      courier: { mode: "express" },
    });
    await new Promise((r) => setTimeout(r, 200));
    expect(town.ctx.tasks.row(taskId).state).toBe("queued");
    c = await town.client({ last_seq: seen });
    await c.waitTask(taskId, "running");
    await c.ok("set_setting", { key: "work_while_away", value: true });
    await c.ok("cancel_task", { task_id: taskId });
  });
});
