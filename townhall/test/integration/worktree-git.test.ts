import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { commitAll, git, makeRepo, markCommand, markConfig, plantRepo, replaceFile, writeMarkHooks } from "../helpers/git.js";
import { summonAgent, TestTown, type TestClient } from "../helpers/harness.js";

const PLAYER = ["-c", "user.name=Test Player", "-c", "user.email=player@example.invalid", "-c", "commit.gpgsign=false"];
/** A planted HEAD only has to look like a commit id. */
const SOME_COMMIT = "0123456789abcdef0123456789abcdef01234567";

interface Workspace {
  repo: string;
  worktree: string;
  branch: string;
  base_sha: string;
  snapshot_sha: string | null;
  archived_ref: string | null;
}

/** Age I allows two agents: one works in a git repository, the other in a plain folder. */
describe("the Town Hall's own git runs nothing an agent planted in its work folder", () => {
  let town: TestTown;
  let c: TestClient;
  let repo: string;
  let folder: string;
  const agent: Record<"repo" | "folder", string> = { repo: "", folder: "" };

  beforeAll(async () => {
    town = await TestTown.start("worktree-git");
    c = await town.client();
    town.ctx.treasury.credit({ food: 3000, wood: 3000, stone: 3000, gold: 3000 }, "reward", "reward", null, "worktree-git");
    repo = makeRepo(town.work, "app");
    folder = path.join(town.work, "notes");
    mkdirSync(folder, { recursive: true });
    writeFileSync(path.join(folder, "todo.txt"), "buy bread\n");
    agent.repo = await summonAgent(c, { name: "Mira", workspace: repo });
    agent.folder = await summonAgent(c, { name: "Quill", role: "scribe", workspace: folder, tile: { x: 60, y: 60 } });
  });

  afterAll(async () => {
    await c.close();
    await town.stop();
  });

  const marksFile = (label: string) => path.join(town.root, `marks-${label}.txt`);
  const workspaceOf = (taskId: string) => JSON.parse(town.ctx.tasks.row(taskId).workspace_json!) as Workspace;

  async function assign(agentId: string, prompt: string): Promise<string> {
    const { task_id: taskId } = await c.ok("assign_task", { agent_id: agentId, title: "Work", prompt, size: "S", courier: { mode: "express" } });
    return taskId as string;
  }

  /**
   * Starts a task whose agent waits for a nudge, so the test can write into its worktree first,
   * as the agent could with its file tools alone.
   */
  async function startWaiting(agentId: string): Promise<{ taskId: string; ws: Workspace }> {
    const taskId = await assign(agentId, "[fake:nudge] Wait for a hint");
    await c.waitTask(taskId, "running");
    return { taskId, ws: workspaceOf(taskId) };
  }

  async function finish(taskId: string, state: string): Promise<void> {
    await c.ok("nudge_task", { task_id: taskId, message: "Go on." });
    await c.waitTask(taskId, state);
  }

  const snapshotNote = (taskId: string) =>
    c.waitEvent((e) => e.type === "task_activity" && e.payload.task_id === taskId && e.payload.entry.text.includes("Left out of the snapshot"));

  it.each(["repo", "folder"] as const)("refuses to run git in a worktree whose .git was redirected (work folder: %s)", async (kind) => {
    const marks = marksFile(`redirect-${kind}`);
    const { taskId, ws } = await startWaiting(agent[kind]);

    // A repository of the agent's own, a .gitattributes naming its filter and textconv, and the
    // worktree's .git aimed at that repository.
    const evil = path.join(ws.worktree, "evil");
    plantRepo(evil, "ref: refs/heads/main", marks);
    writeFileSync(path.join(ws.worktree, ".gitattributes"), "* filter=mark diff=mark\n");
    replaceFile(path.join(ws.worktree, ".git"), "gitdir: evil\n");

    await finish(taskId, "failed");
    expect(town.ctx.tasks.row(taskId).state_reason).toBe("WORKSPACE_DENIED");
    const smoke = await c.waitEvent(
      (e) => e.type === "incident_opened" && e.payload.incident.kind === "smoke" && e.payload.incident.subject.task_id === taskId,
    );
    expect(smoke.payload.incident.message).toMatch(/the work folder's \.git was changed/);
    // git never ran there: no index or branch in the planted repository, no commit on the task's.
    expect(existsSync(path.join(evil, "index"))).toBe(false);
    expect(existsSync(path.join(evil, "refs", "heads", "main"))).toBe(false);
    expect(git(ws.repo, "rev-parse", ws.branch)).toBe(ws.base_sha);

    // The review and the discard refuse with the same reason.
    const detail = await c.send("get_task_detail", { task_id: taskId, include: ["activity", "diff"] });
    expect(detail.error?.code).toBe("WORKSPACE_DENIED");
    expect(detail.error?.message).toMatch(/\.git was changed/);
    const discard = await c.send("discard_workspace", { task_id: taskId, confirm: true });
    expect(discard.error?.code).toBe("WORKSPACE_DENIED");
    expect(existsSync(marks)).toBe(false);

    // Once the player has deleted the worktree, the discard archives the branch as usual.
    rmSync(ws.worktree, { recursive: true, force: true });
    await c.ok("discard_workspace", { task_id: taskId, confirm: true });
    expect(workspaceOf(taskId).archived_ref).toBe(`refs/agentempire/archive/${taskId}`);
    expect(town.ctx.tasks.row(taskId).state).toBe("cancelled");
    expect(existsSync(marks)).toBe(false);
  });

  it("leaves a nested repository out of the snapshot and never runs git inside it", async () => {
    const marks = marksFile("nested");
    const { taskId, ws } = await startWaiting(agent.repo);
    plantRepo(path.join(ws.worktree, "sub", ".git"), SOME_COMMIT, marks);
    writeFileSync(path.join(ws.worktree, "sub", "work.txt"), "inside the nested repository\n");
    mkdirSync(path.join(ws.worktree, "notes"));
    writeFileSync(path.join(ws.worktree, "notes", "plan.md"), "# Plan\n");

    await finish(taskId, "awaiting_review");
    expect(existsSync(marks)).toBe(false);
    const tree = git(repo, "ls-tree", "-r", "--name-only", workspaceOf(taskId).snapshot_sha!).split("\n");
    expect(tree.sort()).toEqual(["README.md", "notes/plan.md", "nudged.txt"]);
    expect((await snapshotNote(taskId)).payload.entry.text).toContain("sub/");

    const detail = await c.ok("get_task_detail", { task_id: taskId, include: ["diff"] });
    expect(detail.diff.files.map((f: { path: string }) => f.path).sort()).toEqual(["notes/plan.md", "nudged.txt"]);
    // The merge takes the rest; the worktree, which still holds sub/, stays for the player.
    const merged = await c.ok("accept_result", { task_id: taskId, integrate: "merge" });
    expect(merged.merge.commit).toMatch(/^[0-9a-f]{40}$/);
    expect(readFileSync(path.join(repo, "notes", "plan.md"), "utf8")).toBe("# Plan\n");
    expect(existsSync(path.join(repo, "sub"))).toBe(false);
    expect(existsSync(marks)).toBe(false);
  });

  it("never runs git inside a submodule folder the agent filled in", async () => {
    const marks = marksFile("submodule");
    git(repo, "update-index", "--add", "--cacheinfo", `160000,${SOME_COMMIT},lib`);
    git(repo, ...PLAYER, "commit", "-q", "-m", "Add the lib submodule");
    mkdirSync(path.join(repo, "lib"));
    const { taskId, ws } = await startWaiting(agent.repo);
    // A repository whose HEAD is the commit the submodule records: `git add` would see no change
    // and run `git status` inside it, which would fetch HEAD through the planted remote.
    plantRepo(path.join(ws.worktree, "lib", ".git"), SOME_COMMIT, marks);
    writeFileSync(path.join(ws.worktree, "lib", "work.txt"), "inside the submodule\n");

    await finish(taskId, "awaiting_review");
    expect(existsSync(marks)).toBe(false);
    expect(git(repo, "ls-tree", workspaceOf(taskId).snapshot_sha!, "lib")).toBe(`160000 commit ${SOME_COMMIT}\tlib`);
    expect((await snapshotNote(taskId)).payload.entry.text).toContain("lib/");
    await c.ok("get_task_detail", { task_id: taskId, include: ["diff"] });
    expect(existsSync(marks)).toBe(false);
  });

  it("runs no fsmonitor command, hook, textconv or external diff from the repository's config", async () => {
    // What an approved `git config` command can leave in the repository that worktrees share.
    const marks = marksFile("shared-config");
    writeFileSync(path.join(repo, ".gitattributes"), "*.md diff=mark\n");
    commitAll(repo, "Name a textconv for Markdown");
    git(repo, "config", "core.fsmonitor", `${markCommand("fsmonitor", marks)}; false`);
    git(repo, "config", "diff.external", markCommand("external-diff", marks));
    git(repo, "config", "diff.mark.textconv", `${markCommand("textconv", marks)}; cat`);
    writeMarkHooks(path.join(repo, ".git", "hooks"), marks);

    const taskId = await assign(agent.repo, "[fake:basic] Leave a note");
    await c.waitTask(taskId, "awaiting_review");
    const detail = await c.ok("get_task_detail", { task_id: taskId, include: ["diff"] });
    expect(detail.diff.patch).toContain("+Notes from a fake agent.");
    const merged = await c.ok("accept_result", { task_id: taskId, integrate: "merge" });
    expect(merged.merge.commit).toMatch(/^[0-9a-f]{40}$/);
    expect(existsSync(marks)).toBe(false);

    // Plain git in the same repository runs them.
    git(repo, "status");
    git(repo, "diff", "HEAD~1", "HEAD");
    const ran = readFileSync(marks, "utf8");
    expect(ran).toContain("fsmonitor");
    expect(ran).toContain("external-diff");
  });

  it("copies no spelling of .git from a plain folder into the Town Hall's copy", async () => {
    const marks = marksFile("copy");
    mkdirSync(path.join(folder, ".GIT"));
    writeFileSync(path.join(folder, ".GIT", "config"), markConfig(marks));
    writeFileSync(path.join(folder, ".gitattributes"), "* filter=mark\n");

    // Each task brings the copy up to date first.
    const taskId = await assign(agent.folder, "[fake:basic] Leave a note");
    await c.waitTask(taskId, "awaiting_review");
    const mirror = town.ctx.agents.row(agent.folder).mirror_path!;
    expect(readFileSync(path.join(mirror, ".git", "config"), "utf8")).not.toContain("mark");
    expect(git(mirror, "ls-files").split("\n")).toEqual([".gitattributes", "todo.txt"]);
    expect(existsSync(marks)).toBe(false);
  });
});
