import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { git, makeRepo, treeHashes } from "../helpers/git.js";
import { summonAgent, TestTown, type TestClient } from "../helpers/harness.js";

describe("the main checkout is protected", () => {
  let town: TestTown;
  let c: TestClient;

  beforeAll(async () => {
    town = await TestTown.start("checkout");
    c = await town.client();
  });

  afterAll(async () => {
    await c.close();
    await town.stop();
  });

  it("refuses work folders outside the allowed roots", async () => {
    const r = await c.send("create_agent", {
      spec: {
        name: "Outsider",
        provider: "claude",
        model: "fake-claude",
        role: "artificer",
        instructions: "",
        approval_mode: "trusted_edits",
        workspace: { path: town.root },
        starting_tools: [],
      },
    });
    expect(r.error?.code).toBe("WORKSPACE_DENIED");
  });

  it("stays byte-identical until accept, and a dirty or switched checkout blocks the merge", async () => {
    const repo = makeRepo(town.work, "app", { "README.md": "# App\n", "src/main.txt": "main\n" });
    const agentId = await summonAgent(c, { workspace: repo });
    const hashes = treeHashes(repo);
    const head = git(repo, "rev-parse", "HEAD");

    const { task_id: taskId } = await c.ok("assign_task", {
      agent_id: agentId,
      title: "Note",
      prompt: "[fake:basic] Leave a note",
      size: "S",
      courier: { mode: "express" },
    });
    await c.waitTask(taskId, "awaiting_review");
    expect(treeHashes(repo)).toEqual(hashes);
    expect(git(repo, "rev-parse", "HEAD")).toBe(head);
    expect(git(repo, "status", "--porcelain")).toBe("");
    expect(git(repo, "branch", "--list", `agentempire/${agentId}/${taskId}`)).toContain(taskId);
    const ws = JSON.parse(town.ctx.tasks.row(taskId).workspace_json!);
    expect(path.basename(ws.worktree)).toHaveLength(8);
    expect(git(repo, "worktree", "list", "--porcelain")).toContain("locked");

    // A dirty main checkout blocks the merge and changes nothing.
    writeFileSync(path.join(repo, "README.md"), "# App, edited by the player\n");
    const blocked = await c.ok("accept_result", { task_id: taskId, integrate: "merge" });
    expect(blocked.rewards).toBeNull();
    expect(blocked.merge.blocked_reason).toBe("checkout_dirty");
    await c.waitEvent((e) => e.type === "incident_opened" && e.payload.incident.kind === "merge_blocked");
    expect(town.ctx.tasks.row(taskId).state).toBe("accepting");
    expect(readFileSync(path.join(repo, "README.md"), "utf8")).toBe("# App, edited by the player\n");
    expect(existsSync(path.join(repo, "agentempire-note.md"))).toBe(false);

    // Being on another branch blocks it too.
    writeFileSync(path.join(repo, "README.md"), "# App\n");
    git(repo, "switch", "-q", "-c", "feature");
    const wrong = await c.ok("accept_result", { task_id: taskId, integrate: "merge" });
    expect(wrong.merge.blocked_reason).toBe("wrong_branch");
    git(repo, "switch", "-q", "main");
    expect(treeHashes(repo)).toEqual(hashes);

    const merged = await c.ok("accept_result", { task_id: taskId, integrate: "merge" });
    expect(merged.merge.commit).toMatch(/^[0-9a-f]{40}$/);
    expect(readFileSync(path.join(repo, "agentempire-note.md"), "utf8")).toBe("Notes from a fake agent.\n");
    await c.waitTask(taskId, "accepted");
    await c.waitEvent((e) => e.type === "incident_resolved");
    // A run shorter than bounty.min_run_s pays nothing.
    expect(town.ctx.tasks.get(taskId).rewards?.breakdown.zero_reason).toBe("too_short");
  });

  it("works in a Town Hall copy of a plain folder and exports on accept", async () => {
    const folder = path.join(town.work, "notes");
    mkdirSync(folder, { recursive: true });
    writeFileSync(path.join(folder, "todo.txt"), "buy bread\n");
    const c2 = c;
    // The first agent keeps the Font's Grace; this one pays.
    const agentId = await summonAgent(c2, { workspace: folder, role: "scribe", name: "Quill", tile: { x: 60, y: 60 } });
    const agent = (await c2.ok("get_state")).agents.find((a: { id: string }) => a.id === agentId);
    expect(agent.workspace.mode).toBe("plain_folder");
    expect(agent.workspace.repo_root).toBeNull();
    const before = treeHashes(folder);

    const { task_id: taskId } = await c2.ok("assign_task", {
      agent_id: agentId,
      title: "Note",
      prompt: "[fake:basic] A different note",
      size: "S",
      courier: { mode: "express" },
    });
    await c2.waitTask(taskId, "awaiting_review");
    expect(treeHashes(folder)).toEqual(before);
    expect(existsSync(path.join(folder, ".git"))).toBe(false);

    const merge = await c2.ok("accept_result", { task_id: taskId, integrate: "merge" });
    expect(merge.merge.blocked_reason).toBe("not_a_repo");
    const exported = await c2.ok("accept_result", { task_id: taskId, integrate: "export" });
    expect(exported.rewards).not.toBeNull();
    expect(readFileSync(path.join(folder, "agentempire-note.md"), "utf8")).toBe("Notes from a fake agent.\n");
    expect(readFileSync(path.join(folder, "todo.txt"), "utf8")).toBe("buy bread\n");
    expect(existsSync(path.join(folder, ".git"))).toBe(false);
  });
});
