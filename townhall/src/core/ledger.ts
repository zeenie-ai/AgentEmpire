import { fail } from "../protocol/errors.js";
import type { LedgerEntry } from "../protocol/objects.js";
import type { Ctx } from "./context.js";
import {
  RESOURCE_KEYS,
  isZero,
  negate,
  toResources,
  zeroResources,
  type Cost,
  type ResourceKey,
  type Resources,
} from "./economy.js";

interface LedgerRow {
  id: number;
  time: string;
  op_id: string | null;
  kind: string;
  reason: string;
  ref: string | null;
  spend_op_id: string | null;
  food: number;
  wood: number;
  stone: number;
  gold: number;
}

export type LedgerKind = "start" | "spend" | "refund" | "gather" | "trade" | "cost" | "reward" | "cancel_refund" | "dismantle";

interface AppendSpec {
  kind: LedgerKind;
  reason: string;
  delta: Resources;
  opId?: string | null;
  ref?: string | null;
  spendOpId?: string | null;
}

interface MarketState {
  penalty: number;
  at: number;
}

/** Prefix for op ids the Town Hall generates itself, so they never collide with client op ids. */
const INTERNAL_OP = "th:";

function rowDelta(r: LedgerRow): Resources {
  return { food: r.food, wood: r.wood, stone: r.stone, gold: r.gold };
}

export class Treasury {
  private cached: Resources | null = null;

  constructor(private readonly ctx: Ctx) {
    ctx.db.addAfterRollback(() => {
      this.cached = null;
    });
  }

  /** Writes the starting resources on a fresh database. */
  init(): void {
    this.ctx.db.tx(() => {
      const any = this.ctx.db.get("SELECT id FROM ledger LIMIT 1");
      if (any) return;
      this.append({
        kind: "start",
        reason: "start",
        delta: toResources(this.ctx.econ.data.start.resources),
        opId: `${INTERNAL_OP}start`,
      });
    });
  }

  balance(): Resources {
    if (this.cached) return { ...this.cached };
    const row = this.ctx.db.get<Resources>(
      "SELECT COALESCE(SUM(food),0) AS food, COALESCE(SUM(wood),0) AS wood, COALESCE(SUM(stone),0) AS stone, COALESCE(SUM(gold),0) AS gold FROM ledger",
    );
    this.cached = row ? { food: row.food, wood: row.wood, stone: row.stone, gold: row.gold } : zeroResources();
    return { ...this.cached };
  }

  canAfford(cost: Resources): boolean {
    const b = this.balance();
    return RESOURCE_KEYS.every((k) => b[k] >= cost[k]);
  }

  private shortfall(cost: Resources): string {
    const b = this.balance();
    const missing = RESOURCE_KEYS.filter((k) => b[k] < cost[k]).map((k) => `${cost[k] - b[k]} ${k}`);
    return `not enough resources: missing ${missing.join(", ")}`;
  }

  private findOp(opId: string): LedgerRow | undefined {
    return this.ctx.db.get<LedgerRow>("SELECT * FROM ledger WHERE op_id = ?", [opId]);
  }

