import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { git, makeRepo, treeHashes } from "../helpers/git.js";
import { TestTown, type TestClient } from "../helpers/harness.js";

describe("the full loop: summon, build, task, approval, review, merge, reward", () => {
  let town: TestTown;
  let c: TestClient;
  let repo: string;

  beforeAll(async () => {
    town = await TestTown.start("loop");
    repo = makeRepo(town.work, "app");
    c = await town.client();
  });

  afterAll(async () => {
    await c.close();
    await town.stop();
  });

  it("runs a task end to end and pays the worked-example bounty", async () => {
    const before = (await c.ok("get_state")).treasury;
    expect(before).toEqual({ food: 200, wood: 200, stone: 150, gold: 100 });

    // Summon under Font's Grace: the first agent, its home and its required tools are free.
    const created = await c.ok("create_agent", {
      spec: {
        name: "Mira",
        provider: "claude",
        model: "fake-claude",
        role: "artificer",
        instructions: "Write small, careful changes.",
        approval_mode: "trusted_edits",
        workspace: { path: repo },
        starting_tools: ["lectern", "quillworks", "forge", "archive"],
      },
    });
    expect(created.free).toBe(true);
    expect(created.cost).toEqual({ food: 0, wood: 0, stone: 0, gold: 0 });
    expect(created.training.duration_ms).toBe(40_000);
    const agentId: string = created.agent_id;
    const training = await c.waitEvent((e) => e.type === "agent_updated" && e.payload.agent.id === agentId);
    expect(training.payload.agent.lifecycle).toBe("training");
    expect(training.payload.agent.workspace.mode).toBe("git_worktree");
    expect(training.payload.agent.billing).toMatch(/^(subscription|api_key)$/);

    await c.ok("agent_trained", { agent_id: agentId });
    await c.waitEvent((e) => e.type === "agent_updated" && e.payload.agent.id === agentId && e.payload.agent.lifecycle === "settling");
    const home = await c.ok("place_home", { agent_id: agentId, tile: { x: 40, y: 52 } });
    expect(home.cost).toEqual({ food: 0, wood: 0, stone: 0, gold: 0 });
    await c.ok("home_built", { agent_id: agentId });
    await c.waitEvent(
      (e) => e.type === "agent_updated" && e.payload.agent.id === agentId && e.payload.agent.blocked_reason === "missing_tools",
    );

    const costs: Record<string, unknown> = {};
    let i = 0;
    for (const type of ["lectern", "quillworks", "forge", "archive"]) {
      const t = await c.ok("attach_tool", { agent_id: agentId, type, tile: { x: 42 + i, y: 50 } });
      costs[type] = t.cost;
      await c.waitEvent((e) => e.type === "tool_updated" && e.payload.tool.id === t.tool_id && e.payload.tool.status === "building");
      await c.ok("tool_built", { tool_id: t.tool_id });
      i++;
    }
    expect(costs.lectern).toEqual({ food: 0, wood: 0, stone: 0, gold: 0 });
    expect(costs.quillworks).toEqual({ food: 0, wood: 0, stone: 0, gold: 0 });
    expect(costs.forge).toEqual({ food: 0, wood: 60, stone: 60, gold: 30 });
    expect(costs.archive).toEqual({ food: 0, wood: 60, stone: 20, gold: 0 });
    await c.waitEvent((e) => e.type === "agent_updated" && e.payload.agent.id === agentId && e.payload.agent.lifecycle === "active");

    const mainBefore = treeHashes(repo);
    const headBefore = git(repo, "rev-parse", "HEAD");

    const { task_id: taskId } = await c.ok("assign_task", {
      agent_id: agentId,
      title: "Add a greeting",
      prompt: "[fake:full_loop] Add a greeting file under src/",
      size: "M",
      acceptance: ["src/greeting.txt exists"],
      rite: 'node -e "process.exit(0)"',
      courier: { mode: "human", human_id: "h1" },
    });
    await c.waitTask(taskId, "in_transit");
    await c.ok("task_delivered", { task_id: taskId });
    await c.waitTask(taskId, "queued");

    const requested = await c.waitEvent((e) => e.type === "approval_requested" && e.payload.approval.task_id === taskId);
    const approval = requested.payload.approval;
    expect(approval.tool).toBe("Bash");
    expect(approval.category).toBe("command");
    expect(approval.status).toBe("pending");
    expect(approval.summary).toBe("Run: npm test");
    await c.waitTask(taskId, "awaiting_approval");
    await c.waitEvent((e) => e.type === "incident_opened" && e.payload.incident.kind === "hand_bell");

    // The agent already wrote its file, but only inside its own worktree.
    expect(treeHashes(repo)).toEqual(mainBefore);

    // Pending approvals never deny themselves: long waits are fine (and count towards min_run_s).
    town.clock.advance(31_000);
    await c.ok("respond_approval", { approval_id: approval.id, decision: "allow", scope: "once" });
    const resolved = await c.waitEvent((e) => e.type === "approval_resolved" && e.payload.approval_id === approval.id);
    expect(resolved.payload.by).toBe("player");

    const review = (await c.waitTask(taskId, "awaiting_review", 30_000)).payload.task;
    expect(review.result.deliverable).toBe(true);
    expect(review.result.diff_stat).toEqual({ files: 1, added: 1, removed: 0 });
    expect(review.result.rite.passed).toBe(true);
    expect(review.spent_micros).toBe(600_000);
    expect(review.attempt).toBe(1);
    expect(treeHashes(repo)).toEqual(mainBefore);
    expect(git(repo, "rev-parse", "HEAD")).toBe(headBefore);

    const detail = await c.ok("get_task_detail", { task_id: taskId, include: ["activity", "diff"] });
    expect(detail.diff.files).toEqual([{ path: "src/greeting.txt", status: "added", added: 1, removed: 0 }]);
    expect(detail.diff.patch).toContain("Hello from Aurelhaven.");
    expect(detail.activity.length).toBeGreaterThan(3);

    const accepted = await c.ok("accept_result", { task_id: taskId, integrate: "merge" });
    // Worked example: M, first try, 60 Mana against an 80 baseline, full practice bonus.
    expect(accepted.rewards.rp).toBe(351);
    expect(accepted.rewards.xp).toBe(351);
    expect(accepted.rewards.breakdown).toEqual({ base: 180, q: 0.5, e: 0.15, p: 0.3, d: 1, ceiling: 1200 });
    expect(accepted.rewards.resources).toEqual({ gold: 123, stone: 123, wood: 53, food: 52 });
    expect(accepted.merge.commit).toMatch(/^[0-9a-f]{40}$/);

    // The main checkout changed only now, through a --no-ff merge.
    expect(readFileSync(path.join(repo, "src", "greeting.txt"), "utf8")).toBe("Hello from Aurelhaven.\n");
    expect(git(repo, "rev-parse", "HEAD")).toBe(accepted.merge.commit);
    expect(git(repo, "rev-list", "--parents", "-n", "1", "HEAD").split(" ")).toHaveLength(3);
    expect(git(repo, "status", "--porcelain")).toBe("");

    const done = await c.waitTask(taskId, "accepted");
    expect(done.payload.task.rewards.rp).toBe(351);
    const reward = await c.waitEvent((e) => e.type === "treasury_updated" && e.payload.reason === "reward");
    expect(reward.payload.delta).toEqual({ food: 52, wood: 53, stone: 123, gold: 123 });

    const state = await c.ok("get_state");
    expect(state.treasury).toEqual({
      food: 200 + 52,
      wood: 200 - 60 - 60 + 53,
      stone: 150 - 60 - 20 + 123,
      gold: 100 - 30 + 123,
    });
    const agent = state.agents.find((a: { id: string }) => a.id === agentId);
    expect(agent.xp).toBe(351);
    expect(agent.level).toBe(3);
    expect(agent.rank).toBe("F");
    expect(agent.stats.accepted).toBe(1);
    expect(agent.stats.accepted_first_try).toBe(1);
    expect(agent.stats.rites_passed).toBe(1);
    expect(agent.stats.mana_spent_micros).toBe(600_000);
    expect(state.mana.spent_micros).toBe(600_000);
    expect(state.mana.reserved_micros).toBe(0);
    expect(state.approvals).toEqual([]);

    // The task's worktree was removed after the merge (never with force).
    const ws = JSON.parse(town.ctx.tasks.row(taskId).workspace_json!);
    expect(ws.removed).toBe(true);
    expect(existsSync(ws.worktree)).toBe(false);

    const ledger = await c.ok("get_ledger", { limit: 50 });
    const sum = ledger.entries.reduce(
      (acc: Record<string, number>, e: { delta: Record<string, number> }) => {
        for (const k of Object.keys(acc)) acc[k]! += e.delta[k]!;
        return acc;
      },
      { food: 0, wood: 0, stone: 0, gold: 0 },
    );
    expect(sum).toEqual(state.treasury);
  });
});
