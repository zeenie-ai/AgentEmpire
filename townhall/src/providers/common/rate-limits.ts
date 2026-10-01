import type { RateWindow } from "../types.js";
import { asNumber, asString, isPlainObject } from "./support.js";

/**
 * The providers' own usage windows, as the harnesses report them, turned into RateWindows for
 * Mana.provider_windows.
 *
 * Claude Code (2.1.281) writes a `rate_limit_event` record in stream-json:
 *   {"type":"rate_limit_event","rate_limit_info":{"status":"allowed"|"allowed_warning"|"rejected",
 *    "resetsAt":<unix s>,"rateLimitType":"five_hour"|"seven_day"|...,"utilization":<0..1>,
 *    "unifiedWindows":{"five_hour":{"utilization","resetsAt"},"seven_day":{...},...}, ...}}
 * The top-level fields describe the window that limits right now; `unifiedWindows` (subscription
 * accounts only) has every window. Utilization is a fraction and can pass 1.
 *
 * Codex (app-server 0.144) sends `account/rateLimits/updated {rateLimits: RateLimitSnapshot}`:
 *   {limitId, limitName, primary: {usedPercent, windowDurationMins, resetsAt} | null,
 *    secondary: {...} | null, credits, individualLimit, planType, rateLimitReachedType}
 * with usedPercent in percent and resetsAt in unix seconds.
 */

/** Window lengths Claude Code names but does not state. */
const CLAUDE_WINDOW_MINUTES: Record<string, number | null> = {
  five_hour: 300,
  seven_day: 7 * 24 * 60,
  seven_day_opus: 7 * 24 * 60,
  seven_day_sonnet: 7 * 24 * 60,
  seven_day_overage_included: 7 * 24 * 60,
  overage: null,
};

const WINDOW_NAME = /^[A-Za-z0-9_:/.-]{1,64}$/;

function clampPercent(p: number): number {
  return Math.round(Math.min(100, Math.max(0, p)) * 10) / 10;
}

function isoFromUnixSeconds(v: unknown): string | null {
  const s = asNumber(v);
  if (s === null || s <= 0) return null;
  const ms = s < 1e12 ? s * 1000 : s; // seconds, or already milliseconds
  const d = new Date(ms);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/** Windows from Claude Code's `rate_limit_info`. */
export function claudeRateWindows(info: unknown): RateWindow[] {
  if (!isPlainObject(info)) return [];
  const out = new Map<string, RateWindow>();
  const unified = isPlainObject(info.unifiedWindows) ? info.unifiedWindows : {};
  for (const [name, raw] of Object.entries(unified)) {
    if (!WINDOW_NAME.test(name) || !isPlainObject(raw)) continue;
    const utilization = asNumber(raw.utilization);
    if (utilization === null) continue;
    out.set(name, {
      window: name,
      usedPercent: clampPercent(utilization * 100),
      resetsAt: isoFromUnixSeconds(raw.resetsAt),
      windowMinutes: CLAUDE_WINDOW_MINUTES[name] ?? null,
    });
  }
  // The window that limits right now, when unifiedWindows did not already cover it.
  const type = asString(info.rateLimitType);
  if (type && WINDOW_NAME.test(type) && !out.has(type)) {
    const utilization = asNumber(info.utilization);
    const used = utilization !== null ? utilization * 100 : info.status === "rejected" ? 100 : null;
    if (used !== null) {
      out.set(type, {
        window: type,
        usedPercent: clampPercent(used),
        resetsAt: isoFromUnixSeconds(info.resetsAt),
        windowMinutes: CLAUDE_WINDOW_MINUTES[type] ?? null,
      });
    }
  }
  return [...out.values()];
}

/** A Codex window's name from its length: the usual five-hour and weekly windows by name. */
function codexWindowName(slot: "primary" | "secondary", minutes: number | null): string {
  if (minutes === 300) return "five_hour";
  if (minutes === 7 * 24 * 60) return "seven_day";
  if (minutes === 24 * 60) return "one_day";
  return slot;
}

/** Windows from Codex's `account/rateLimits/updated` params (or a bare RateLimitSnapshot). */
export function codexRateWindows(params: unknown): RateWindow[] {
  if (!isPlainObject(params)) return [];
  const snap = isPlainObject(params.rateLimits) ? params.rateLimits : params;
  // A second limit bucket (not the default one) keeps its windows apart from the default's.
  const limitId = asString(snap.limitId);
  const prefix = limitId && limitId !== "codex" && WINDOW_NAME.test(limitId) ? `${limitId}/` : "";
  const out: RateWindow[] = [];
  for (const slot of ["primary", "secondary"] as const) {
    const w = snap[slot];
    if (!isPlainObject(w)) continue;
    const used = asNumber(w.usedPercent);
    if (used === null) continue;
    const minutes = asNumber(w.windowDurationMins);
    out.push({
      window: `${prefix}${codexWindowName(slot, minutes)}`,
      usedPercent: clampPercent(used),
      resetsAt: isoFromUnixSeconds(w.resetsAt),
      windowMinutes: minutes !== null && minutes >= 0 ? Math.round(minutes) : null,
    });
  }
  return out;
}
