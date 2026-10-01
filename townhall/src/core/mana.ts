import { fromJson, toJson } from "../db/db.js";
import { fail } from "../protocol/errors.js";
import type { Billing, Mana, ManaLevel, ManaPeriod, Provider, ProviderWindow } from "../protocol/objects.js";
import type { RateWindow } from "../providers/types.js";
import type { TimerHandle } from "./clock.js";
import type { Ctx } from "./context.js";
import { incidentKey } from "./incidents.js";

export type ProviderBilling = Record<Provider, Billing>;

export interface BudgetConfig {
  period: ManaPeriod;
  refill_hour_local: number;
  pool_micros: number;
  billing: ProviderBilling;
}

type ByProvider = Record<Provider, number>;

function zeroByProvider(): ByProvider {
  return { claude: 0, codex: 0, pi: 0 };
}

/** Where the providers' usage windows are kept between runs and restarts. */
const WINDOWS_KEY = "provider_windows";
const PROVIDER_ORDER: Provider[] = ["claude", "codex", "pi"];

interface PeriodRow {
  id: number;
  kind: ManaPeriod;
  refill_hour: number;
  period_start: string;
  period_end: string;
  pool_micros: number;
  carried_in_micros: number;
  cap_micros: number;
  spent_micros: number;
  overdraft_micros: number;
  by_provider_json: string;
  closed_at: string | null;
}

interface TaskMoney {
  id: string;
  agent_id: string;
  seal_micros: number;
  reserved_micros: number;
  spent_micros: number;
  seal_warned: number;
}

export interface ChargeResult {
  sealWarning: boolean;
  sealExhausted: boolean;
}

/** Start and end (epoch ms) of the budget period containing `now`, in local time. */
export function periodBounds(kind: ManaPeriod, refillHour: number, now: number): { start: number; end: number } {
  const n = new Date(now);
  const at = (y: number, m: number, d: number) => new Date(y, m, d, refillHour, 0, 0, 0).getTime();
  const y = n.getFullYear();
  const m = n.getMonth();
  const d = n.getDate();
  let start: number;
  if (kind === "day") {
    start = at(y, m, d);
    if (start > now) start = at(y, m, d - 1);
    const s = new Date(start);
    return { start, end: at(s.getFullYear(), s.getMonth(), s.getDate() + 1) };
  }
  if (kind === "week") {
    const sinceMonday = (n.getDay() + 6) % 7;
    start = at(y, m, d - sinceMonday);
    if (start > now) start = at(y, m, d - sinceMonday - 7);
    const s = new Date(start);
    return { start, end: at(s.getFullYear(), s.getMonth(), s.getDate() + 7) };
  }
  start = at(y, m, 1);
  if (start > now) start = at(y, m - 1, 1);
  const s = new Date(start);
  return { start, end: at(s.getFullYear(), s.getMonth() + 1, 1) };
}

export function levelFor(capMicros: number, spentMicros: number, stages: { dim: number; warning: number }, lightsOut: number): ManaLevel {
  if (capMicros <= 0) return "depleted";
  const left = (capMicros - spentMicros) / capMicros;
  if (left <= lightsOut) return "depleted";
  if (left <= stages.warning) return "warning";
  if (left <= stages.dim) return "dim";
  return "normal";
}

/**
 * Default billing per provider. pi prices every assistant message from its own model catalog,
 * so it defaults to API-key billing; the player can mark it as a subscription in set_budget.
 */
function detectBilling(env: Record<string, string | undefined>): ProviderBilling {
  return {
    claude: env.ANTHROPIC_API_KEY ? "api_key" : "subscription",
    codex: env.OPENAI_API_KEY || env.CODEX_API_KEY ? "api_key" : "subscription",
    pi: "api_key",
  };
}

export class ManaService {
  private timer: TimerHandle | null = null;
  private dirty = false;
  private lastLevel: ManaLevel | null = null;

  constructor(private readonly ctx: Ctx) {
    ctx.bus.addFlusher(() => {
      if (!this.dirty) return false;
      this.dirty = false;
      this.ctx.bus.emit("mana_updated", { mana: this.state() }, "mana");
      return true;
    });
    ctx.db.addAfterRollback(() => {
      this.dirty = false;
    });
  }

  private get m() {
    return this.ctx.econ.data.mana;
  }

