import { readFileSync } from "node:fs";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { Economy } from "../../src/core/economy.js";
import { defaultEconomyPath, defaultPricingPath } from "../../src/paths.js";
import { bundledPiCli } from "../../src/providers/common/exec.js";
import { harnessDeps } from "../../src/providers/real.js";
import { ClaudeCodeAdapter } from "../../src/providers/claude/adapter.js";
import { CodexCliAdapter } from "../../src/providers/codex/adapter.js";
import { PiAdapter } from "../../src/providers/pi/adapter.js";
import { git, makeRepo } from "../helpers/git.js";
import { summonAgent, TestTown, type TestClient } from "../helpers/harness.js";
import { FIXTURES, writeJson } from "../helpers/run-host.js";

const PI_CLI = bundledPiCli();

// The whole Town Hall with the real adapters: a fake Claude Code CLI, a fake codex app-server
// and the real pi with a scripted provider. Approvals go through the ApprovalService (approval
// modes, cards, respond_approval), finished work goes to review, and Mana is billed per provider.
describe.skipIf(!PI_CLI)("the Town Hall with the real harness adapters", () => {
  let town: TestTown;
  let c: TestClient;
  const env: Record<string, string | undefined> = { ...process.env };

  // A fresh town per case: Age 1 allows two agents and a starting treasury pays for them.
  beforeEach(async () => {
    town = await TestTown.start("real-harness", {
      adapters: ({ root, dataDir }) => {
        Object.assign(env, {
          AURELHAVEN_CLAUDE_BIN: path.join(FIXTURES, "fake-claude.mjs"),
          FAKE_CLAUDE_HOME: path.join(root, "claude-sessions"),
          AURELHAVEN_CODEX_BIN: path.join(FIXTURES, "fake-codex.mjs"),
          FAKE_CODEX_HOME: path.join(root, "codex-threads"),
          AURELHAVEN_PI_BIN: PI_CLI!,
          PI_CODING_AGENT_DIR: path.join(root, "pi-agent"),
          PI_OFFLINE: "1",
        });
        const deps = harnessDeps({ econ: Economy.load(defaultEconomyPath()).data, dataDir, pricingPath: defaultPricingPath(), env });
        return {
          claude: new ClaudeCodeAdapter(deps),
          codex: new CodexCliAdapter(deps),
          pi: new PiAdapter(deps, { extraArgs: ["-e", path.join(FIXTURES, "pi-faux-provider.mjs"), "--offline"] }),
        };
      },
    });
    c = await town.client();
  });

  afterEach(async () => {
    await c.close();
    await town.stop();
  });

  const cases = [
    {
      provider: "claude" as const,
      model: "haiku",
      setup: () => {
        env.FAKE_CLAUDE_SCENARIO = writeJson(town.root, "claude.json", {
          turns: [
            {
              steps: [
                { tool: "Write", input: { file_path: "notes.md", content: "# Notes\n" } },
                { tool: "Bash", input: { command: "npm test" } },
                { cost: 0.03 },
                { text: "Added notes.md." },
              ],
            },
          ],
        });
      },
      commandTool: "Bash",
    },
    {
      provider: "codex" as const,
      model: "gpt-5.6-luna",
      setup: () => {
        env.FAKE_CODEX_SCENARIO = writeJson(town.root, "codex.json", {
          turns: [
            {
              steps: [
                { patch: [{ path: "notes.md", content: "# Notes\n" }] },
                { command: "npm test" },
                { tokens: { input: 100_000, output: 10_000 } },
                { text: "Added notes.md." },
              ],
            },
          ],
        });
      },
      commandTool: "shell",
    },
    {
      provider: "pi" as const,
      model: "faux/faux-1",
      setup: () => {
        env.AURELHAVEN_PI_FAUX_SCRIPT = writeJson(town.root, "pi.json", {
          responses: [
            { tool: "write", args: { path: "notes.md", content: "# Notes\n" } },
            { tool: "bash", args: { command: "echo testing" } },
            { text: "Added notes.md." },
          ],
        });
      },
      commandTool: "bash",
    },
  ];

  it("reports all three harnesses as installed and signed in", async () => {
    const { providers } = await c.ok("check_providers", {});
    for (const id of ["claude", "codex", "pi"]) {
      expect(providers.find((p: { id: string }) => p.id === id)).toMatchObject({ installed: true, logged_in: true });
    }
  });

  it.each(cases)("$provider: edits are automatic in trusted_edits, the command waits for the player, the work reaches review", async (tc) => {
    const repo = makeRepo(town.work, `app-${tc.provider}`);
    tc.setup();
    const agentId = await summonAgent(c, {
      name: `Agent ${tc.provider}`,
      provider: tc.provider,
      model: tc.model,
      workspace: repo,
      tools: ["lectern", "quillworks", "forge"],
      tile: { x: 40 + tc.provider.length * 3, y: 52 },
    });
    const before = (await c.ok("get_state")).mana.by_provider[tc.provider] as number;
    const { task_id: taskId } = await c.ok("assign_task", {
      agent_id: agentId,
      title: "Write notes",
      prompt: "Create notes.md with a heading, then run the tests.",
      size: "S",
      courier: { mode: "express" },
    });
    const card = await c.waitEvent((e) => e.type === "approval_requested" && e.payload.approval.task_id === taskId, 30_000, "command approval");
    expect(card.payload.approval).toMatchObject({ tool: tc.commandTool, category: "command" });
    await c.ok("respond_approval", { approval_id: card.payload.approval.id, decision: "allow", scope: "once" });
    const review = await c.waitTask(taskId, "awaiting_review", 30_000);
    expect(review.payload.task.result.summary).toBe("Added notes.md.");
    expect(review.payload.task.result.diff_stat.files).toBe(1);
    // The write never became a card: trusted_edits allowed it inside the worktree.
    const cards = c.events.filter((e) => e.type === "approval_requested" && e.payload.approval.task_id === taskId);
    expect(cards).toHaveLength(1);
    const mana = (await c.ok("get_state")).mana;
    expect(mana.by_provider[tc.provider]).toBeGreaterThan(before);
    // The player's main checkout is untouched until the result is accepted.
    expect(git(repo, "status", "--porcelain")).toBe("");
    const detail = await c.ok("get_task_detail", { task_id: taskId, include: ["diff"] });
    expect(detail.diff.files.map((f: { path: string }) => f.path)).toEqual(["notes.md"]);
    const worktree = town.ctx.tasks.workspaceOf(town.ctx.tasks.row(taskId))!.worktree;
    expect(readFileSync(path.join(worktree, "notes.md"), "utf8")).toBe("# Notes\n");
  });
});