  private append(spec: AppendSpec): Resources {
    return this.ctx.db.tx(() => {
      const next = this.balance();
      for (const k of RESOURCE_KEYS) next[k] += spec.delta[k];
      if (RESOURCE_KEYS.some((k) => next[k] < 0)) throw fail.resources(this.shortfall(negate(spec.delta)));
      this.ctx.db.run(
        "INSERT INTO ledger (time, op_id, kind, reason, ref, spend_op_id, food, wood, stone, gold) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [
          this.ctx.clock.iso(),
          spec.opId ?? null,
          spec.kind,
          spec.reason,
          spec.ref ?? null,
          spec.spendOpId ?? null,
          spec.delta.food,
          spec.delta.wood,
          spec.delta.stone,
          spec.delta.gold,
        ],
      );
      this.cached = next;
      if (!isZero(spec.delta)) {
        this.ctx.bus.emit("treasury_updated", { treasury: { ...next }, reason: spec.reason, delta: spec.delta }, "treasury");
      }
      return { ...next };
    });
  }

  /** Server-side charge (agents, homes, tools, ages). `opKey` makes it happen at most once. */
  charge(cost: Resources, reason: string, ref: string | null, opKey: string): Resources {
    return this.ctx.db.tx(() => {
      const opId = INTERNAL_OP + opKey;
      if (this.findOp(opId)) return this.balance();
      if (isZero(cost)) return this.balance();
      if (!this.canAfford(cost)) throw fail.resources(this.shortfall(cost));
      return this.append({ kind: "cost", reason, delta: negate(cost), opId, ref });
    });
  }

  /** Server-side credit (rewards, refunds). Credits are not limited by storage caps. */
  credit(amount: Resources, kind: LedgerKind, reason: string, ref: string | null, opKey: string): Resources {
    return this.ctx.db.tx(() => {
      const opId = INTERNAL_OP + opKey;
      if (this.findOp(opId)) return this.balance();
      return this.append({ kind, reason, delta: amount, opId, ref });
    });
  }

  private assertClientOp(opId: string): void {
    if (opId.startsWith(INTERNAL_OP)) throw fail.badRequest(`op_id must not start with "${INTERNAL_OP}"`);
  }

  spend(opId: string, reason: string, cost: Cost, ref?: string): Resources {
    this.assertClientOp(opId);
    return this.ctx.db.tx(() => {
      const existing = this.findOp(opId);
      if (existing) {
        if (existing.kind !== "spend") throw fail.conflict(`op_id ${opId} was already used for ${existing.kind}`);
        return this.balance();
      }
      const amount = toResources(cost);
      if (isZero(amount)) throw fail.badRequest("cost must not be empty");
      if (!this.canAfford(amount)) throw fail.resources(this.shortfall(amount));
      return this.append({ kind: "spend", reason: `spend:${reason}`, delta: negate(amount), opId, ref: ref ?? null });
    });
  }

  refund(opId: string, spendOpId: string, fraction: number): Resources {
    this.assertClientOp(opId);
    return this.ctx.db.tx(() => {
      const existing = this.findOp(opId);
      if (existing) {
        if (existing.kind !== "refund") throw fail.conflict(`op_id ${opId} was already used for ${existing.kind}`);
        return this.balance();
      }
      const spend = this.findOp(spendOpId);
      if (!spend || spend.kind !== "spend") throw fail.notFound("spend", spendOpId);
      const prior = this.ctx.db.get("SELECT id FROM ledger WHERE spend_op_id = ?", [spendOpId]);
      if (prior) throw fail.conflict(`spend ${spendOpId} was already refunded`);
      const spent = negate(rowDelta(spend));
      const amount = zeroResources();
      for (const k of RESOURCE_KEYS) amount[k] = Math.min(spent[k], Math.floor(spent[k] * fraction));
      return this.append({
        kind: "refund",
        reason: `refund:${spend.reason.replace(/^spend:/, "")}`,
        delta: amount,
        opId,
        ref: spend.ref,
        spendOpId,
      });
    });
  }

  gather(opId: string, deposits: { food?: number; wood?: number }, storehouses: number): Resources {
    this.assertClientOp(opId);
    return this.ctx.db.tx(() => {
      const existing = this.findOp(opId);
      if (existing) {
        if (existing.kind !== "gather") throw fail.conflict(`op_id ${opId} was already used for ${existing.kind}`);
        return this.balance();
      }
      const age = this.ctx.ages.current();
      const cap = this.ctx.econ.storageCap(age, storehouses);
      const capped = new Set<ResourceKey>(this.ctx.econ.data.storage.capped);
      const balance = this.balance();
      const delta = zeroResources();
      for (const k of ["food", "wood"] as const) {
        const dep = deposits[k] ?? 0;
        if (dep <= 0) continue;
        delta[k] = capped.has(k) ? Math.max(0, Math.min(dep, cap - balance[k])) : dep;
      }
      return this.append({ kind: "gather", reason: "gather", delta, opId });
    });
  }

  private market(): MarketState {
    return this.ctx.settings.getState<MarketState>("quartermaster", { penalty: 0, at: this.ctx.clock.now() });
  }

  /** The Quartermaster's current rate multiplier (1 = the base rate). */
  marketRate(): number {
    const qm = this.ctx.econ.data.quartermaster;
    const m = this.market();
    const minutes = Math.max(0, (this.ctx.clock.now() - m.at) / 60_000);
    const penalty = Math.max(0, m.penalty - qm.recover_per_minute * minutes);
    return Math.max(0, 1 - penalty);
  }

  trade(opId: string, give: { resource: ResourceKey; amount: number }, get: ResourceKey): { treasury: Resources; rate: number } {
    this.assertClientOp(opId);
    const qm = this.ctx.econ.data.quartermaster;
    return this.ctx.db.tx(() => {
      const existing = this.findOp(opId);
      if (existing) {
        if (existing.kind !== "trade") throw fail.conflict(`op_id ${opId} was already used for ${existing.kind}`);
        return { treasury: this.balance(), rate: this.marketRate() };
      }
      if (this.ctx.ages.current() < qm.age) throw fail.age(`the Quartermaster opens in Age ${qm.age}`);
      let ratio: number;
      if (qm.sell_basic.give_from.includes(give.resource) && qm.sell_basic.get_to.includes(get)) {
        ratio = qm.sell_basic.get / qm.sell_basic.give;
      } else if (qm.sell_precious.give_from.includes(give.resource) && qm.sell_precious.get_to.includes(get)) {
        ratio = qm.sell_precious.get / qm.sell_precious.give;
      } else {
        throw fail.badRequest(`the Quartermaster does not trade ${give.resource} for ${get}`);
      }
      const rate = this.marketRate();
      const received = Math.floor(give.amount * ratio * rate);
      if (received <= 0) throw fail.badRequest("the trade is too small to receive anything");
      const delta = zeroResources();
      delta[give.resource] -= give.amount;
      delta[get] += received;
      const treasury = this.append({ kind: "trade", reason: `trade:${give.resource}->${get}`, delta, opId });
      const penaltyNow = 1 - rate;
      this.ctx.settings.setState("quartermaster", {
        penalty: Math.min(1, penaltyNow + qm.worsen_per_trade),
        at: this.ctx.clock.now(),
      } satisfies MarketState);
      return { treasury, rate: this.marketRate() };
    });
  }

  entries(limit = 100): LedgerEntry[] {
    const rows = this.ctx.db.all<LedgerRow>("SELECT * FROM ledger ORDER BY id DESC LIMIT ?", [limit]);
    return rows.map((r) => ({
      id: String(r.id),
      time: r.time,
      op_id: r.op_id,
      kind: r.kind,
      reason: r.reason,
      ref: r.ref,
      delta: rowDelta(r),
    }));
  }
}
