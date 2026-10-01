import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { Economy } from "../../src/core/economy.js";
import { defaultEconomyPath, defaultPricingPath, srcPath } from "../../src/paths.js";
import { ClaudeCodeAdapter } from "../../src/providers/claude/adapter.js";
import { FakeProvider } from "../../src/providers/fake/adapter.js";
import { ScenarioLibrary } from "../../src/providers/fake/scenarios.js";
import { harnessDeps } from "../../src/providers/real.js";
import { makeRepo } from "../helpers/git.js";
import { summonAgent, TestTown, type Ev } from "../helpers/harness.js";
import { publish, SMOKE_CAP_MICROS } from "./smoke-helpers.js";

/** The whole party works within this seal: 9 Mana ($0.09), so overshoot stays under the $0.10 cap. */
const PARTY_SEAL_MANA = 9;
const MEMBER_BUDGET_MANA = 4;

// Opt-in: a real party on the installed Claude Code, Haiku 4.5 for the lead and the member (real,
// paid model calls). The lead delegates with the town tools, the member writes its file, the lead
// collects the result and writes its own. Codex and pi are not run (scripted stand-ins only).
describe.skipIf(process.env.AURELHAVEN_SMOKE_PARTY !== "1")("smoke: a Claude Code party", () => {
  it("delegates through the town tools, collects the member's result, and stays under the cap", async () => {
    const started = Date.now();
    const town = await TestTown.start("smoke-party", {
      adapters: ({ dataDir }) => {
        const deps = harnessDeps({ econ: Economy.load(defaultEconomyPath()).data, dataDir, pricingPath: defaultPricingPath(), env: process.env });
        const library = new ScenarioLibrary(srcPath("providers", "fake", "scenarios"));
        const fake = (id: "codex" | "pi") => new FakeProvider(id, { library, defaultScenario: "basic", microsPerMana: 10_000 });
        return { claude: new ClaudeCodeAdapter(deps), codex: fake("codex"), pi: fake("pi") };
      },
    });
    const c = await town.client();
    try {
      const providers = (await c.ok("get_state")).providers as Array<{ id: string; installed: boolean; logged_in: boolean; version?: string }>;
      const claude = providers.find((p) => p.id === "claude")!;
      expect(claude).toMatchObject({ installed: true, logged_in: true });

      town.ctx.db.tx(() => town.ctx.settings.setState("age", { current: 2, research: null }));
      town.ctx.treasury.credit({ food: 2000, wood: 2000, stone: 2000, gold: 2000 }, "reward", "reward", null, "smoke-party");
      const leadRepo = makeRepo(town.work, "lead");
      const memberRepo = makeRepo(town.work, "member");
      const tools = ["lectern", "quillworks"];
      const lead = await summonAgent(c, { name: "Mira", provider: "claude", model: "haiku", workspace: leadRepo, tools, tile: { x: 40, y: 52 } });
      const member = await summonAgent(c, { name: "Rune", provider: "claude", model: "haiku", workspace: memberRepo, tools, tile: { x: 60, y: 52 } });
      town.ctx.db.tx(() => {
        town.ctx.db.run("UPDATE agents SET xp = 150, stats_json = json_set(stats_json, '$.accepted', 2) WHERE id = ?", [lead]);
        town.ctx.agents.recomputeRank(lead);
      });
      const { party_id: partyId } = await c.ok("form_party", { lead_agent_id: lead, member_ids: [member] });

      // Any card that does come up: reads and writes are allowed, anything else is denied.
      const answered: Array<{ agent: string; tool: string; category: string; decision: string }> = [];
      c.ws.on("message", (data) => {
        const ev = JSON.parse(data.toString()) as Ev;
        if (ev.type !== "approval_requested") return;
        const a = ev.payload.approval as { id: string; agent_id: string; tool: string; category: string };
        const decision = a.category === "read" || a.category === "write" ? "allow" : "deny";
        answered.push({ agent: a.agent_id === lead ? "lead" : "member", tool: a.tool, category: a.category, decision });
        void c.send("respond_approval", { approval_id: a.id, decision, scope: "once" });
      });

      const { task_id: parentId } = await c.ok("assign_task", {
        party_id: partyId,
        title: "Party smoke test",
        prompt: [
          "Do exactly these steps, with as few tool calls as possible:",
          `1. Call mcp__town__delegate with member "Rune", title "Write member.txt", budget_mana ${MEMBER_BUDGET_MANA}, and prompt: "Create a file named member.txt in your current folder whose whole content is the two words 'from the member' (no period, no newline). Do nothing else, then reply with one short sentence."`,
          `2. Create a file named lead.txt in your current folder whose whole content is "from the lead" (no period, no newline).`,
          "3. Call mcp__town__collect_results once.",
          "4. Reply with one short sentence.",
        ].join("\n"),
        size: "S",
        seal_mana: PARTY_SEAL_MANA,
        courier: { mode: "express" },
      });

      const delegated = await c.waitEvent((e) => e.type === "subtask_delegated" && e.payload.parent_task_id === parentId, 300_000, "the delegation");
      const childId: string = delegated.payload.task_id;
      const end = (id: string) => (e: Ev) =>
        e.type === "task_updated" && e.payload.task.id === id && ["awaiting_review", "failed", "paused", "cancelled"].includes(e.payload.task.state);
      const child = await c.waitEvent(end(childId), 600_000, "the member's result");
      const parent = await c.waitEvent(end(parentId), 600_000, "the lead's result");

      const p = town.ctx.tasks.row(parentId);
      const k = town.ctx.tasks.row(childId);
      const ws = (id: string) => town.ctx.tasks.workspaceOf(town.ctx.tasks.row(id))!.worktree;
      const read = (file: string) => (existsSync(file) ? readFileSync(file, "utf8") : null);
      const activity = (id: string) =>
        town.ctx.db.all<{ kind: string; text: string }>("SELECT kind, text FROM task_events WHERE task_id = ? ORDER BY id", [id]).map((e) => `${e.kind}: ${e.text}`);
      const report = {
        claudeVersion: claude.version,
        model: "haiku",
        seconds: Math.round((Date.now() - started) / 1000),
        parent: { state: parent.payload.task.state, reason: p.state_reason, summary: parent.payload.task.result?.summary ?? null, seal_micros: p.seal_micros, spent_micros: p.spent_micros, estimate: p.spent_is_estimate === 1, session: p.session_id },
        member: { state: child.payload.task.state, reason: k.state_reason, summary: child.payload.task.result?.summary ?? null, seal_micros: k.seal_micros, spent_micros: k.spent_micros, estimate: k.spent_is_estimate === 1, session: k.session_id },
        totalMicros: p.spent_micros + k.spent_micros,
        files: { lead: read(path.join(ws(parentId), "lead.txt")), member: read(path.join(ws(childId), "member.txt")) },
        approvals: answered,
        leadActivity: activity(parentId),
        memberActivity: activity(childId),
        worktrees: { lead: ws(parentId), member: ws(childId) },
      };
      publish("party", report);

      expect(delegated.payload).toMatchObject({ from_agent_id: lead, to_agent_id: member });
      expect(k.seal_micros).toBe(MEMBER_BUDGET_MANA * 10_000);
      // The model's wording is not the point: a stray full stop is fine.
      const words = (s: string | null) => s?.trim().replace(/[.!]+$/, "");
      expect(report.member.state).toBe("awaiting_review");
      expect(words(report.files.member)).toBe("from the member");
      expect(report.parent.state).toBe("awaiting_review");
      expect(words(report.files.lead)).toBe("from the lead");
      expect(report.leadActivity.some((t) => t.includes("collect_results"))).toBe(true);
      // The town tools never became cards.
      expect(answered.some((a) => a.tool.startsWith("mcp__town__"))).toBe(false);
      expect(report.totalMicros).toBeGreaterThan(0);
      expect(report.totalMicros).toBeLessThanOrEqual(SMOKE_CAP_MICROS);
    } finally {
      await c.close();
      await town.stop();
    }
  });
});