  markDirty(): void {
    if (this.ctx.db.inTx()) this.dirty = true;
    else this.ctx.db.tx(() => (this.dirty = true));
  }

  config(): BudgetConfig {
    const detected = detectBilling(process.env);
    const cfg = this.ctx.settings.getState<BudgetConfig>("budget", {
      period: this.m.default_period,
      refill_hour_local: this.m.refill_hour_local,
      pool_micros: this.ctx.econ.usdToMicros(this.m.default_pool_usd),
      billing: detected,
    });
    // Budgets saved before pi existed (protocol 1.1) have no pi entry.
    return { ...cfg, billing: { ...detected, ...cfg.billing } };
  }

  defaultBilling(provider: Provider): Billing {
    return this.config().billing[provider];
  }

  private latest(): PeriodRow | undefined {
    return this.ctx.db.get<PeriodRow>("SELECT * FROM budget_periods ORDER BY id DESC LIMIT 1");
  }

  private openPeriod(carriedIn: number): PeriodRow {
    const cfg = this.config();
    const now = this.ctx.clock.now();
    const b = periodBounds(cfg.period, cfg.refill_hour_local, now);
    const cap = Math.max(0, cfg.pool_micros - carriedIn);
    const leftover = Math.max(0, carriedIn - cfg.pool_micros);
    this.ctx.db.run(
      "INSERT INTO budget_periods (kind, refill_hour, period_start, period_end, pool_micros, carried_in_micros, cap_micros, spent_micros, overdraft_micros, by_provider_json) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)",
      [
        cfg.period,
        cfg.refill_hour_local,
        new Date(b.start).toISOString(),
        new Date(b.end).toISOString(),
        cfg.pool_micros,
        carriedIn,
        cap,
        leftover,
        toJson(zeroByProvider()),
      ],
    );
    return this.latest()!;
  }

  /** The current period, creating the first one on a fresh database. */
  current(): PeriodRow {
    const row = this.latest();
    if (row) return row;
    return this.ctx.db.tx(() => this.openPeriod(0));
  }

  reservedTotal(): number {
    return (
      this.ctx.db.get<{ total: number | null }>(
        "SELECT SUM(reserved_micros) AS total FROM tasks WHERE reserved_micros > 0",
      )?.total ?? 0
    );
  }

  level(): ManaLevel {
    const p = this.current();
    return levelFor(p.cap_micros, p.spent_micros, this.m.stages, this.m.lights_out_fraction);
  }

  state(): Mana {
    const p = this.current();
    const reserved = this.reservedTotal();
    const byProvider = { ...zeroByProvider(), ...fromJson<Partial<ByProvider>>(p.by_provider_json, {}) };
    const subscriptionAgents =
      this.ctx.db.get<{ n: number }>(
        "SELECT COUNT(*) AS n FROM agents WHERE retired_at IS NULL AND billing = 'subscription'",
      )?.n ?? 0;
    const anyAgents = this.ctx.db.get<{ n: number }>("SELECT COUNT(*) AS n FROM agents WHERE retired_at IS NULL")?.n ?? 0;
    const cfg = this.config();
    const estimates = anyAgents > 0 ? subscriptionAgents > 0 : Object.values(cfg.billing).includes("subscription");
    return {
      period: p.kind,
      period_start: p.period_start,
      period_end: p.period_end,
      cap_micros: p.cap_micros,
      spent_micros: p.spent_micros,
      reserved_micros: reserved,
      remaining_micros: Math.max(0, p.cap_micros - p.spent_micros - reserved),
      level: levelFor(p.cap_micros, p.spent_micros, this.m.stages, this.m.lights_out_fraction),
      by_provider: { claude: byProvider.claude, codex: byProvider.codex, pi: byProvider.pi },
      estimates,
      provider_windows: this.providerWindows(),
    };
  }

  /**
   * The providers' own usage windows as their harnesses last reported them, without the ones
   * that have reset since: by provider, then shortest window first.
   */
  providerWindows(): ProviderWindow[] {
    const now = this.ctx.clock.now();
    return this.ctx.settings
      .getState<ProviderWindow[]>(WINDOWS_KEY, [])
      .filter((w) => !w.resets_at || Date.parse(w.resets_at) > now)
      .sort(
        (a, b) =>
          PROVIDER_ORDER.indexOf(a.provider) - PROVIDER_ORDER.indexOf(b.provider) ||
          (a.window_minutes ?? Number.MAX_SAFE_INTEGER) - (b.window_minutes ?? Number.MAX_SAFE_INTEGER) ||
          a.window.localeCompare(b.window),
      );
  }

