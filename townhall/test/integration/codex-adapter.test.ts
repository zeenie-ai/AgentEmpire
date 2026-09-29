import { existsSync, mkdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { CodexCliAdapter } from "../../src/providers/codex/adapter.js";
import type { CodexCheckpoint } from "../../src/providers/codex/run.js";
import type { RunRequest } from "../../src/providers/types.js";
import { removeRoot, tempRoot } from "../helpers/harness.js";
import { FIXTURES, MockHost, readLog, runRequest, testDeps, within, writeJson } from "../helpers/run-host.js";

const FAKE = path.join(FIXTURES, "fake-codex.mjs");

describe("CodexCliAdapter against a fake codex app-server", () => {
  let root: string;
  let work: string;
  let logFile: string;
  let env: Record<string, string | undefined>;

  beforeEach(() => {
    root = tempRoot("codex");
    work = path.join(root, "work");
    mkdirSync(work, { recursive: true });
    logFile = path.join(root, "fake-codex.log");
    env = { ...process.env, AURELHAVEN_CODEX_BIN: FAKE, FAKE_CODEX_HOME: path.join(root, "threads"), FAKE_CODEX_LOG: logFile };
  });

  afterEach(() => removeRoot(root));

  const adapter = () => new CodexCliAdapter(testDeps(path.join(root, "data"), env));
  const scenario = (turns: unknown[], extra: Record<string, unknown> = {}) => {
    env.FAKE_CODEX_SCENARIO = writeJson(root, `scenario-${Math.random().toString(36).slice(2)}.json`, { turns, ...extra });
  };
  const start = (a: CodexCliAdapter, host: MockHost, overrides: Partial<RunRequest> = {}) =>
    a.start(runRequest(work, { provider: "codex", model: "gpt-5.6-luna", tools: ["lectern", "quillworks", "forge"], ...overrides }), host);
  const log = () => readLog(logFile);
  const requests = (method: string) => log().filter((e) => e.kind === "request" && e.method === method);
  const approvals = () => log().filter((e) => e.kind === "approval");

  it("probes the version and the sign-in method, and never throws when the CLI is missing", async () => {
    expect(await adapter().probe()).toMatchObject({ id: "codex", installed: true, version: "0.144.2", logged_in: true, billing_hint: "subscription" });
    env.FAKE_CODEX_AUTH = "api";
    const api = await adapter().probe();
    expect(api).toMatchObject({ logged_in: true, billing_hint: "api_key" });
    expect(api.message).not.toMatch(/sk-proj/);
    env.FAKE_CODEX_AUTH = "none";
    expect(await adapter().probe()).toMatchObject({ installed: true, logged_in: false });
    env = { PATH: "", APPDATA: path.join(root, "nowhere"), AURELHAVEN_CODEX_BIN: "" };
    expect(await adapter().probe()).toMatchObject({ installed: false, logged_in: false });
  });

  it("lists models with model/list, hiding hidden ones and pricing from pricing.json", async () => {
    const models = await adapter().listModels();
    expect(models.map((m) => m.id)).toEqual(["gpt-5.6-sol", "gpt-5.6-luna"]);
    expect(models[0]!.default).toBe(true);
    expect(models[1]!.cost_hint).toBe("$0.20 in / $1.20 out per 1M tokens");
  });

  it("runs a turn: file and command approvals, priced usage, summary", async () => {
    scenario([
      {
        steps: [
          { patch: [{ path: "hello.txt", content: "hello\n" }] },
          { command: "npm test", exitCode: 0 },
          { tokens: { input: 1_000_000, cached: 400_000, output: 100_000 } },
          { text: "Added hello.txt and ran the tests." },
        ],
      },
    ]);
    const a = adapter();
    await a.probe();
    const host = new MockHost();
    const outcome = await within(start(a, host).done);
    expect(outcome).toEqual({ kind: "completed", summary: "Added hello.txt and ran the tests." });
    expect(readFileSync(path.join(work, "hello.txt"), "utf8")).toBe("hello\n");

    expect(host.approvals.map((r) => [r.tool, r.category, r.summary])).toEqual([
      ["apply_patch", "write", "Edit: hello.txt"],
      ["shell", "command", "Run: npm test"],
    ]);
    expect((host.approvals[0]!.input as { path: string }).path).toBe(path.join(work, "hello.txt"));
    expect(approvals().map((e) => e.response.result.decision)).toEqual(["accept", "accept"]);
    expect(host.events).toContainEqual({ kind: "files_touched", paths: ["hello.txt"] });
    expect(host.events).toContainEqual(expect.objectContaining({ kind: "tool_end", tool: "shell", ok: true }));
    // gpt-5.6-luna: 600k input at $0.20, 400k cached at $0.02, 100k output at $1.20 per 1M.
    expect(host.events).toContainEqual({ kind: "usage", costMicros: 248_000, inputTokens: 1_000_000, outputTokens: 100_000, estimate: true });

    const [thread] = requests("thread/start");
    expect(thread!.params).toMatchObject({ cwd: work, approvalPolicy: "untrusted", sandbox: "workspace-write", model: "gpt-5.6-luna", ephemeral: false });
    expect(thread!.params.developerInstructions).toMatch(/^# Aurelhaven/);
    expect(thread!.params.config).toEqual({ projects: { [work]: { trust_level: "untrusted" } } });
    const overrides: string[] = log().find((e) => e.kind === "start")!.overrides;
    expect(overrides).toEqual(expect.arrayContaining(["features.apps=false", "features.plugins=false", "features.multi_agent=false", 'web_search="disabled"', "project_doc_max_bytes=0"]));
    const cp = host.lastCheckpoint<CodexCheckpoint>();
    expect(cp).toEqual({
      v: 1,
      harness: "codex",
      threadId: expect.stringMatching(/^thr_/),
      tokens: { inputTokens: 1_000_000, cachedInputTokens: 400_000, outputTokens: 100_000 },
    });
    expect(host.events).toContainEqual({ kind: "session", sessionId: cp.threadId });
  });

  it("declines what the player denies and refuses commands without a Forge", async () => {
    scenario([
      { steps: [{ command: "rm -rf build" }, { patch: [{ path: "no.txt", content: "x" }] }, { text: "Stopped." }] },
      { steps: [{ command: "npm install" }, { text: "No Forge." }] },
    ]);
    const host = new MockHost();
    host.decide = (r) => ({ decision: "deny", message: r.tool === "shell" ? "No deleting" : "No writing" });
    expect(await within(start(adapter(), host).done)).toEqual({ kind: "completed", summary: "Stopped." });
    expect(host.approvals[0]).toMatchObject({ tool: "shell", risk: "high" });
    expect(approvals().map((e) => e.response.result.decision)).toEqual(["decline", "decline"]);
    expect(existsSync(path.join(work, "no.txt"))).toBe(false);
    expect(host.events).toContainEqual(expect.objectContaining({ kind: "tool_end", tool: "apply_patch", ok: false }));

    const noForge = new MockHost();
    scenario([{ steps: [{ command: "npm install" }, { text: "No Forge." }] }]);
    expect(await within(start(adapter(), noForge, { tools: ["lectern", "quillworks"] }).done)).toEqual({ kind: "completed", summary: "No Forge." });
    expect(noForge.approvals).toHaveLength(0);
    expect(noForge.texts("activity").some((t) => t.includes("no Forge"))).toBe(true);
    expect(approvals().at(-1)!.response.result.decision).toBe("decline");
  });

  it("maps network and MCP approvals to their categories", async () => {
    scenario([
      {
        steps: [
          { command: "curl https://example.org", network: true },
          { mcp: { server: "github", tool: "create_issue", params: { title: "Bug" } } },
          { text: "Done." },
        ],
      },
    ]);
    const host = new MockHost();
    host.decide = (r) => ({ decision: r.category === "mcp" ? "deny" : "allow" });
    await within(start(adapter(), host).done);
    expect(host.approvals.map((r) => [r.tool, r.category])).toEqual([
      ["shell", "network"],
      ["mcp__github__create_issue", "mcp"],
    ]);
    // The host goes in as a URL, so an answer for the task or the agent covers that host only.
    expect(host.approvals[0]!.input).toMatchObject({ command: "curl https://example.org", url: "https://example.org" });
    expect(host.approvals[0]!.summary).toBe("Network access to example.org for: curl https://example.org");
    expect(host.approvals[0]!.risk).toBeUndefined();
    expect(host.approvals[1]!.input).toEqual({ title: "Bug" });
    expect(approvals()[1]!.response.result).toEqual({ action: "decline", content: null, _meta: null });
  });

  it("asks about an MCP tool named in a request for user input, and a command known only from its item", async () => {
    scenario([
      {
        steps: [
          { userInput: { server: "github", tool: "create_issue", params: { title: "Bug" } } },
          { command: "npm run build", omitCommand: true },
          { text: "Done." },
        ],
      },
    ]);
    const host = new MockHost();
    host.decide = (r) => ({ decision: r.category === "mcp" ? "allow" : "deny" });
    await within(start(adapter(), host).done);
    expect(host.approvals.map((r) => [r.tool, r.category, r.risk])).toEqual([
      ["mcp__github__create_issue", "mcp", undefined],
      ["shell", "command", undefined],
    ]);
    expect(host.approvals[0]!.input).toEqual({ title: "Bug" });
    expect(host.approvals[1]!.input).toMatchObject({ command: "npm run build", cwd: work });
    const [input, command] = approvals();
    expect(Object.values(input!.response.result.answers)).toEqual([{ answers: ["Allow"] }]);
    expect(command!.response.result.decision).toBe("decline");
  });

  it("grants only the permissions it understood, asking with the strictest category", async () => {
    const special = (kind: string) => ({ path: { type: "special", value: { kind } }, access: "write" });
    scenario([
      {
        steps: [
          { permissions: { network: { enabled: true }, fileSystem: null } },
          { permissions: { network: null, fileSystem: { read: null, write: null, entries: [special("root")] } } },
          { permissions: { network: { enabled: true }, fileSystem: { read: ["docs"], write: null } } },
          { permissions: { network: null, fileSystem: { read: null, write: null, entries: [{ path: { type: "path", path: "src" }, access: "write" }] } } },
          { permissions: { network: null, fileSystem: { read: null, write: null, entries: [{ path: { type: "mystery" }, access: "write" }] } } },
          { permissions: { network: null, fileSystem: null, somethingNew: { enabled: true } } },
          { text: "Done." },
        ],
      },
    ]);
    const host = new MockHost();
    const outcome = await within(start(adapter(), host).done);
    expect(outcome).toEqual({ kind: "completed", summary: "Done." });
    expect(host.approvals.map((r) => [r.tool, r.category, r.risk])).toEqual([
      ["network_access", "network", undefined],
      ["file_access", "outside_workspace", undefined],
      ["permissions", "network", "high"],
      ["file_access", "write", undefined],
    ]);
    expect(host.approvals[1]!.summary).toBe("Allow write access to the whole file system for this turn");
    expect(host.approvals[2]!.summary).toBe("Allow network access and read access to docs for this turn");
    const answers = approvals().map((e) => e.response.result);
    expect(answers).toEqual([
      { permissions: { network: { enabled: true } }, scope: "turn" },
      { permissions: { fileSystem: { read: null, write: null, entries: [special("root")] } }, scope: "turn" },
      { permissions: { network: { enabled: true }, fileSystem: { read: ["docs"], write: null } }, scope: "turn" },
      { permissions: { fileSystem: { read: null, write: null, entries: [{ path: { type: "path", path: "src" }, access: "write" }] } }, scope: "turn" },
      // Not understood: declined without a grant, and without asking the player.
      { permissions: {}, scope: "turn" },
      { permissions: {}, scope: "turn" },
    ]);
    expect(host.texts("activity").filter((t) => t.includes("does not understand"))).toHaveLength(2);
  });

  it("refuses file edits and write permissions without a Quillworks, and edits it cannot see", async () => {
    scenario([
      {
        steps: [
          { patch: [{ path: "no.txt", content: "x" }] },
          { permissions: { network: null, fileSystem: { read: null, write: ["src"] } } },
          { text: "Read only." },
        ],
      },
    ]);
    const host = new MockHost();
    await within(start(adapter(), host, { tools: ["lectern", "forge"] }).done);
    expect(host.approvals).toHaveLength(0);
    expect(approvals().map((e) => e.response.result)).toEqual([{ decision: "decline" }, { permissions: {}, scope: "turn" }]);
    expect(existsSync(path.join(work, "no.txt"))).toBe(false);
    expect(host.texts("activity").filter((t) => t.includes("no Quillworks"))).toHaveLength(2);

    scenario([{ steps: [{ patch: [{ path: "hidden.txt", content: "x" }], hidden: true }, { text: "Unseen." }] }]);
    const unseen = new MockHost();
    await within(start(adapter(), unseen).done);
    expect(unseen.approvals).toHaveLength(0);
    expect(approvals().at(-1)!.response.result).toEqual({ decision: "decline" });
    expect(existsSync(path.join(work, "hidden.txt"))).toBe(false);
  });

  it("treats a move out of the work folder as an outside-workspace edit", async () => {
    scenario([{ steps: [{ patch: [{ path: "inside.txt", content: "x", move: "../outside.txt" }] }, { text: "Moved." }] }]);
    const host = new MockHost();
    host.decide = () => ({ decision: "deny" });
    await within(start(adapter(), host).done);
    expect(host.approvals[0]).toMatchObject({ tool: "apply_patch", category: "outside_workspace" });
    expect((host.approvals[0]!.input as { path: string }).path).toBe(path.resolve(work, "../outside.txt"));
  });

  it("does not start a new turn for a nudge that fails to steer after a stop", async () => {
    scenario([{ steps: [{ text: "Long job." }, { hang: true }] }], { rejectSteer: true });
    const host = new MockHost();
    const run = start(adapter(), host);
    await host.waitFor((e) => e.kind === "activity");
    run.send("One more thing");
    run.interrupt();
    expect(await within(run.done)).toEqual({ kind: "interrupted" });
    expect(log().some((e) => e.kind === "steer_rejected")).toBe(true);
    expect(log().filter((e) => e.kind === "turn")).toHaveLength(1);
    run.send("Too late");
    await host.waitFor((e) => e.kind === "activity" && e.text.includes("not delivered"));
  });

  it("steers nudges into the running turn", async () => {
    scenario([{ steps: [{ text: "Working." }, { sleep: 400 }, { text: "Done with the nudge." }] }]);
    const host = new MockHost();
    const run = start(adapter(), host);
    await host.waitFor((e) => e.kind === "activity" && e.text === "Working.");
    run.send("Add a comment too");
    expect(await within(run.done)).toEqual({ kind: "completed", summary: "Done with the nudge." });
    expect(log().filter((e) => e.kind === "steer").map((e) => e.text)).toEqual(["Message from the player: Add a comment too"]);
  });

  it("interrupts with turn/interrupt and kills the process on kill()", async () => {
    scenario([{ steps: [{ text: "Long job." }, { hang: true }] }]);
    const host = new MockHost();
    const run = start(adapter(), host);
    await host.waitFor((e) => e.kind === "activity");
    run.interrupt();
    expect(await within(run.done)).toEqual({ kind: "interrupted" });
    expect(log().some((e) => e.kind === "interrupt")).toBe(true);

    scenario([{ steps: [{ hang: true }] }]);
    const killHost = new MockHost();
    const killed = start(adapter(), killHost);
    await killHost.waitFor((e) => e.kind === "session");
    const pid = log().filter((e) => e.kind === "start").at(-1)!.pid as number;
    killed.kill();
    expect(await within(killed.done)).toEqual({ kind: "interrupted" });
    expect(alive(pid)).toBe(false);
  });

  it("resumes the thread with the feedback first, charging only new tokens", async () => {
    scenario([{ steps: [{ tokens: { input: 100_000, output: 10_000 } }, { text: "First." }] }]);
    const firstHost = new MockHost();
    await within(start(adapter(), firstHost).done);
    const cp = firstHost.lastCheckpoint<CodexCheckpoint>();

    // Codex restates the restored figures (as on a rate-limit update) before the new request's.
    scenario([{ steps: [{ restate: true }, { tokens: { input: 50_000, output: 5_000 } }, { text: "Second." }] }]);
    const host = new MockHost();
    const outcome = await within(start(adapter(), host, { attempt: 2, resume: { sessionId: cp.threadId, state: cp, feedback: "Shorter please" } }).done);
    expect(outcome).toEqual({ kind: "completed", summary: "Second." });
    expect(requests("thread/resume")[0]!.params.threadId).toBe(cp.threadId);
    expect(log().filter((e) => e.kind === "turn").at(-1)!.text).toMatch(/sent it back with this feedback:\n\nShorter please/);
    // 50k input at $0.20 + 5k output at $1.20 per 1M; the restored thread total is not charged again.
    expect(host.usageMicros()).toBe(16_000);
    expect(host.lastCheckpoint<CodexCheckpoint>().tokens).toEqual({ inputTokens: 150_000, cachedInputTokens: 0, outputTokens: 15_000 });
  });

  it("starts a new thread when the old one is gone", async () => {
    scenario([{ steps: [{ text: "New thread." }] }]);
    const host = new MockHost();
    const outcome = await within(start(adapter(), host, { resume: { sessionId: "thr_missing", state: null, feedback: null } }).done);
    expect(outcome).toEqual({ kind: "completed", summary: "New thread." });
    expect(host.texts("activity").some((t) => t.includes("could not be resumed"))).toBe(true);
    expect(requests("thread/start")).toHaveLength(1);
    expect(log().find((e) => e.kind === "turn")!.text).toBe("Write hello.txt");
  });

  it("adds Waygates and web search through -c overrides that only name secrets", async () => {
    scenario([{ steps: [{ text: "Ok." }] }]);
    env.GH_TOKEN = "ghp_secretvalue1234567890abcdefgh";
    await within(
      start(adapter(), new MockHost(), {
        tools: ["lectern", "rookery", "waygate", "archive"],
        waygates: [{ server_name: "github", transport: "stdio", command: "node", args: ["gh.js"], env_refs: ["GH_TOKEN"] }],
      }).done,
    );
    const overrides: string[] = log().find((e) => e.kind === "start")!.overrides;
    expect(overrides).toEqual(
      expect.arrayContaining([
        'web_search="live"',
        'mcp_servers.github.command="node"',
        'mcp_servers.github.env_vars=["GH_TOKEN"]',
        'mcp_servers.github.default_tools_approval_mode="prompt"',
      ]),
    );
    expect(overrides).not.toContain("project_doc_max_bytes=0");
    expect(requests("thread/start")[0]!.params.sandbox).toBe("read-only");
    expect(readFileSync(logFile, "utf8")).not.toContain("secretvalue");
  });

  it("reports a usage limit as a provider limit", async () => {
    scenario([{ steps: [{ fail: "usageLimitExceeded", message: "You've hit your usage limit." }] }]);
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
