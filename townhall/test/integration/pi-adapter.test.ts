import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { bundledPiCli } from "../../src/providers/common/exec.js";
import { PiAdapter } from "../../src/providers/pi/adapter.js";
import { piSessionId, splitPiModel, type PiCheckpoint } from "../../src/providers/pi/run.js";
import type { RunRequest } from "../../src/providers/types.js";
import { removeRoot, tempRoot } from "../helpers/harness.js";
import { FIXTURES, MockHost, readLog, runRequest, testDeps, within, writeJson } from "../helpers/run-host.js";

const FAUX = path.join(FIXTURES, "pi-faux-provider.mjs");
const PI_CLI = bundledPiCli();

// These tests run the real pi (the version pinned in package.json) in RPC mode with a scripted
// faux model provider: no network, no credentials, no cost.
describe.skipIf(!PI_CLI)("PiAdapter against the real pi with a faux provider", () => {
  let root: string;
  let work: string;
  let fauxLog: string;
  let env: Record<string, string | undefined>;

  beforeEach(() => {
    root = tempRoot("pi");
    work = path.join(root, "work");
    mkdirSync(work, { recursive: true });
    fauxLog = path.join(root, "faux.log");
    env = {
      ...process.env,
      AURELHAVEN_PI_BIN: PI_CLI!,
      // A private pi config folder: the player's ~/.pi is never read or written.
      PI_CODING_AGENT_DIR: path.join(root, "pi-agent"),
      PI_OFFLINE: "1",
      AURELHAVEN_PI_FAUX_LOG: fauxLog,
    };
    // Keep pi's own retry of transient errors, but with short delays.
    writeJson(path.join(root, "pi-agent"), "settings.json", { retry: { baseDelayMs: 20 } });
  });

  afterEach(() => removeRoot(root));

  const adapter = (withFaux = true) =>
    new PiAdapter(testDeps(path.join(root, "data"), env), { extraArgs: withFaux ? ["-e", FAUX, "--offline"] : ["--offline"] });
  const script = (responses: unknown[]) => {
    env.AURELHAVEN_PI_FAUX_SCRIPT = writeJson(root, `script-${Math.random().toString(36).slice(2)}.json`, { responses });
  };
  const start = (a: PiAdapter, host: MockHost, overrides: Partial<RunRequest> = {}) =>
    a.start(runRequest(work, { provider: "pi", model: "faux/faux-1", ...overrides }), host);
  const calls = () => readLog(fauxLog).filter((e) => e.kind === "call");

  it("probes and lists models, and never throws when pi is missing or has no credentials", async () => {
    const info = await adapter().probe();
    expect(info).toMatchObject({ id: "pi", installed: true, version: "0.87.1", logged_in: true });
    expect(info.message).toMatch(/credentials for faux/);
    const models = await adapter().listModels();
    expect(models).toEqual([{ id: "faux/faux-1", label: "Faux One (faux)", default: true, cost_hint: "$1.00 in / $5.00 out per 1M tokens" }]);

    const bare = await adapter(false).probe();
    expect(bare).toMatchObject({ installed: true, logged_in: false });
    expect(bare.message).toMatch(/no provider credentials/);

    env = { PATH: "", AURELHAVEN_PI_BIN: path.join(root, "missing.js") };
    expect(await adapter().probe()).toMatchObject({ installed: false, logged_in: false });
  });

  it("runs a task: the gate extension's approval round trip, events, usage, session", async () => {
    script([
      { text: "I will write the greeting.", tool: "write", args: { path: "hello.txt", content: "hi\n" } },
      { text: "Done writing." },
    ]);
    const host = new MockHost();
    const outcome = await within(start(adapter(), host).done);
    expect(outcome).toEqual({ kind: "completed", summary: "Done writing." });
    expect(readFileSync(path.join(work, "hello.txt"), "utf8")).toBe("hi\n");
    expect(host.approvals).toHaveLength(1);
    expect(host.approvals[0]).toMatchObject({ tool: "write", category: "write", summary: "Write: hello.txt", input: { path: "hello.txt", content: "hi\n" } });
    expect(host.events).toContainEqual(expect.objectContaining({ kind: "tool_start", tool: "write" }));
    expect(host.events).toContainEqual(expect.objectContaining({ kind: "tool_end", tool: "write", ok: true }));
    expect(host.events).toContainEqual({ kind: "files_touched", paths: ["hello.txt"] });
    expect(host.texts("activity")).toContain("I will write the greeting.");

    // Usage: the per-message costs pi reported, charged once each.
    const priced = readLog(fauxLog).filter((e) => e.kind === "cost").reduce((s, e) => s + (e.total as number), 0);
    expect(priced).toBeGreaterThan(0);
    expect(Math.abs(host.usageMicros() - Math.round(priced * 1_000_000))).toBeLessThanOrEqual(2);

    const cp = host.lastCheckpoint<PiCheckpoint>();
    expect(cp).toMatchObject({ harness: "pi", sessionId: piSessionId("tsk_test") });
    expect(cp.sessionDir).toBe(path.join(root, "data", "pi-sessions", "tsk_test"));
    expect(cp.sessionFile && existsSync(cp.sessionFile)).toBe(true);
    expect(host.events).toContainEqual({ kind: "session", sessionId: cp.sessionId });
    // The first call carried the task framing and the Oath in the system prompt.
    expect(calls()[0]!.system).toContain("Greet the town");
    expect(calls()[0]!.lastUser).toBe("Write hello.txt");
  });

  it("blocks a denied tool call with the player's message", async () => {
    script([{ tool: "bash", args: { command: "git push origin main" } }, { echo: true }]);
    const host = new MockHost();
    host.decide = () => ({ decision: "deny", message: "no pushing" });
    const outcome = await within(start(adapter(), host, { tools: ["lectern", "forge"] }).done);
    expect(outcome.kind).toBe("completed");
    expect(host.approvals[0]).toMatchObject({ tool: "bash", category: "command", risk: "high" });
    expect(host.events).toContainEqual(expect.objectContaining({ kind: "tool_end", tool: "bash", ok: false }));
    expect(calls()[1]!.lastToolResult).toMatchObject({ tool: "bash", isError: true, text: expect.stringContaining("The player denied this: no pushing") });
  });

  it("maps add-ons to pi's --tools: a tool the agent lacks never runs", async () => {
    script([{ tool: "bash", args: { command: "echo hi" } }, { text: "No shell here." }]);
    const host = new MockHost();
    const outcome = await within(start(adapter(), host, { tools: ["lectern", "quillworks", "rookery"] }).done);
    expect(outcome).toEqual({ kind: "completed", summary: "No shell here." });
    expect(host.approvals).toHaveLength(0);
    expect(calls()[1]!.lastToolResult).toMatchObject({ isError: true });
    expect(host.texts("activity").some((t) => t.includes("rookery add-on does nothing for pi"))).toBe(true);
  });

  it("loads AGENTS.md only with an Archive", async () => {
    writeFileSync(path.join(work, "AGENTS.md"), "Charter marker: always use tabs.\n");
    script([{ text: "ok" }]);
    await within(start(adapter(), new MockHost()).done);
    expect(calls()[0]!.system).not.toContain("Charter marker");
    script([{ text: "ok" }]);
    await within(start(adapter(), new MockHost(), { taskId: "tsk_archive", tools: ["lectern", "archive"] }).done);
    expect(calls()[1]!.system).toContain("Charter marker");
  });

  it("steers a nudge into a streaming run", async () => {
    script([{ sleep: 1_500, text: "First part." }, { echo: true }]);
    const host = new MockHost();
    const run = start(adapter(), host);
    await waitUntil(() => calls().length >= 1);
    run.send("Also sign it");
    const outcome = await within(run.done);
    expect(outcome).toEqual({ kind: "completed", summary: "Echo: Message from the player: Also sign it" });
  });

  it("aborts while an approval is pending, and on a hanging model call", async () => {
    script([{ tool: "write", args: { path: "x.txt", content: "x" } }]);
    const host = new MockHost();
    host.decide = () => new Promise(() => undefined);
    const run = start(adapter(), host);
    await host.waitApprovals(1);
    run.interrupt();
    expect(await within(run.done)).toEqual({ kind: "interrupted" });
    expect(existsSync(path.join(work, "x.txt"))).toBe(false);

    script([{ hang: true }]);
    const hangHost = new MockHost();
    const hanging = start(adapter(), hangHost, { taskId: "tsk_hang" });
    await waitUntil(() => calls().some((c) => c.step.hang));
    hanging.interrupt();
    expect(await within(hanging.done)).toEqual({ kind: "interrupted" });
  });

  it("kills pi on kill()", async () => {
    script([{ hang: true }]);
    const host = new MockHost();
    const run = start(adapter(), host);
    await waitUntil(() => calls().length >= 1);
    run.kill();
    expect(await within(run.done)).toEqual({ kind: "interrupted" });
  });

  it("resumes the task's session with the feedback as the next message", async () => {
    script([{ text: "Version one." }]);
    const firstHost = new MockHost();
    await within(start(adapter(), firstHost).done);
    const cp = firstHost.lastCheckpoint<PiCheckpoint>();

    script([{ echo: true }]);
    const host = new MockHost();
    const outcome = await within(start(adapter(), host, { attempt: 2, resume: { sessionId: cp.sessionId, state: cp, feedback: "Make it warmer" } }).done);
    expect(outcome.kind).toBe("completed");
    const second = calls()[1]!;
    expect(second.users).toBe(2);
    expect(second.lastUser).toMatch(/^The player reviewed your work on this task and sent it back with this feedback:\n\nMake it warmer/);
  });

  it("reports a provider error as a failure, and a rate limit as a provider limit", async () => {
    // pi retries rate limits itself; every attempt fails the same way here.
    script([1, 2, 3, 4, 5].map(() => ({ error: "429 rate limit exceeded" })));
    const outcome = await within(start(adapter(), new MockHost()).done);
    expect(outcome).toMatchObject({ kind: "failed", error: { code: "provider_limit", transient: true } });
  });

  it("warns that this pi version cannot connect Waygates", async () => {
    script([{ text: "ok" }]);
    const host = new MockHost();
    await within(
      start(adapter(), host, {
        tools: ["lectern", "waygate"],
        waygates: [{ server_name: "github", transport: "stdio", command: "node", args: ["gh.js"], env_refs: ["GH_TOKEN"] }],
      }).done,
    );
    expect(host.texts("activity").some((t) => t.includes("cannot connect MCP servers") && t.includes("github"))).toBe(true);
  });

  it("splits pi model names", () => {
    expect(splitPiModel("openrouter/deepseek/deepseek-chat")).toEqual({ provider: "openrouter", id: "deepseek/deepseek-chat" });
    expect(splitPiModel("sonnet")).toEqual({ provider: null, id: "sonnet" });
    expect(piSessionId("tsk_01J:x")).toBe("aurelhaven-tsk_01J_x");
  });
});

async function waitUntil(pred: () => boolean, ms = 20_000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!pred()) {
    if (Date.now() > deadline) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 50));
  }
}