  /**
   * Records the usage windows a harness reported (Claude Code's rate_limit_event, Codex's
   * account/rateLimits/updated). Each report replaces that window's earlier figures; mana_updated
   * goes out only when something visible changed.
   */
  updateProviderWindows(provider: Provider, windows: RateWindow[]): void {
    if (windows.length === 0) return;
    this.ctx.db.tx(() => {
      const now = this.ctx.clock.now();
      const stored = this.ctx.settings
        .getState<ProviderWindow[]>(WINDOWS_KEY, [])
        .filter((w) => !w.resets_at || Date.parse(w.resets_at) > now);
      const before = JSON.stringify(stored);
      for (const w of windows) {
        const next: ProviderWindow = {
          provider,
          window: w.window,
          window_minutes: w.windowMinutes === null ? null : Math.max(0, Math.round(w.windowMinutes)),
          used_percent: Math.round(Math.min(100, Math.max(0, w.usedPercent)) * 10) / 10,
          resets_at: w.resetsAt,
        };
        const i = stored.findIndex((s) => s.provider === provider && s.window === w.window);
        if (i >= 0) stored[i] = next;
        else stored.push(next);
      }
      if (JSON.stringify(stored) === before) return;
      this.ctx.settings.setState(WINDOWS_KEY, stored);
      this.markDirty();
    });
  }

  /** Called at startup: roll over a stale period, arm the refill timer, sync incidents. */
  start(): void {
    this.current();
    this.maybeRollover();
    this.armTimer();
    this.syncLevel();
  }

  stop(): void {
    this.ctx.clock.clearTimeout(this.timer);
    this.timer = null;
  }

  private armTimer(): void {
    this.ctx.clock.clearTimeout(this.timer);
    const end = Date.parse(this.current().period_end);
    this.timer = this.ctx.clock.setTimeout(() => {
      this.timer = null;
      this.maybeRollover();
      this.armTimer();
    }, Math.max(0, end - this.ctx.clock.now()));
  }

  /** Starts a new period when the current one has ended. Returns true if it rolled over. */
  maybeRollover(): boolean {
    const p = this.current();
    if (this.ctx.clock.now() < Date.parse(p.period_end)) return false;
    this.ctx.db.tx(() => {
      this.ctx.db.run("UPDATE budget_periods SET closed_at = ? WHERE id = ?", [this.ctx.clock.iso(), p.id]);
      this.openPeriod(p.overdraft_micros);
      this.trimReservations();
      this.markDirty();
    });
    this.syncLevel();
    return true;
  }

  /** Keeps spent + reserved <= cap after the cap shrinks. */
  private trimReservations(): void {
    const p = this.current();
    let over = p.spent_micros + this.reservedTotal() - p.cap_micros;
    if (over <= 0) return;
    const rows = this.ctx.db.all<TaskMoney>(
      "SELECT id, agent_id, seal_micros, reserved_micros, spent_micros, seal_warned FROM tasks WHERE reserved_micros > 0 ORDER BY created_at DESC",
    );
    for (const r of rows) {
      if (over <= 0) break;
      const cut = Math.min(over, r.reserved_micros);
      this.ctx.db.run("UPDATE tasks SET reserved_micros = reserved_micros - ? WHERE id = ?", [cut, r.id]);
      this.ctx.tasks.markDirty(r.id);
      over -= cut;
    }
  }

  private freeMicros(): number {
    const p = this.current();
    return Math.max(0, p.cap_micros - p.spent_micros - this.reservedTotal());
  }

  /** The start rule: free Mana covers 25% of the remaining seal and the minimum reservation. */
  canStart(task: { seal_micros: number; spent_micros: number; reserved_micros: number }): { ok: boolean; reason?: string } {
    if (this.level() === "depleted") return { ok: false, reason: "lights out: the Mana pool is exhausted" };
    const remainingSeal = task.seal_micros - task.spent_micros;
    if (remainingSeal <= 0) return { ok: false, reason: "the task's Mana Seal is exhausted" };
    const need = Math.max(
      Math.ceil(this.m.start_min_fraction_of_seal * remainingSeal),
      this.ctx.econ.usdToMicros(this.m.min_reservation_usd),
    );
    const available = this.freeMicros() + task.reserved_micros;
    if (available < need) return { ok: false, reason: `needs ${need} micros of free Mana, ${available} available` };
    return { ok: true };
  }

