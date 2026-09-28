import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { TestClient, TestTown } from "../helpers/harness.js";

describe("reconnect replay and take-over", () => {
  let town: TestTown;

  beforeAll(async () => {
    town = await TestTown.start("replay");
  });

  afterAll(async () => {
    await town.stop();
  });

  it("replays missed events in order after last_seq", async () => {
    const a = await town.client();
    await a.ok("spend_resources", { op_id: "op-1", reason: "cottage", cost: { wood: 30 } });
    await a.waitEvent((e) => e.type === "treasury_updated");
    const seen = a.lastSeq();
    expect(seen).toBeGreaterThan(0);
    await a.close();

    // Changes while the game is closed.
    town.ctx.treasury.spend("op-2", "farm", { wood: 40 });
    town.ctx.treasury.spend("op-3", "cottage", { wood: 30 });
    town.ctx.town.save(0, 1, { tiles: [1, 2, 3] });

    const b = await TestClient.connect(town.port);
    const r = await b.hello(town.token, { last_seq: seen });
    expect(r.ok).toBe(true);
    expect(r.payload.catchup).toBe("replay");
    const current = r.payload.seq as number;
    expect(current).toBeGreaterThan(seen);
    await b.waitEvent((e) => e.seq === current, 5_000, "the last missed event");
    const seqs = b.events.map((e) => e.seq);
    expect(seqs[0]).toBe(seen + 1);
    for (let i = 1; i < seqs.length; i++) expect(seqs[i]).toBe(seqs[i - 1]! + 1);
    expect(b.events.filter((e) => e.type === "treasury_updated")).toHaveLength(2);
    expect(b.events.some((e) => e.type === "town_saved" && e.payload.rev === 1)).toBe(true);

    // The state snapshot agrees with the replayed events.
    const state = await b.ok("get_state");
    expect(state.seq).toBe(current);
    expect(state.treasury.wood).toBe(200 - 30 - 40 - 30);
    await b.close();
  });

  it("asks for a snapshot without last_seq or when last_seq is ahead", async () => {
    const c = await TestClient.connect(town.port);
    const r = await c.hello(town.token);
    expect(r.payload.catchup).toBe("snapshot");
    await c.close();
    const d = await TestClient.connect(town.port);
    const r2 = await d.hello(town.token, { last_seq: 10_000_000 });
    expect(r2.payload.catchup).toBe("snapshot");
    await d.close();
  });

  it("allows one active client; take_over revokes the old one with 4409", async () => {
    const a = await town.client();
    const b = await TestClient.connect(town.port);
    const busy = await b.hello(town.token);
    expect(busy.ok).toBe(false);
    expect(busy.error?.code).toBe("SESSION_BUSY");
    expect(b.closeInfo).toBeNull();

    const taken = await b.hello(town.token, { take_over: true });
    expect(taken.ok).toBe(true);
    const closed = await a.closed;
    expect(closed.code).toBe(4409);
    expect(a.events.some((e) => e.type === "session_revoked")).toBe(true);

    // Only the new client receives live events now.
    const before = a.events.length;
    await b.ok("spend_resources", { op_id: "op-4", reason: "cottage", cost: { wood: 30 } });
    await b.waitEvent((e) => e.type === "treasury_updated" && e.payload.reason === "spend:cottage");
    expect(a.events.length).toBe(before);
    await b.close();
  });

  it("makes commands idempotent by request_id", async () => {
    const c = await town.client();
    const first = await c.send("spend_resources", { op_id: "op-5", reason: "farm", cost: { wood: 10 } }, "same-id");
    const again = await c.send("spend_resources", { op_id: "op-5", reason: "farm", cost: { wood: 10 } }, "same-id");
    expect(again).toEqual(first);
    const conflict = await c.send("spend_resources", { op_id: "op-6", reason: "farm", cost: { wood: 10 } }, "same-id");
    expect(conflict.error?.code).toBe("CONFLICT");
    const spends = town.ctx.db.all("SELECT id FROM ledger WHERE op_id = 'op-5'");
    expect(spends).toHaveLength(1);
    await c.close();
  });
});
