import { existsSync, mkdirSync, readFileSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Economy } from "../../src/core/economy.js";
import { defaultEconomyPath, defaultPricingPath, srcPath } from "../../src/paths.js";
import { CodexCliAdapter } from "../../src/providers/codex/adapter.js";
import { bundledPiCli } from "../../src/providers/common/exec.js";
import { FakeProvider } from "../../src/providers/fake/adapter.js";
import { ScenarioLibrary, type Step } from "../../src/providers/fake/scenarios.js";
import { PiAdapter } from "../../src/providers/pi/adapter.js";
import { harnessDeps } from "../../src/providers/real.js";
import type { ProviderAdapter } from "../../src/providers/types.js";
import { makeRepo } from "../helpers/git.js";
import { summonAgent, TestTown, type TestClient } from "../helpers/harness.js";
import { FIXTURES, readLog, writeJson } from "../helpers/run-host.js";

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

describe("tool paths that lead outside the worktree reach the player", () => {
  const PI_CLI = bundledPiCli();
  const env: Record<string, string | undefined> = { ...process.env };
  let town: TestTown;
  let c: TestClient;
  let scout: string;
  let pim: string;
  let outside = "";
  let home = "";

  type Attack = { tool: string; category: "read" | "write" | "mcp"; input: Record<string, unknown> };
  // Each spelling a harness reads as a place outside the worktree. In trusted_edits they all
  // used to pass as reads and writes inside the work folder, without a card. The Town Hall reads
  // ~ as its own home folder, so the home paths name a folder that does not exist.
  const NOWHERE = "aurelhaven-test-nowhere";
  const attacks = (out: string): Attack[] => [
    { tool: "write", category: "write", input: { path: `~/${NOWHERE}/.bashrc`, content: "export EVIL=1\n" } },
    { tool: "edit", category: "write", input: { path: `@${path.join(out, "notes.txt")}`, edits: [] } },
    { tool: "read", category: "read", input: { path: pathToFileURL(path.join(out, "secret.txt")).href } },
    { tool: "Grep", category: "read", input: { pattern: "token", path: `~/${NOWHERE}`, output_mode: "content" } },
    { tool: "Glob", category: "read", input: { pattern: `${out.replace(/\\/g, "/")}/*`, path: "src" } },
    { tool: "NotebookEdit", category: "write", input: { notebook_path: path.join(out, "nb.ipynb"), new_source: "x" } },
    { tool: "ls", category: "read", input: { path: `$HOME/${NOWHERE}` } },
    // The repository's .git, which every worktree shares: its pointer file, a nested one, a hook.
    { tool: "write", category: "write", input: { path: ".git", content: "gitdir: evil\n" } },
    { tool: "write", category: "write", input: { path: "sub/.git/config", content: "[core]\n\tfsmonitor = ./evil.sh\n" } },
    { tool: "edit", category: "write", input: { path: ".GIT/hooks/post-commit", edits: [] } },
    // Claude Code's file tools take absolute paths; a relative one starts from a folder that can move.
    { tool: "Read", category: "read", input: { file_path: "README.md" } },
    { tool: "Write", category: "write", input: { file_path: "notes.md", content: "x" } },
    // An MCP tool's other path fields.
    { tool: "mcp__filesystem__move_file", category: "mcp", input: { source: "README.md", destination: path.join(out, "moved.md") } },
  ];
  const ask = (a: Attack): Step => ({ op: "approval", expect: { ...a }, onAllow: [], onDeny: [] });

  beforeAll(async () => {
    town = await TestTown.start("approval-paths", {
      adapters: ({ root, dataDir }) => {
        outside = path.join(root, "outside");
        home = path.join(root, "home");
        mkdirSync(outside, { recursive: true });
        mkdirSync(home, { recursive: true });
        writeFileSync(path.join(outside, "secret.txt"), "secret\n");
        const library = new ScenarioLibrary(srcPath("providers", "fake", "scenarios"));
        library.add({
          name: "reach_outside",
          description: "",
          steps: [
            ...attacks(outside).map(ask),
            { op: "write_file", path: "inside.txt", content: "inside\n", append: false },
            { op: "end", summary: "Looked around." },
          ],
        });
        library.add({
          name: "reach_through_link",
          description: "",
          steps: [
            { op: "emit", kind: "message", text: "Waiting for the link." },
            { op: "hang", until: "nudge" },
            ask({ tool: "write", category: "write", input: { path: "linked/escape.txt", content: "x" } }),
            ask({ tool: "Read", category: "read", input: { file_path: "linked/secret.txt" } }),
            { op: "emit", kind: "message", text: "Done with the link." },
            { op: "hang", until: "nudge" },
            { op: "write_file", path: "inside.txt", content: "inside\n", append: false },
            { op: "end", summary: "Followed the link." },
          ],
        });
        const fake = (id: "claude" | "codex" | "pi") => new FakeProvider(id, { library, defaultScenario: "basic", microsPerMana: 10_000 });
        let pi: ProviderAdapter = fake("pi");
        if (PI_CLI) {
          // The real pi with a scripted model, its home folder a temp folder.
          Object.assign(env, {
            AURELHAVEN_PI_BIN: PI_CLI,
            PI_CODING_AGENT_DIR: path.join(root, "pi-agent"),
            PI_OFFLINE: "1",
            USERPROFILE: home,
            HOME: home,
          });
          const deps = harnessDeps({ econ: Economy.load(defaultEconomyPath()).data, dataDir, pricingPath: defaultPricingPath(), env });
          pi = new PiAdapter(deps, { extraArgs: ["-e", path.join(FIXTURES, "pi-faux-provider.mjs"), "--offline"] });
        }
        return { claude: fake("claude"), codex: fake("codex"), pi };
      },
    });
    c = await town.client();
    scout = await summonAgent(c, { name: "Scout", workspace: makeRepo(town.work, "scout") });
    if (PI_CLI) {
      pim = await summonAgent(c, { name: "Pim", provider: "pi", model: "faux/faux-1", workspace: makeRepo(town.work, "pim"), tile: { x: 60, y: 52 } });
    }
  });

  afterAll(async () => {
    await c.close();
    await town.stop();
  });

  const assign = async (agentId: string, prompt: string) =>
    (await c.ok("assign_task", { agent_id: agentId, title: prompt, prompt, size: "S", courier: { mode: "express" } })).task_id as string;
  const cards = (taskId: string, client = c) => client.events.filter((e) => e.type === "approval_requested" && e.payload.approval.task_id === taskId);
  const answered = new Set<string>();
  /** The task's next card that has not been answered yet. */
  const nextCard = async (taskId: string, client = c): Promise<Record<string, any>> => {
    const card = await client.waitEvent(
      (e) => e.type === "approval_requested" && e.payload.approval.task_id === taskId && !answered.has(e.payload.approval.id),
      30_000,
      `the next card of ${taskId}`,
    );
    answered.add(card.payload.approval.id);
    return card.payload.approval;
  };
  /** Checks that the next card asks about a place outside the worktree, and denies it. */
  const denyOutside = async (taskId: string, tool: string, client = c) => {
    const approval = await nextCard(taskId, client);
    expect(approval).toMatchObject({ tool, category: "outside_workspace", risk: "high", scopes: ["once"] });
    await client.ok("respond_approval", { approval_id: approval.id, decision: "deny", scope: "once" });
    return approval;
  };
  const worktreeOf = (taskId: string) => town.ctx.tasks.workspaceOf(town.ctx.tasks.row(taskId))!;

  it("asks in trusted_edits about ~, @, file://, $HOME, absolute patterns and notebook paths that lead outside", async () => {
    const taskId = await assign(scout, "[fake:reach_outside] Look around");
    for (const attack of attacks(outside)) await denyOutside(taskId, attack.tool);
    await c.waitTask(taskId, "awaiting_review");
    // The write inside the worktree still passed without a card.
    expect(cards(taskId)).toHaveLength(attacks(outside).length);
    expect(readFileSync(path.join(worktreeOf(taskId).cwd, "inside.txt"), "utf8")).toBe("inside\n");
  });

  it("follows a link inside the worktree to where it really leads", async () => {
    const taskId = await assign(scout, "[fake:reach_through_link] Follow the link");
    await c.waitEvent((e) => e.type === "task_activity" && e.payload.task_id === taskId && e.payload.entry.text.includes("Waiting for the link"));
    const link = path.join(worktreeOf(taskId).cwd, "linked");
    symlinkSync(outside, link, process.platform === "win32" ? "junction" : "dir");
    await c.ok("nudge_task", { task_id: taskId, message: "The link is there." });
    await denyOutside(taskId, "write");
    await denyOutside(taskId, "Read");
    await c.waitEvent((e) => e.type === "task_activity" && e.payload.task_id === taskId && e.payload.entry.text.includes("Done with the link"));
    // Gone again before the result is committed.
    unlinkSync(link);
    await c.ok("nudge_task", { task_id: taskId, message: "Carry on." });
    await c.waitTask(taskId, "awaiting_review");
    expect(cards(taskId)).toHaveLength(2);
    expect(existsSync(path.join(outside, "escape.txt"))).toBe(false);
  });

  it.skipIf(!PI_CLI)("pi: writes to ~, @<path> and file:// wait for the player, and a denial keeps them from happening", async () => {
    env.AURELHAVEN_PI_FAUX_SCRIPT = writeJson(town.root, "pi-paths.json", {
      responses: [
        { tool: "write", args: { path: `~/${NOWHERE}/.bashrc`, content: "export EVIL=1\n" } },
        { tool: "write", args: { path: `@${path.join(outside, "at.txt")}`, content: "x\n" } },
        { tool: "write", args: { path: pathToFileURL(path.join(outside, "url.txt")).href, content: "x\n" } },
        { tool: "write", args: { path: "notes.md", content: "# Notes\n" } },
        { text: "Wrote notes.md." },
      ],
    });
    const taskId = await assign(pim, "Write some notes.");
    for (let i = 0; i < 3; i++) await denyOutside(taskId, "write");
    const review = await c.waitTask(taskId, "awaiting_review", 30_000);
    expect(review.payload.task.result.summary).toBe("Wrote notes.md.");
    expect(cards(taskId)).toHaveLength(3);
    expect(existsSync(path.join(home, NOWHERE))).toBe(false);
    expect(existsSync(path.join(outside, "at.txt"))).toBe(false);
    expect(existsSync(path.join(outside, "url.txt"))).toBe(false);
    expect(readFileSync(path.join(worktreeOf(taskId).cwd, "notes.md"), "utf8")).toBe("# Notes\n");
  });

  it("Codex: a command's extra sandbox access and its working folder are judged like file paths", async () => {
    // Its own town: an Age I town has room for two agents only.
    const codexEnv: Record<string, string | undefined> = { ...process.env };
    let codexLog = "";
    const codexTown = await TestTown.start("approval-paths-codex", {
      adapters: ({ root, dataDir }) => {
        codexLog = path.join(root, "fake-codex.log");
        Object.assign(codexEnv, {
          AURELHAVEN_CODEX_BIN: path.join(FIXTURES, "fake-codex.mjs"),
          FAKE_CODEX_HOME: path.join(root, "codex-threads"),
          FAKE_CODEX_LOG: codexLog,
        });
        const deps = harnessDeps({ econ: Economy.load(defaultEconomyPath()).data, dataDir, pricingPath: defaultPricingPath(), env: codexEnv });
        const library = new ScenarioLibrary(srcPath("providers", "fake", "scenarios"));
        const fake = (id: "claude" | "pi") => new FakeProvider(id, { library, defaultScenario: "basic", microsPerMana: 10_000 });
        return { claude: fake("claude"), codex: new CodexCliAdapter(deps), pi: fake("pi") };
      },
    });
    const cc = await codexTown.client();
    try {
      const away = path.join(codexTown.root, "away");
      mkdirSync(away);
      codexEnv.FAKE_CODEX_SCENARIO = writeJson(codexTown.root, "codex.json", {
        turns: [
          {
            steps: [
              { command: "npm test", additionalPermissions: { network: null, fileSystem: { read: null, write: [away] } } },
              { command: "npm run build", additionalPermissions: { network: null, fileSystem: { read: null, write: ["dist"] } } },
              { command: "npm run lint", additionalPermissions: { network: null, fileSystem: null, somethingNew: { enabled: true } } },
              { command: "npm test", cwd: away },
              { text: "Done." },
            ],
          },
        ],
      });
      const agentId = await summonAgent(cc, {
        name: "Cody",
        provider: "codex",
        model: "gpt-5.6-luna",
        workspace: makeRepo(codexTown.work, "cody"),
        tools: ["lectern", "quillworks", "forge"],
      });
      const { task_id: taskId } = await cc.ok("assign_task", { agent_id: agentId, title: "Build", prompt: "Build and test.", size: "S", courier: { mode: "express" } });

      const extra = await denyOutside(taskId, "shell", cc);
      expect(extra.summary).toBe(`Run: npm test, with write access to ${away.replace(/\\/g, "/")}`);
      const inside = await nextCard(taskId, cc);
      expect(inside).toMatchObject({ tool: "shell", category: "command", summary: "Run: npm run build, with write access to dist" });
      await cc.ok("respond_approval", { approval_id: inside.id, decision: "allow", scope: "once" });
      // The lint command's request is not understood: declined without a card. Then the command run outside.
      await denyOutside(taskId, "shell", cc);
      await cc.waitTask(taskId, "awaiting_review", 30_000);
      expect(cards(taskId, cc)).toHaveLength(3);
      const decisions = readLog(codexLog).filter((e) => e.kind === "approval").map((e) => e.response.result.decision);
      expect(decisions).toEqual(["decline", "accept", "decline", "decline"]);
    } finally {
      await cc.close();
      await codexTown.stop();
    }
  });
});
