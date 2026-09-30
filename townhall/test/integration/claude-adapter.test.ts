import { existsSync, mkdirSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ClaudeCodeAdapter } from "../../src/providers/claude/adapter.js";
import type { ClaudeCheckpoint } from "../../src/providers/claude/run.js";
import type { RunRequest } from "../../src/providers/types.js";
import { removeRoot, tempRoot } from "../helpers/harness.js";
import { FIXTURES, MockHost, readLog, runRequest, testDeps, within, writeJson } from "../helpers/run-host.js";

const FAKE = path.join(FIXTURES, "fake-claude.mjs");

describe("ClaudeCodeAdapter against a fake Claude Code CLI", () => {
  let root: string;
  let work: string;
  let logFile: string;
  let env: Record<string, string | undefined>;

  beforeEach(() => {
    root = tempRoot("claude");
    work = path.join(root, "work");
    mkdirSync(work, { recursive: true });
    logFile = path.join(root, "fake-claude.log");
    env = {
      ...process.env,
      AURELHAVEN_CLAUDE_BIN: FAKE,
      FAKE_CLAUDE_HOME: path.join(root, "sessions"),
      FAKE_CLAUDE_LOG: logFile,
    };
  });

  afterEach(() => removeRoot(root));

  const adapter = () => new ClaudeCodeAdapter(testDeps(path.join(root, "data"), env));
  const scenario = (turns: unknown[]) => {
    env.FAKE_CLAUDE_SCENARIO = writeJson(root, `scenario-${Math.random().toString(36).slice(2)}.json`, { turns });
  };
  const start = (a: ClaudeCodeAdapter, host: MockHost, overrides: Partial<RunRequest> = {}) => a.start(runRequest(work, overrides), host);
  const starts = () => readLog(logFile).filter((e) => e.kind === "start");

  it("probes version and sign-in, and never throws when the CLI is missing", async () => {
    const info = await adapter().probe();
    expect(info).toMatchObject({ id: "claude", installed: true, version: "2.1.281", logged_in: true, billing_hint: "subscription" });
    expect(info.message).toBe("Claude Code 2.1.281, signed in with a Claude Max subscription");

    env.FAKE_CLAUDE_AUTH = "none";
    expect(await adapter().probe()).toMatchObject({ installed: true, logged_in: false });

    env = { PATH: "", AURELHAVEN_CLAUDE_BIN: path.join(root, "missing", "claude.exe") };
    const missing = await adapter().probe();
    expect(missing).toMatchObject({ installed: false, logged_in: false });
    expect(missing.message).toMatch(/AURELHAVEN_CLAUDE_BIN/);
  });

  it("lists models from the initialize control request, with prices from pricing.json", async () => {
    const models = await adapter().listModels();
    expect(models.map((m) => m.id)).toEqual(["default", "haiku"]);
    expect(models[0]!.default).toBe(true);
    expect(models[1]!.cost_hint).toBe("$1.00 in / $5.00 out per 1M tokens");
  });

  it("runs a task: the approve tool round trip, events, usage and the summary", async () => {
    scenario([
      {
        steps: [
          { text: "I will write the greeting." },
          { tool: "Write", input: { file_path: path.join(work, "hello.txt"), content: "hello\n" } },
          { cost: 0.0125 },
          { text: "Wrote hello.txt." },
        ],
      },
    ]);
    const a = adapter();
    await a.probe();
    const host = new MockHost();
    const outcome = await within(start(a, host).done);
    expect(outcome).toEqual({ kind: "completed", summary: "Wrote hello.txt." });
    expect(readFileSync(path.join(work, "hello.txt"), "utf8")).toBe("hello\n");

    expect(host.approvals).toHaveLength(1);
    expect(host.approvals[0]).toMatchObject({ tool: "Write", category: "write", summary: "Write: hello.txt" });
    const approvals = readLog(logFile).filter((e) => e.kind === "approval");
    expect(approvals).toEqual([expect.objectContaining({ tool: "Write", decision: expect.objectContaining({ behavior: "allow" }) })]);

    const kinds = host.events.map((e) => e.kind);
    expect(kinds).toContain("session");
    expect(host.events).toContainEqual(expect.objectContaining({ kind: "tool_start", tool: "Write", text: "Write: hello.txt" }));
    expect(host.events).toContainEqual(expect.objectContaining({ kind: "tool_end", tool: "Write", ok: true }));
    expect(host.events).toContainEqual({ kind: "files_touched", paths: ["hello.txt"] });
    expect(host.events).toContainEqual({ kind: "usage", costMicros: 12_500, estimate: true });
    expect(host.texts("activity")).toContain("I will write the greeting.");

    const [first] = starts();
    const argv: string[] = first!.argv;
    const at = (f: string) => argv[argv.indexOf(f) + 1];
    expect(argv.slice(0, 7)).toEqual(["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--setting-sources"]);
    expect(at("--setting-sources")).toBe("");
    expect(JSON.parse(at("--settings")!)).toEqual({ permissions: { ask: ["*"] } });
    expect(at("--permission-prompt-tool")).toBe("mcp__aurelhaven__approve");
    expect(at("--permission-mode")).toBe("manual");
    expect(at("--tools")).toBe("Read,Glob,Grep,Edit,Write");
    expect(at("--model")).toBe("haiku");
    expect(argv).toContain("--strict-mcp-config");
    expect(argv).toContain("--session-id");
    expect(Number(at("--max-budget-usd"))).toBeCloseTo(0.45, 3);
    // The approval secret travels only in the per-run MCP config, never on the command line.
    const config = readLog(logFile).find((e) => e.kind === "mcp_config")!.servers.aurelhaven;
    expect(config.env.AURELHAVEN_APPROVAL_URL).toMatch(/^http:\/\/127\.0\.0\.1:\d+\/approve$/);
    expect(argv.join(" ")).not.toContain(config.env.AURELHAVEN_APPROVAL_TOKEN);
    expect(first!.envNames).not.toContain("AURELHAVEN_APPROVAL_TOKEN");
    expect(first!.claudeMdsDisabled).toBe(true);
    // The session is checkpointed for resume.
    const cp = host.lastCheckpoint<ClaudeCheckpoint>();
    expect(cp).toMatchObject({ harness: "claude", costSeenUsd: 0.0125, costSavedUsd: 0.0125 });
    expect(host.events).toContainEqual({ kind: "session", sessionId: cp.sessionId });
    // The per-run scratch folder is removed.
    expect(existsSync(path.join(root, "data", "harness", "claude"))).toBe(true);
    expect(readdirCount(path.join(root, "data", "harness", "claude"))).toBe(0);
  });

  it("sends the player's denial back to the agent, which carries on", async () => {
    scenario([
      {
        steps: [
          { tool: "Bash", input: { command: "git push --force origin main" } },
          { text: "I will not push." },
        ],
      },
    ]);
    const host = new MockHost();
    host.decide = () => ({ decision: "deny", message: "Never push" });
    const outcome = await within(start(adapter(), host, { tools: ["lectern", "forge"] }).done);
    expect(outcome).toEqual({ kind: "completed", summary: "I will not push." });
    expect(host.approvals[0]).toMatchObject({ tool: "Bash", category: "command", risk: "high", summary: "Run: git push --force origin main" });
    expect(host.events).toContainEqual(expect.objectContaining({ kind: "tool_end", tool: "Bash", ok: false }));
    const approval = readLog(logFile).find((e) => e.kind === "approval")!;
    expect(approval.decision).toEqual({ behavior: "deny", message: "The player denied this: Never push" });
    const argv: string[] = starts()[0]!.argv;
    expect(argv[argv.indexOf("--tools") + 1]).toBe("Read,Glob,Grep,Bash");
  });

  it("charges usage as deltas of Claude's running total across turns and nudges", async () => {
    scenario([
      { steps: [{ cost: 0.01 }, { sleep: 300 }, { text: "First pass done." }] },
      { steps: [{ cost: 0.005 }, { text: "Added the nudge." }] },
    ]);
    const host = new MockHost();
    const run = start(adapter(), host);
    await host.waitFor((e) => e.kind === "session");
    run.send("Also add a comment");
    const outcome = await within(run.done);
    expect(outcome).toEqual({ kind: "completed", summary: "Added the nudge." });
    const usage = host.events.filter((e) => e.kind === "usage").map((e) => (e.kind === "usage" ? e.costMicros : 0));
    expect(usage).toEqual([10_000, 5_000]);
    const messages = readLog(logFile).filter((e) => e.kind === "message").map((e) => e.text as string);
    expect(messages[1]).toBe("Message from the player: Also add a comment");
  });

  it("interrupts with the documented control request and reports interrupted", async () => {
    scenario([{ steps: [{ text: "Thinking for a long time." }, { hang: true }] }]);
    const host = new MockHost();
    const run = start(adapter(), host);
    await host.waitFor((e) => e.kind === "activity");
    run.interrupt();
    expect(await within(run.done)).toEqual({ kind: "interrupted" });
    expect(readLog(logFile).filter((e) => e.kind === "interrupt")).toEqual([expect.objectContaining({ cancel_queued: true })]);
    // The clean exit saved the session, so a resume restores its cost total.
    expect(readLog(logFile).some((e) => e.kind === "exit")).toBe(true);
  });

  it("kills the process tree on kill()", async () => {
    scenario([{ steps: [{ hang: true }] }]);
    const host = new MockHost();
    const run = start(adapter(), host);
    await host.waitFor((e) => e.kind === "session");
    const pid = starts()[0]!.pid as number;
    run.kill();
    expect(await within(run.done)).toEqual({ kind: "interrupted" });
    expect(alive(pid)).toBe(false);
    expect(readLog(logFile).some((e) => e.kind === "exit")).toBe(false);
  });

  it("leaves no orphans when killed while an approval is pending", async () => {
    scenario([{ steps: [{ tool: "Write", input: { file_path: "b.txt", content: "b" } }] }]);
    const host = new MockHost();
    host.decide = () => new Promise(() => undefined);
    const run = start(adapter(), host);
    await host.waitApprovals(1);
    const claudePid = starts()[0]!.pid as number;
    const mcpPid = readLog(logFile).find((e) => e.kind === "mcp_started")!.pid as number;
    expect(alive(mcpPid)).toBe(true);
    run.kill();
    expect(await within(run.done)).toEqual({ kind: "interrupted" });
    expect(alive(claudePid)).toBe(false);
    await waitUntil(() => !alive(mcpPid));
    expect(alive(mcpPid)).toBe(false);
  });

  it("withdraws a pending approval when the run stops: deny with interrupt", async () => {
    scenario([{ steps: [{ tool: "Write", input: { file_path: "a.txt", content: "a" } }, { text: "unreachable" }] }]);
    const host = new MockHost();
    let release: (() => void) | null = null;
    host.decide = () =>
      new Promise((resolve) => {
        release = () => resolve({ decision: "deny", cancelled: true });
      });
    const run = start(adapter(), host);
    await host.waitApprovals(1);
    run.interrupt();
    release!();
    expect(await within(run.done)).toEqual({ kind: "interrupted" });
    const approval = readLog(logFile).find((e) => e.kind === "approval")!;
    expect(approval.decision).toMatchObject({ behavior: "deny", interrupt: true });
    expect(existsSync(path.join(work, "a.txt"))).toBe(false);
  });

  it("resumes the session with the feedback first, without charging the restored total again", async () => {
    scenario([{ steps: [{ cost: 0.02 }, { text: "Version one." }] }]);
    const firstHost = new MockHost();
    await within(start(adapter(), firstHost).done);
    const cp = firstHost.lastCheckpoint<ClaudeCheckpoint>();
    expect(cp.costSavedUsd).toBeCloseTo(0.02, 6);

    scenario([{ steps: [{ cost: 0.003 }, { text: "Version two." }] }]);
    const host = new MockHost();
    const outcome = await within(
      start(adapter(), host, { attempt: 2, resume: { sessionId: cp.sessionId, state: cp, feedback: "Use a warmer greeting" } }).done,
    );
    expect(outcome).toEqual({ kind: "completed", summary: "Version two." });
    const argv: string[] = starts()[1]!.argv;
    expect(argv[argv.indexOf("--resume") + 1]).toBe(cp.sessionId);
    expect(argv).not.toContain("--session-id");
    // The cap applies to Claude Code's running total, which starts from the restored $0.02.
    expect(Number(argv[argv.indexOf("--max-budget-usd") + 1])).toBeCloseTo(0.47, 4);
    const messages = readLog(logFile).filter((e) => e.kind === "message").map((e) => e.text as string);
    expect(messages[1]).toMatch(/^The player reviewed your work on this task and sent it back with this feedback:\n\nUse a warmer greeting/);
    expect(host.usageMicros()).toBe(3_000);
  });

  it("after a kill, charges the resumed run from the total Claude Code actually restores", async () => {
    scenario([{ steps: [{ cost: 0.01 }, { sleep: 400 }, { text: "Part one." }] }, { steps: [{ hang: true }] }]);
    const host = new MockHost();
    const run = start(adapter(), host);
    await host.waitFor((e) => e.kind === "session");
    run.send("Keep going");
    await host.waitFor((e) => e.kind === "usage");
    await waitUntil(() => readLog(logFile).filter((e) => e.kind === "message").length >= 2);
    run.kill();
    expect(await within(run.done)).toEqual({ kind: "interrupted" });
    const cp = host.lastCheckpoint<ClaudeCheckpoint>();
    // Killed: nothing was saved, so the session will restore the total it started with.
    expect(cp).toMatchObject({ costSeenUsd: 0.01, costSavedUsd: 0 });

    scenario([{ steps: [{ cost: 0.004 }, { text: "Resumed." }] }]);
    const resumed = new MockHost();
    await within(start(adapter(), resumed, { resume: { sessionId: cp.sessionId, state: cp, feedback: null } }).done);
    expect(host.usageMicros()).toBe(10_000);
    expect(resumed.usageMicros()).toBe(4_000);
  });

  it("starts a new session when the old one cannot be resumed", async () => {
    scenario([{ steps: [{ text: "Fresh start." }] }]);
    const host = new MockHost();
    const outcome = await within(
      start(adapter(), host, { resume: { sessionId: "11111111-2222-3333-4444-555555555555", state: null, feedback: "Try again" } }).done,
    );
    expect(outcome).toEqual({ kind: "completed", summary: "Fresh start." });
    expect(host.texts("activity").some((t) => t.includes("could not be resumed"))).toBe(true);
    const [failed, fresh] = starts();
    expect(failed!.argv).toContain("--resume");
    expect(fresh!.argv).toContain("--session-id");
    const message = readLog(logFile).find((e) => e.kind === "message")!.text as string;
    expect(message).toMatch(/^Write hello\.txt\n\nThe player reviewed an earlier attempt/);
  });

  it("passes Waygates as MCP servers with environment references, never the secret values", async () => {
    scenario([{ steps: [{ text: "Connected." }] }]);
    env.GH_TOKEN = "ghp_secretvalue1234567890abcdefgh";
    env.GH_AUTH_HEADER = "Bearer secret-header-value";
    const host = new MockHost();
    await within(
      start(adapter(), host, {
        tools: ["lectern", "quillworks", "waygate", "archive"],
        waygates: [
          { server_name: "github", transport: "stdio", command: "node", args: ["gh-mcp.js"], env_refs: ["GH_TOKEN"], allowed_tools: ["search"] },
          { server_name: "docs", transport: "http", url: "https://mcp.example.invalid/mcp", header_refs: { Authorization: "GH_AUTH_HEADER" } },
          { server_name: "aurelhaven", transport: "stdio", command: "node" },
        ],
      }).done,
    );
    const servers = readLog(logFile).find((e) => e.kind === "mcp_config")!.servers;
    expect(servers.github).toEqual({ type: "stdio", command: "node", args: ["gh-mcp.js"], env: { GH_TOKEN: "${GH_TOKEN}" } });
    expect(servers.docs).toEqual({ type: "http", url: "https://mcp.example.invalid/mcp", headers: { Authorization: "${GH_AUTH_HEADER}" } });
    expect(servers.aurelhaven.args[0]).toMatch(/approval-mcp\.mjs$/);
    const everything = readFileSync(logFile, "utf8");
    expect(everything).not.toContain("secretvalue");
    expect(everything).not.toContain("secret-header-value");
    expect(host.texts("activity").some((t) => t.includes("Waygate aurelhaven was skipped"))).toBe(true);
    expect(starts()[0]!.claudeMdsDisabled).toBe(false);
  });

  it("refuses the approval tool itself and Waygate tools outside allowed_tools, without asking", async () => {
    scenario([
      {
        steps: [
          { tool: "mcp__aurelhaven__approve", input: { tool_name: "Bash", input: { command: "rm -rf /" } } },
          { tool: "mcp__docs_site__search", input: { q: "x" } },
          { tool: "mcp__docs_site__lookup", input: { q: "y" } },
          { text: "Done." },
        ],
      },
    ]);
    const host = new MockHost();
    const outcome = await within(
      start(adapter(), host, {
        tools: ["lectern", "waygate"],
        waygates: [{ server_name: "docs.site", transport: "http", url: "https://mcp.example.invalid/mcp", allowed_tools: ["lookup"] }],
      }).done,
    );
    expect(outcome).toEqual({ kind: "completed", summary: "Done." });
    expect(host.approvals.map((r) => r.tool)).toEqual(["mcp__docs_site__lookup"]);
    const decisions = readLog(logFile).filter((e) => e.kind === "approval").map((e) => [e.tool, e.decision.behavior, e.decision.message]);
    expect(decisions).toEqual([
      ["mcp__aurelhaven__approve", "deny", "This tool belongs to the Town Hall and is not available to agents."],
      ["mcp__docs_site__search", "deny", "The docs_site Waygate does not allow the tool search."],
      ["mcp__docs_site__lookup", "allow", undefined],
    ]);
    // Claude Code's name for the server, as it appears in tool names.
    expect(Object.keys(readLog(logFile).find((e) => e.kind === "mcp_config")!.servers)).toEqual(["aurelhaven", "docs_site"]);
  });

  it("denies, and carries on, when the Town Hall cannot ask the player", async () => {
    scenario([{ steps: [{ tool: "Write", input: { file_path: "c.txt", content: "c" } }, { text: "Could not write." }] }]);
    const host = new MockHost();
    host.decide = () => {
      throw new Error("the database is gone");
    };
    const run = start(adapter(), host);
    expect(await within(run.done)).toEqual({ kind: "completed", summary: "Could not write." });
    const approval = readLog(logFile).find((e) => e.kind === "approval")!;
    expect(approval.decision).toEqual({ behavior: "deny", message: "The Town Hall could not ask the player about this action." });
    expect(existsSync(path.join(work, "c.txt"))).toBe(false);
    // A nudge after the run ended cannot reach the agent: the player is told so.
    run.send("Too late");
    await host.waitFor((e) => e.kind === "activity" && e.text.includes("not delivered"));
  });

  it("uses plan mode for plan_first and adds ExitPlanMode", async () => {
    scenario([{ steps: [{ text: "Here is my plan." }] }]);
    await within(start(adapter(), new MockHost(), { approvalMode: "plan_first" }).done);
    const argv: string[] = starts()[0]!.argv;
    expect(argv[argv.indexOf("--permission-mode") + 1]).toBe("plan");
    expect(argv[argv.indexOf("--tools") + 1]).toBe("Read,Glob,Grep,Edit,Write,ExitPlanMode");
  });

  it("reports rate limits as a provider limit", async () => {
    scenario([{ steps: [{ error: "rate_limit", error_text: "Claude AI usage limit reached|1790700000" }] }]);
    const outcome = await within(start(adapter(), new MockHost()).done);
    expect(outcome).toMatchObject({ kind: "failed", error: { code: "provider_limit", transient: true } });
  });
});

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitUntil(pred: () => boolean, ms = 5_000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!pred() && Date.now() < deadline) await new Promise((r) => setTimeout(r, 100));
}

function readdirCount(dir: string): number {
  try {
    return readdirSync(dir).length;
  } catch {
    return 0;
  }
}
