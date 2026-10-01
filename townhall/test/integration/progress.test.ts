import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { QUARTERMASTER_RECHECK_MS } from "../../src/core/progress.js";
import { Progress } from "../../src/protocol/objects.js";
import { makeRepo } from "../helpers/git.js";
import { sleep, summonAgent, TestTown, type Ev, type TestClient } from "../helpers/harness.js";

const progressEvents = (c: TestClient, after = 0): Ev[] => c.events.filter((e) => e.type === "progress_updated" && e.seq > after);

describe("town progress (get_progress and progress_updated, protocol 1.3)", () => {
  let town: TestTown;
  let c: TestClient;
  let repo: string;

  beforeAll(async () => {
    town = await TestTown.start("progress");
    c = await town.client();
    repo = makeRepo(town.work, "app");
  });

  afterAll(async () => {
    await c.close();
    await town.stop();
  });

  it("describes a new town: Age I, no facts yet, the Market age's milestones, base Quartermaster rates", async () => {
    const p = await c.ok("get_progress");
    expect(Progress.parse(p)).toEqual(p);
    expect(p).toEqual({
      age: { current: 1, research: null },
      facts: { accepted: 0, accepted_first_try: 0, tools_built: 0, rites_passed: 0, party_tasks: 0, under_baseline: 0 },
      next: {
        n: 2,
        id: "market",
        name: "Market",
        wall: "Merchant Ring",
        cost: { food: 400, wood: 300, stone: 150, gold: 100 },
        research_s: 90,
        ready: false,
        milestones: [
          { key: "accepted", label: "tasks accepted", have: 0, want: 3, met: false },
          { key: "tools_built", label: "add-ons built", have: 0, want: 2, met: false },
        ],
      },
      quartermaster: { basic_rate: 1, precious_rate: 1 },
    });
    // The snapshot carries the same object, so a reconnecting client never asks twice.
    expect((await c.ok("get_state")).progress).toEqual(p);
  });

  it("announces add-ons built and accepted work, and only when something changed", async () => {
    const agentId = await summonAgent(c, { workspace: repo, tools: ["lectern", "quillworks"] });
    const built = await c.waitEvent(
      (e) => e.type === "progress_updated" && e.payload.facts.tools_built === 2,
      10_000,
      "progress with two add-ons",
    );
    expect(built.payload.next.milestones[1]).toEqual({ key: "tools_built", label: "add-ons built", have: 2, want: 2, met: true });
    // The agent's many updates while it settled in did not each send progress.
    expect(progressEvents(c).map((e) => e.payload.facts.tools_built)).toEqual([1, 2]);

    const seen = c.lastSeq();
    const { task_id: taskId } = await c.ok("assign_task", {
      agent_id: agentId,
      title: "Think it through",
      prompt: "[fake:long] Think it through",
      size: "S",
      courier: { mode: "express" },
    });
    await c.waitTask(taskId, "running");
    town.clock.advance(31_000);
    await c.waitTask(taskId, "awaiting_review");
    // Starting, running and reviewing the task moved nothing in the progress.
    expect(progressEvents(c, seen)).toHaveLength(0);
    const accepted = await c.ok("accept_result", { task_id: taskId, integrate: "keep_branch" });
    expect(accepted.rewards.rp).toBeGreaterThan(0);
    const after = await c.waitEvent((e) => e.type === "progress_updated" && e.seq > seen && e.payload.facts.accepted === 1);
    expect(after.payload.facts).toMatchObject({ accepted: 1, accepted_first_try: 1 });
    expect(after.payload.next.milestones[0]).toMatchObject({ key: "accepted", have: 1, want: 3, met: false });
    expect(await c.ok("get_progress")).toEqual(after.payload);
  });

  it("follows each Quartermaster rate after a trade and while it recovers, at most once a minute", async () => {
    const seen = c.lastSeq();
    await c.ok("trade", { op_id: "pq1", give: { resource: "food", amount: 100 }, get: "gold" });
    const traded = await c.waitEvent((e) => e.type === "progress_updated" && e.seq > seen);
    expect(traded.payload.quartermaster).toEqual({ basic_rate: 0.95, precious_rate: 1 });

    // Half a minute later nothing is sent; the recovery shows on the next check.
    const before = c.lastSeq();
    town.clock.advance(QUARTERMASTER_RECHECK_MS / 2);
    await sleep(100);
    expect(progressEvents(c, before)).toHaveLength(0);
    town.clock.advance(QUARTERMASTER_RECHECK_MS / 2);
    const recovered = await c.waitEvent((e) => e.type === "progress_updated" && e.seq > before);
    expect(recovered.payload.quartermaster).toEqual({ basic_rate: 0.96, precious_rate: 1 });

    // A precious trade moves only the precious rate.
    await c.ok("trade", { op_id: "pq2", give: { resource: "gold", amount: 25 }, get: "wood" });
    const precious = await c.waitEvent((e) => e.type === "progress_updated" && e.payload.quartermaster.precious_rate === 0.95);
    expect(precious.payload.quartermaster.basic_rate).toBe(0.96);

    // Once both have recovered, the checks stop.
    town.clock.advance(10 * QUARTERMASTER_RECHECK_MS);
    const both = await c.waitEvent(
      (e) => e.type === "progress_updated" && e.seq > precious.seq && e.payload.quartermaster.basic_rate === 1 && e.payload.quartermaster.precious_rate === 1,
    );
    const quiet = both.seq;
    town.clock.advance(5 * QUARTERMASTER_RECHECK_MS);
    await sleep(100);
    expect(progressEvents(c, quiet)).toHaveLength(0);
  });

  it("says when the next age can be started, then follows the research into Age II", async () => {
    const agentId = town.ctx.db.get<{ id: string }>("SELECT id FROM agents WHERE retired_at IS NULL LIMIT 1")!.id;
    // Two more rewarded tasks for the milestone (the first came through play above).
    town.ctx.db.tx(() => {
      for (let i = 0; i < 2; i++) {
        town.ctx.db.run(
          `INSERT INTO tasks (id, agent_id, title, prompt, prompt_hash, size, acceptance_json, state, seal_micros, courier_json, created_at, updated_at, accepted_at, reward_rp, attempt)
           VALUES (?, ?, 't', 'p', ?, 'S', '[]', 'accepted', 1, '{"mode":"express"}', ?, ?, ?, 60, 2)`,
          [`tsk_progress${i}`, agentId, `hp${i}`, town.clock.iso(), town.clock.iso(), town.clock.iso()],
        );
      }
    });
    // Seeded rows bypass the services; a treasury change makes the Town Hall look again.
    const seen = c.lastSeq();
    town.ctx.treasury.credit({ food: 1000, wood: 1000, stone: 1000, gold: 1000 }, "reward", "reward", null, "progress-age");
    const ready = await c.waitEvent((e) => e.type === "progress_updated" && e.seq > seen && e.payload.next?.ready === true);
    expect(ready.payload.facts.accepted).toBe(3);
    expect(ready.payload.next.milestones.every((m: { met: boolean }) => m.met)).toBe(true);

    await c.ok("advance_age", {});
    const researching = await c.waitEvent((e) => e.type === "progress_updated" && e.payload.age.research?.target === 2);
    expect(researching.payload.next.ready).toBe(false);
    town.clock.advance(90_000);
    const market = await c.waitEvent((e) => e.type === "progress_updated" && e.payload.age.current === 2);
    expect(market.payload.next).toMatchObject({ n: 3, id: "guild", wall: "Guild Ring", ready: false });
    expect(market.payload.next.milestones.map((m: { key: string }) => m.key)).toEqual([
      "accepted",
      "accepted_first_try",
      "rites_passed",
      "agent_rank",
    ]);
    expect(market.payload.next.milestones[3]).toEqual({
      key: "agent_rank",
      label: "agents of rank D or higher",
      have: 0,
      want: 1,
      met: false,
    });
  });

  it("stays quiet after a restart when nothing changed, and catches up on what changed meanwhile", async () => {
    const logged = () => town.ctx.db.get<{ n: number }>("SELECT COUNT(*) AS n FROM event_log WHERE type = 'progress_updated'")!.n;
    const before = await c.ok("get_progress");
    const sent = logged();
    await c.close();
    await town.restart();
    // Startup work (recovery, refreshing every agent) sent nothing new.
    expect(logged()).toBe(sent);
    c = await town.client({ last_seq: town.ctx.bus.currentSeq() });
    const start = c.lastSeq();
    expect(await c.ok("get_progress")).toEqual(before);
    await sleep(100);
    expect(progressEvents(c, start)).toHaveLength(0);

    // A trade, then the Town Hall is down while its rate recovers: the next start reports it.
    await c.ok("trade", { op_id: "pq3", give: { resource: "wood", amount: 100 }, get: "stone" });
    await c.waitEvent((e) => e.type === "progress_updated" && e.payload.quartermaster.basic_rate === 0.95);
    await c.close();
    const seq = town.ctx.bus.currentSeq();
    await town.daemon.stop();
    town.clock.advance(3 * QUARTERMASTER_RECHECK_MS);
    await town.restart();
    c = await town.client({ last_seq: seq });
    const caught = await c.waitEvent((e) => e.type === "progress_updated" && e.seq > seq);
    expect(caught.payload.quartermaster.basic_rate).toBe(0.98);
  });
});
