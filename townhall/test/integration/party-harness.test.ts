import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { Economy } from "../../src/core/economy.js";
import { defaultEconomyPath, defaultPricingPath, srcPath } from "../../src/paths.js";
import { ClaudeCodeAdapter } from "../../src/providers/claude/adapter.js";
import { CodexCliAdapter } from "../../src/providers/codex/adapter.js";
import { FakeProvider } from "../../src/providers/fake/adapter.js";
import { ScenarioLibrary } from "../../src/providers/fake/scenarios.js";
import { harnessDeps } from "../../src/providers/real.js";
import { makeRepo } from "../helpers/git.js";
import { summonAgent, TestTown, type TestClient } from "../helpers/harness.js";
import { FIXTURES, readLog, writeJson } from "../helpers/run-host.js";

/**
 * Parties on the real harness adapters (docs/spikes.md S5): a Claude Code lead delegates through
 * the town MCP server (delegate, check_status, collect_results) to a Codex member and a Claude
 * member, all played by the fake CLIs in test/fixtures.
 */
describe("parties on the real harnesses: a Claude lead with the town tools", () => {
  let town: TestTown;
  let c: TestClient;
  let claudeLog: string;
  let codexLog: string;
  let lead: string;
  let quill: string;
  let rune: string;
  let repos: Record<string, string>;
  const env: Record<string, string | undefined> = { ...process.env };

  beforeEach(async () => {
    town = await TestTown.start("party-harness", {
      adapters: ({ root, dataDir }) => {
        claudeLog = path.join(root, "fake-claude.log");
        codexLog = path.join(root, "fake-codex.log");
        Object.assign(env, {
          AURELHAVEN_CLAUDE_BIN: path.join(FIXTURES, "fake-claude.mjs"),
          FAKE_CLAUDE_HOME: path.join(root, "claude-sessions"),
          FAKE_CLAUDE_LOG: claudeLog,
          AURELHAVEN_CODEX_BIN: path.join(FIXTURES, "fake-codex.mjs"),
          FAKE_CODEX_HOME: path.join(root, "codex-threads"),
          FAKE_CODEX_LOG: codexLog,
        });
        const deps = harnessDeps({ econ: Economy.load(defaultEconomyPath()).data, dataDir, pricingPath: defaultPricingPath(), env });
        const pi = new FakeProvider("pi", { library: new ScenarioLibrary(srcPath("providers", "fake", "scenarios")), defaultScenario: "basic", microsPerMana: 10_000 });
        return { claude: new ClaudeCodeAdapter(deps), codex: new CodexCliAdapter(deps), pi };
      },
    });
    c = await town.client();
    // Age II (parties), resources for three agents, and a lead of rank E.
    town.ctx.db.tx(() => town.ctx.settings.setState("age", { current: 2, research: null }));
    town.ctx.treasury.credit({ food: 3000, wood: 3000, stone: 3000, gold: 3000 }, "reward", "reward", null, "party-harness");
    repos = { lead: makeRepo(town.work, "engine"), quill: makeRepo(town.work, "docs"), rune: makeRepo(town.work, "tools") };
    const tools = ["lectern", "quillworks", "forge"];
    lead = await summonAgent(c, { name: "Mira", provider: "claude", model: "haiku", workspace: repos.lead!, tools, tile: { x: 40, y: 52 } });
    quill = await summonAgent(c, { name: "Quill", role: "scribe", provider: "codex", model: "gpt-5.6-luna", workspace: repos.quill!, tools, tile: { x: 60, y: 52 } });
    rune = await summonAgent(c, { name: "Rune", provider: "claude", model: "haiku", workspace: repos.rune!, tools, tile: { x: 70, y: 60 } });
    town.ctx.db.tx(() => {
      town.ctx.db.run("UPDATE agents SET xp = 150, stats_json = json_set(stats_json, '$.accepted', 2) WHERE id = ?", [lead]);
      town.ctx.agents.recomputeRank(lead);
    });
  });

  afterEach(async () => {
    await c.close();
    await town.stop();
  });

  const formParty = async () => (await c.ok("form_party", { lead_agent_id: lead, member_ids: [quill, rune] })).party_id as string;
  const scenarios = (named: Record<string, unknown>) => {
    env.FAKE_CLAUDE_SCENARIOS = writeJson(town.root, `claude-${Math.random().toString(36).slice(2)}.json`, named);
  };

  it("delegates to a Codex and a Claude member, every member approval reaches the player, and the party is paid once", async () => {
    scenarios({
      lead: {
        turns: [
          {
            steps: [
              { text: "I will split the work." },
              { mcp_tool: "mcp__town__delegate", input: { member: "Nobody", title: "Lost", prompt: "Nothing" } },
              { mcp_tool: "mcp__town__delegate", input: { member: "Quill", title: "Write the docs", prompt: "Write docs.md about the helper." } },
              { mcp_tool: "mcp__town__delegate", input: { member: "rune", title: "Write the helper", prompt: "[scenario:member] Write helper.txt.", budget_mana: 20 } },
              { mcp_tool: "mcp__town__check_status", input: {} },
              { mcp_tool: "mcp__town__collect_results", input: { wait_seconds: 120 } },
              { tool: "Write", input: { file_path: "lead.txt", content: "The lead's part.\n" } },
              { cost: 0.03 },
              { text: "The party wrote docs.md, helper.txt and lead.txt." },
            ],
          },
        ],
      },
      member: {
        turns: [
          {
            steps: [
              { tool: "Write", input: { file_path: "helper.txt", content: "helper\n" } },
              { tool: "Bash", input: { command: "npm test" } },
              { cost: 0.01 },
              { text: "Wrote helper.txt and ran the tests." },
            ],
          },
        ],
      },
    });
    env.FAKE_CODEX_SCENARIO = writeJson(town.root, "codex.json", {
      turns: [{ steps: [{ patch: [{ path: "docs.md", content: "# Docs\n" }] }, { command: "npm test" }, { tokens: { input: 20_000, output: 2_000 } }, { text: "Wrote docs.md." }] }],
    });
    const partyId = await formParty();
    const { task_id: parentId } = await c.ok("assign_task", {
      party_id: partyId,
      title: "Build the helper with its docs",
      prompt: "[scenario:lead] Build the helper, its docs and your own part.",
      size: "M",
      courier: { mode: "express" },
    });

    // Both members get a sub-task; each command they run waits for the player.
    const delegated = await Promise.all([
      c.waitEvent((e) => e.type === "subtask_delegated" && e.payload.to_agent_id === quill, 30_000, "delegated to Quill"),
      c.waitEvent((e) => e.type === "subtask_delegated" && e.payload.to_agent_id === rune, 30_000, "delegated to Rune"),
    ]);
    const [quillTask, runeTask] = delegated.map((e) => e.payload.task_id as string);
    expect(delegated.every((e) => e.payload.parent_task_id === parentId && e.payload.from_agent_id === lead)).toBe(true);
    for (const [agent, task, tool] of [[quill, quillTask, "shell"], [rune, runeTask, "Bash"]] as const) {
      const card = await c.waitEvent((e) => e.type === "approval_requested" && e.payload.approval.task_id === task, 30_000, `${tool} approval`);
      expect(card.payload.approval).toMatchObject({ agent_id: agent, tool, category: "command" });
      await c.ok("respond_approval", { approval_id: card.payload.approval.id, decision: "allow", scope: "once" });
    }
    // Long enough to earn a reward (bounty.min_run_s) while the lead waits for its party.
    town.clock.advance(31_000);
    await c.waitTask(quillTask!, "awaiting_review", 30_000);
    await c.waitTask(runeTask!, "awaiting_review", 30_000);
    const review = await c.waitTask(parentId, "awaiting_review", 30_000);
    expect(review.payload.task.result.summary).toBe("The party wrote docs.md, helper.txt and lead.txt.");

    // The lead's town tools never asked the player: only the members' commands did.
    const cards = c.events.filter((e) => e.type === "approval_requested").map((e) => e.payload.approval);
    expect(cards.map((a) => a.task_id).sort()).toEqual([quillTask, runeTask].sort());

    // Budgets came out of the lead's seal: Quill's S seal (40), then the 20 asked for Rune.
    expect(town.ctx.tasks.row(quillTask!).seal_micros).toBe(400_000);
    expect(town.ctx.tasks.row(runeTask!).seal_micros).toBe(200_000);
    expect(town.ctx.tasks.row(parentId).seal_micros).toBe(1_500_000 - 600_000);

    // What the lead saw.
    const log = readLog(claudeLog);
    const starts = log.filter((e) => e.kind === "start");
    const leadStart = starts.find((e) => e.systemPrompt?.includes("## Your party"))!;
    expect(leadStart.systemPrompt).toContain("- Quill: Scribe (Writing and docs), on codex");
    expect(leadStart.systemPrompt).toContain("mcp__town__collect_results");
    const memberStart = starts.find((e) => e.systemPrompt?.includes("delegated to you"))!;
    expect(memberStart.systemPrompt).not.toContain("## Your party");
    // The lead sees its town tools directly (no deferred loading behind ToolSearch).
    expect(leadStart.toolSearch).toBe("false");
    expect(memberStart.toolSearch).toBeNull();
    const configs = log.filter((e) => e.kind === "mcp_config").map((e) => Object.keys(e.servers).sort());
    expect(configs).toContainEqual(["aurelhaven", "town"]);
    expect(configs).toContainEqual(["aurelhaven"]);
    const townServer = log.find((e) => e.kind === "mcp_config" && e.servers.town)!.servers.town;
    expect(townServer.args[0]).toMatch(/town-mcp\.mjs$/);
    expect(leadStart.argv.join(" ")).not.toContain(townServer.env.AURELHAVEN_TOWN_TOKEN);
    expect(leadStart.envNames).not.toContain("AURELHAVEN_TOWN_TOKEN");
    const listed = log.find((e) => e.kind === "mcp_tools" && e.server === "town")!.tools;
    expect(listed.map((t: { name: string }) => t.name)).toEqual(["delegate", "check_status", "collect_results"]);
    expect(listed[0].inputSchema.properties.member.enum).toEqual(["Quill", "Rune"]);

    const calls = log.filter((e) => e.kind === "mcp_call");
    expect(calls.map((e) => [e.tool, e.isError])).toEqual([
      ["mcp__town__delegate", true],
      ["mcp__town__delegate", false],
      ["mcp__town__delegate", false],
      ["mcp__town__check_status", false],
      ["mcp__town__collect_results", false],
    ]);
    expect(calls[0].text).toMatch(/no party member matches "Nobody" \(members: Quill, Rune\)/);
    expect(JSON.parse(calls[1].text)).toMatchObject({ task_id: quillTask, member: "Quill", budget_mana: 40 });
    expect(JSON.parse(calls[2].text)).toMatchObject({ task_id: runeTask, member: "Rune", budget_mana: 20 });
    const status = JSON.parse(calls[3].text);
    expect(status.seal_left_mana).toBe(90);
    expect(status.subtasks.map((s: { member: string }) => s.member)).toEqual(["Quill", "Rune"]);
    const collected = JSON.parse(calls[4].text);
    expect(collected.all_finished).toBe(true);
    expect(collected.subtasks).toEqual([
      expect.objectContaining({ task_id: quillTask, member: "Quill", status: "done", summary: "Wrote docs.md.", files: ["docs.md"] }),
      expect.objectContaining({ task_id: runeTask, member: "Rune", status: "done", summary: "Wrote helper.txt and ran the tests.", files: ["helper.txt"] }),
    ]);

    // One review for the whole party; sub-tasks pay only through it, split 40/60.
    const direct = await c.send("accept_result", { task_id: quillTask, integrate: "merge" });
    expect(direct.error?.code).toBe("INVALID_STATE");
    const xp = (id: string) => town.ctx.agents.row(id).xp;
    const before = { lead: xp(lead), quill: xp(quill), rune: xp(rune) };
    const accepted = await c.ok("accept_result", { task_id: parentId, integrate: "merge" });
    const rp: number = accepted.rewards.rp;
    expect(rp).toBeGreaterThan(0);
    for (const id of [quillTask!, runeTask!]) {
      const done = await c.waitTask(id, "accepted");
      expect(done.payload.task.rewards).toMatchObject({ rp: 0, breakdown: { zero_reason: "party_subtask" } });
    }
    expect(xp(lead) - before.lead).toBe(Math.round(rp * 0.4));
    expect(xp(quill) - before.quill + (xp(rune) - before.rune)).toBe(rp - Math.round(rp * 0.4));
    expect(readFileSync(path.join(repos.lead!, "lead.txt"), "utf8")).toBe("The lead's part.\n");
    expect(readFileSync(path.join(repos.quill!, "docs.md"), "utf8")).toBe("# Docs\n");
    expect(existsSync(path.join(repos.rune!, "helper.txt"))).toBe(true);
  });

  it("stops waiting for the party when the party task is cancelled, and cancels the sub-tasks", async () => {
    scenarios({
      lead: {
        turns: [
          {
            steps: [
              { mcp_tool: "mcp__town__delegate", input: { member: "Quill", title: "Think hard", prompt: "Think about it for a long time." } },
              { mcp_tool: "mcp__town__collect_results", input: {} },
              { text: "unreachable" },
            ],
          },
        ],
      },
    });
    env.FAKE_CODEX_SCENARIO = writeJson(town.root, "codex-hang.json", { turns: [{ steps: [{ hang: true }] }] });
    const partyId = await formParty();
    const { task_id: parentId } = await c.ok("assign_task", {
      party_id: partyId,
      title: "Wait for the party",
      prompt: "[scenario:lead] Wait for the party.",
      size: "S",
      courier: { mode: "express" },
    });
    const delegated = await c.waitEvent((e) => e.type === "subtask_delegated" && e.payload.parent_task_id === parentId, 30_000);
    const childId: string = delegated.payload.task_id;
    await c.waitTask(childId, "running", 30_000);
    // The lead is now waiting inside collect_results.
    await c.waitEvent((e) => e.type === "task_progress" && e.payload.task_id === parentId && e.payload.phase === "delegating", 30_000);
    await c.ok("cancel_task", { task_id: parentId });
    await c.waitTask(parentId, "cancelled", 30_000);
    await c.waitTask(childId, "cancelled", 30_000);
    const collect = readLog(claudeLog).find((e) => e.kind === "mcp_call" && e.tool === "mcp__town__collect_results");
    // The wait ended with the run: the call returned (or the lead was stopped first), never hung.
    if (collect) expect(JSON.parse(collect.text).all_finished).toBe(false);
  });
});
