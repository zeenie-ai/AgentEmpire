import { existsSync } from "node:fs";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { makeRepo } from "../helpers/git.js";
import { summonAgent, TestTown, type TestClient } from "../helpers/harness.js";

describe("parties", () => {
  let town: TestTown;
  let c: TestClient;
  let lead: string;
  let member: string;
  let leadRepo: string;
  let memberRepo: string;

  beforeAll(async () => {
    town = await TestTown.start("party");
    c = await town.client();
    leadRepo = makeRepo(town.work, "engine");
    memberRepo = makeRepo(town.work, "docs");
    lead = await summonAgent(c, { name: "Mira", workspace: leadRepo });
    member = await summonAgent(c, {
      name: "Quill",
      role: "scribe",
      provider: "codex",
      workspace: memberRepo,
      tile: { x: 60, y: 60 },
    });
  });

  afterAll(async () => {
    await c.close();
    await town.stop();
  });

  it("enforces the unlock age, the lead rank and the lead provider", async () => {
    const early = await c.send("form_party", { lead_agent_id: lead, member_ids: [member] });
    expect(early.error?.code).toBe("AGE_REQUIRED");

    // Seed Age II directly; reaching it through play is covered by the rules tests.
    town.ctx.db.tx(() => town.ctx.settings.setState("age", { current: 2, research: null }));
    const lowRank = await c.send("form_party", { lead_agent_id: lead, member_ids: [member] });
    expect(lowRank.error?.code).toBe("RANK_REQUIRED");

    const codexLead = await c.send("form_party", { lead_agent_id: member, member_ids: [lead] });
    expect(codexLead.error?.code).toBe("BAD_REQUEST");
  });

  it("delegates a sub-task to a member, waits for it, and splits the reward 40/60", async () => {
    // Seed rank E for the lead (150 XP, 2 accepted tasks).
    town.ctx.db.tx(() => {
      town.ctx.db.run("UPDATE agents SET xp = 150, stats_json = json_set(stats_json, '$.accepted', 2) WHERE id = ?", [lead]);
      town.ctx.agents.recomputeRank(lead);
    });
    expect(town.ctx.agents.row(lead).rank).toBe("E");

    const { party_id: partyId } = await c.ok("form_party", { lead_agent_id: lead, member_ids: [member] });
    const formed = await c.waitEvent((e) => e.type === "party_updated" && e.payload.party.id === partyId);
    expect(formed.payload.party.member_ids).toEqual([member]);

    const { task_id: parentId } = await c.ok("assign_task", {
      party_id: partyId,
      title: "Build the helper and the lead part",
      prompt: "[fake:party_lead] Build it together",
      size: "M",
      courier: { mode: "express" },
    });
    const delegated = await c.waitEvent((e) => e.type === "subtask_delegated" && e.payload.parent_task_id === parentId);
    expect(delegated.payload.from_agent_id).toBe(lead);
    expect(delegated.payload.to_agent_id).toBe(member);
    const childId: string = delegated.payload.task_id;
    const child = town.ctx.tasks.row(childId);
    expect(child.depth).toBe(1);
    expect(child.agent_id).toBe(member);
    expect(child.seal_micros).toBe(200_000);
    expect(town.ctx.tasks.row(parentId).seal_micros).toBe(1_500_000 - 200_000);
    // Sub-tasks sit at depth 1 and cannot delegate further, so no cycle can form.
    expect(() =>
      town.ctx.parties.delegate(childId, member, { to: "any", title: "Loop", prompt: "loop", size: "S", budgetMana: 1 }),
    ).toThrow(/cannot delegate/);

    // The party works long enough to earn a reward.
    town.clock.advance(31_000);
    const childReview = await c.waitTask(childId, "awaiting_review");
    expect(childReview.payload.task.parent_task_id).toBe(parentId);
    const parentReview = await c.waitTask(parentId, "awaiting_review", 30_000);
    expect(parentReview.payload.task.result.deliverable).toBe(true);
    await c.waitEvent((e) => e.type === "task_activity" && e.payload.task_id === parentId && e.payload.entry.text.includes(`Sub-task ${childId} done`));

    const direct = await c.send("accept_result", { task_id: childId, integrate: "merge" });
    expect(direct.error?.code).toBe("INVALID_STATE");
    const busy = await c.send("disband_party", { party_id: partyId });
    expect(busy.error?.code).toBe("INVALID_STATE");

    const xpBefore = { lead: town.ctx.agents.row(lead).xp, member: town.ctx.agents.row(member).xp };
    const accepted = await c.ok("accept_result", { task_id: parentId, integrate: "merge" });
    const rp: number = accepted.rewards.rp;
    expect(rp).toBeGreaterThan(0);
    await c.waitTask(parentId, "accepted");
    const childDone = await c.waitTask(childId, "accepted");
    expect(childDone.payload.task.rewards.rp).toBe(0);
    expect(childDone.payload.task.rewards.breakdown.zero_reason).toBe("party_subtask");

    const leadXp = town.ctx.agents.row(lead).xp - xpBefore.lead;
    const memberXp = town.ctx.agents.row(member).xp - xpBefore.member;
    expect(leadXp).toBe(Math.round(rp * 0.4));
    expect(memberXp).toBe(rp - Math.round(rp * 0.4));
    expect(town.ctx.agents.get(member).stats.party_tasks).toBe(1);
    // Both repositories received their part.
    expect(existsSync(path.join(leadRepo, "lead.txt"))).toBe(true);
    expect(existsSync(path.join(memberRepo, "member.txt"))).toBe(true);

    await c.ok("disband_party", { party_id: partyId });
    await c.waitEvent((e) => e.type === "party_disbanded" && e.payload.party_id === partyId);
    expect(town.ctx.agents.row(lead).party_id).toBeNull();
  });
});