  reserve(taskId: string): number {
    return this.ctx.db.tx(() => {
      const t = this.taskMoney(taskId);
      const want = Math.max(0, t.seal_micros - t.spent_micros - t.reserved_micros);
      const add = Math.min(want, this.freeMicros());
      if (add > 0) {
        this.ctx.db.run("UPDATE tasks SET reserved_micros = reserved_micros + ? WHERE id = ?", [add, taskId]);
        this.ctx.tasks.markDirty(taskId);
        this.markDirty();
      }
      return add;
    });
  }

  release(taskId: string): void {
    this.ctx.db.tx(() => {
      const t = this.taskMoney(taskId);
      if (t.reserved_micros === 0) return;
      this.ctx.db.run("UPDATE tasks SET reserved_micros = 0 WHERE id = ?", [taskId]);
      this.ctx.tasks.markDirty(taskId);
      this.markDirty();
    });
  }

  /** Moves part of a parent's reservation to a delegated child task. */
  transferReservation(fromTaskId: string, toTaskId: string, amount: number): number {
    return this.ctx.db.tx(() => {
      const from = this.taskMoney(fromTaskId);
      const moved = Math.max(0, Math.min(amount, from.reserved_micros));
      if (moved > 0) {
        this.ctx.db.run("UPDATE tasks SET reserved_micros = reserved_micros - ? WHERE id = ?", [moved, fromTaskId]);
        this.ctx.db.run("UPDATE tasks SET reserved_micros = reserved_micros + ? WHERE id = ?", [moved, toTaskId]);
        this.ctx.tasks.markDirty(fromTaskId);
        this.ctx.tasks.markDirty(toTaskId);
      }
      return moved;
    });
  }

  private taskMoney(taskId: string): TaskMoney {
    const t = this.ctx.db.get<TaskMoney>(
      "SELECT id, agent_id, seal_micros, reserved_micros, spent_micros, seal_warned FROM tasks WHERE id = ?",
      [taskId],
    );
    if (!t) throw fail.notFound("task", taskId);
    return t;
  }

  /**
   * Records real usage for a task. Usage is taken from the task's reservation first,
   * then from free Mana; anything beyond the cap becomes overdraft on the next period.
   */
  charge(taskId: string, provider: Provider, micros: number, estimate: boolean): ChargeResult {
    if (micros <= 0) return { sealWarning: false, sealExhausted: false };
    this.maybeRollover();
    const result = this.ctx.db.tx(() => {
      const t = this.taskMoney(taskId);
      const p = this.current();
      const fromReservation = Math.min(micros, t.reserved_micros);
      let spent = p.spent_micros + fromReservation;
      const rest = micros - fromReservation;
      const reservedAfter = this.reservedTotal() - fromReservation;
      const free = Math.max(0, p.cap_micros - spent - reservedAfter);
      const fromFree = Math.min(rest, free);
      spent += fromFree;
      const overdraft = p.overdraft_micros + (rest - fromFree);
      const byProvider = { ...zeroByProvider(), ...fromJson<Partial<ByProvider>>(p.by_provider_json, {}) };
      byProvider[provider] += micros;
      this.ctx.db.run(
        "UPDATE budget_periods SET spent_micros = ?, overdraft_micros = ?, by_provider_json = ? WHERE id = ?",
        [spent, overdraft, toJson(byProvider), p.id],
      );
      const newSpent = t.spent_micros + micros;
      let newReserved = t.reserved_micros - fromReservation;
      if (newReserved === 0 && newSpent < t.seal_micros) {
        // Top the reservation up from free Mana so the task keeps running within its seal.
        const topUp = Math.min(t.seal_micros - newSpent, Math.max(0, p.cap_micros - spent - reservedAfter));
        newReserved += topUp;
      }
      const sealWarning = t.seal_warned === 0 && newSpent >= this.m.seal_warning_fraction * t.seal_micros;
      this.ctx.db.run(
        "UPDATE tasks SET spent_micros = ?, reserved_micros = ?, seal_warned = ?, spent_is_estimate = CASE WHEN ? THEN 1 ELSE spent_is_estimate END WHERE id = ?",
        [newSpent, newReserved, sealWarning ? 1 : t.seal_warned, estimate ? 1 : 0, taskId],
      );
      this.ctx.agents.addManaSpent(t.agent_id, micros);
      this.ctx.tasks.markDirty(taskId);
      this.markDirty();
      return { sealWarning, sealExhausted: newSpent >= t.seal_micros };
    });
    this.syncLevel();
    return result;
  }

