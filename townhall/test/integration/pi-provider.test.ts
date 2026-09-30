import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { makeRepo } from "../helpers/git.js";
import { summonAgent, TestClient, TestTown, type Reply } from "../helpers/harness.js";

describe("pi as a third provider (protocol 1.2, fake mode)", () => {
  let town: TestTown;
  let c: TestClient;
  let hello: Reply;
  let repo: string;

  beforeAll(async () => {
    town = await TestTown.start("pi-provider");
    c = await TestClient.connect(town.port);
    hello = await c.hello(town.token);
    repo = makeRepo(town.work, "app");
  });

  afterAll(async () => {
    await c.close();
    await town.stop();
  });

  it("lists pi and its models, and reports the protocol minor version 2", async () => {
    const providers = await c.ok("check_providers", {});
    const pi = providers.providers.find((p: { id: string }) => p.id === "pi");
    expect(pi).toMatchObject({ installed: true, logged_in: true });
    const models = await c.ok("list_models", { provider: "pi" });
    expect(models.models).toEqual([expect.objectContaining({ id: "fake/pi", default: true })]);
    expect(hello.ok).toBe(true);
    expect(hello.payload.protocol).toEqual({ major: 1, minor: 2 });
    expect(hello.payload.features).toContain("fake_provider");
    expect(hello.payload.sdk_versions).toEqual({ claude: "fake-1.0", codex: "fake-1.0", pi: "fake-1.0" });
  });

  it('requires "<pi provider>/<model id>" for pi agents', async () => {
    const spec = {
      name: "Pim",
      provider: "pi",
      model: "deepseek-chat",
      role: "artificer",
      instructions: "",
      approval_mode: "trusted_edits",
      workspace: { path: repo },
      starting_tools: [],
    };
    const bad = await c.send("create_agent", { spec });
    expect(bad.error?.code).toBe("BAD_REQUEST");
    expect(bad.error?.message).toMatch(/pi provider/);
    const planFirst = await c.send("create_agent", { spec: { ...spec, model: "openrouter/deepseek/deepseek-chat", approval_mode: "plan_first" } });
    expect(planFirst.error?.code).toBe("BAD_REQUEST");
  });

  it("runs a pi agent's task and bills Mana to pi", async () => {
    const agentId = await summonAgent(c, { name: "Pim", provider: "pi", workspace: repo });
    const agent = (await c.ok("get_state")).agents.find((a: { id: string }) => a.id === agentId);
    expect(agent).toMatchObject({ provider: "pi", model: "fake/pi", billing: "api_key" });
    const { task_id: taskId } = await c.ok("assign_task", {
      agent_id: agentId,
      title: "Greet",
      prompt: "[fake:basic] Greet",
      size: "S",
      courier: { mode: "express" },
    });
    await c.waitTask(taskId, "awaiting_review");
    const mana = (await c.ok("get_state")).mana;
    expect(mana.by_provider.pi).toBeGreaterThan(0);
    expect(mana.by_provider.claude).toBe(0);
    // Renaming the model keeps the same rule (retry if a background update bumped the version).
    let code: string | undefined;
    for (let i = 0; i < 5; i++) {
      const latest = (await c.ok("get_state")).agents.find((a: { id: string }) => a.id === agentId);
      const patched = await c.send("update_agent", { agent_id: agentId, patch: { model: "sonnet" }, expected_version: latest.version });
      code = patched.error?.code;
      if (code !== "CONFLICT") break;
    }
    expect(code).toBe("BAD_REQUEST");
  });

  it("keeps pi billing when a 1.1 client sends set_budget without it, and sets it when given", async () => {
    const before = town.ctx.mana.config().billing.pi;
    await c.ok("set_budget", { period: "day", pool_usd: 5, billing: { claude: "subscription", codex: "subscription" }, confirm_raise: true });
    expect(town.ctx.mana.config().billing.pi).toBe(before);
    await c.ok("set_budget", {
      period: "day",
      pool_usd: 5,
      billing: { claude: "subscription", codex: "subscription", pi: "subscription" },
      confirm_raise: true,
    });
    expect(town.ctx.mana.config().billing.pi).toBe("subscription");
    const agents = (await c.ok("get_state")).agents.filter((a: { provider: string; lifecycle: string }) => a.provider === "pi");
    expect(agents.length).toBeGreaterThan(0);
    for (const a of agents) expect(a.billing).toBe("subscription");
  });
});