  /** Extends a task's seal by `mana` (the "Extend +50%" choice). */
  extendSeal(taskId: string, mana: number): void {
    this.ctx.db.tx(() => {
      const add = this.ctx.econ.manaToMicros(mana);
      this.ctx.db.run("UPDATE tasks SET seal_micros = seal_micros + ?, seal_warned = 0 WHERE id = ?", [add, taskId]);
      this.ctx.tasks.markDirty(taskId);
    });
  }

  setBudget(input: {
    period: ManaPeriod;
    refill_hour_local?: number | undefined;
    pool_usd: number;
    billing: { claude: Billing; codex: Billing; pi?: Billing | undefined };
    confirm_raise?: boolean | undefined;
  }): Mana {
    this.maybeRollover();
    this.ctx.db.tx(() => {
      const cfg = this.config();
      // A 1.1 client sends no pi entry: keep the current one.
      const billing: ProviderBilling = { claude: input.billing.claude, codex: input.billing.codex, pi: input.billing.pi ?? cfg.billing.pi };
      const p = this.current();
      const newPool = this.ctx.econ.usdToMicros(input.pool_usd);
      const refill = input.refill_hour_local ?? cfg.refill_hour_local;
      const periodChanged = input.period !== cfg.period || refill !== cfg.refill_hour_local;
      const now = this.ctx.clock.now();
      const newEnd = periodChanged ? periodBounds(input.period, refill, now).end : Date.parse(p.period_end);
      const midPeriod = p.spent_micros > 0 || this.reservedTotal() > 0;
      const raising = newPool > cfg.pool_micros || (periodChanged && newEnd < Date.parse(p.period_end));
      if (raising && midPeriod && input.confirm_raise !== true) {
        throw fail.conflict("raising the Mana pool in the middle of a period requires confirm_raise");
      }
      const next: BudgetConfig = { period: input.period, refill_hour_local: refill, pool_micros: newPool, billing };
      this.ctx.settings.setState("budget", next);
      const cap = Math.max(p.spent_micros, Math.max(0, newPool - p.carried_in_micros));
      this.ctx.db.run(
        "UPDATE budget_periods SET kind = ?, refill_hour = ?, period_end = ?, pool_micros = ?, cap_micros = ? WHERE id = ?",
        [input.period, refill, new Date(newEnd).toISOString(), newPool, cap, p.id],
      );
      this.trimReservations();
      this.ctx.agents.applyBillingDefaults(billing);
      this.markDirty();
    });
    this.armTimer();
    this.syncLevel();
    this.ctx.scheduler.kick();
    return this.state();
  }

  /** Opens or resolves the lantern incidents and triggers lights out / recovery. */
  syncLevel(): void {
    const level = this.level();
    const previous = this.lastLevel;
    this.lastLevel = level;
    this.ctx.db.tx(() => {
      if (level === "normal") {
        this.ctx.incidents.resolve(incidentKey.dimLanterns());
      } else {
        this.ctx.incidents.open("dim_lanterns", incidentKey.dimLanterns(), {
          severity: level === "dim" ? "info" : "warn",
          message: "The lanterns dim: the Mana pool is running low",
        });
      }
      if (level === "depleted") {
        this.ctx.incidents.open("font_dark", incidentKey.fontDark(), {
          severity: "urgent",
          message: "The Font has gone dark: the Mana pool is exhausted and all work is paused",
        });
      } else {
        this.ctx.incidents.resolve(incidentKey.fontDark());
      }
    });
    if (level === "depleted" && previous !== "depleted") {
      // Lights out: pause every run. Deferred so it never re-enters the caller's flow.
      setImmediate(() => this.ctx.supervisor.pauseAll("mana_depleted"));
    }
    if (previous === "depleted" && level !== "depleted") {
      setImmediate(() => this.ctx.tasks.autoResume("mana_depleted"));
    }
    if (previous !== null && previous !== level) this.ctx.scheduler.kick();
  }
}
