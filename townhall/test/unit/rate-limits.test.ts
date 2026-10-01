import { describe, expect, it } from "vitest";
import { claudeRateWindows, codexRateWindows } from "../../src/providers/common/rate-limits.js";

const RESET = 1_790_700_000; // unix seconds
const RESET_ISO = new Date(RESET * 1000).toISOString();

describe("provider usage windows from the harnesses", () => {
  it("reads every window of Claude Code's rate_limit_info, as percentages", () => {
    const windows = claudeRateWindows({
      status: "allowed_warning",
      resetsAt: RESET,
      rateLimitType: "five_hour",
      utilization: 0.8,
      unifiedWindows: {
        five_hour: { utilization: 0.8123, resetsAt: RESET },
        seven_day: { utilization: 0.21, resetsAt: RESET + 86_400 },
      },
      isUsingOverage: false,
    });
    expect(windows).toEqual([
      { window: "five_hour", usedPercent: 81.2, resetsAt: RESET_ISO, windowMinutes: 300 },
      { window: "seven_day", usedPercent: 21, resetsAt: new Date((RESET + 86_400) * 1000).toISOString(), windowMinutes: 10_080 },
    ]);
  });

  it("falls back to the limiting window, counts a rejection as full and clamps past the cap", () => {
    expect(claudeRateWindows({ status: "allowed", rateLimitType: "seven_day_opus", utilization: 1.4, resetsAt: RESET })).toEqual([
      { window: "seven_day_opus", usedPercent: 100, resetsAt: RESET_ISO, windowMinutes: 10_080 },
    ]);
    expect(claudeRateWindows({ status: "rejected", rateLimitType: "five_hour" })).toEqual([
      { window: "five_hour", usedPercent: 100, resetsAt: null, windowMinutes: 300 },
    ]);
    // An API-key session reports a status only: nothing to show.
    expect(claudeRateWindows({ status: "allowed" })).toEqual([]);
    expect(claudeRateWindows(null)).toEqual([]);
    expect(claudeRateWindows({ unifiedWindows: { "bad name!": { utilization: 0.5 } } })).toEqual([]);
  });

  it("reads Codex's primary and secondary windows and names them by their length", () => {
    const windows = codexRateWindows({
      rateLimits: {
        limitId: "codex",
        limitName: null,
        primary: { usedPercent: 12.5, windowDurationMins: 300, resetsAt: RESET },
        secondary: { usedPercent: 3, windowDurationMins: 10_080, resetsAt: null },
        credits: null,
        planType: "pro",
      },
    });
    expect(windows).toEqual([
      { window: "five_hour", usedPercent: 12.5, resetsAt: RESET_ISO, windowMinutes: 300 },
      { window: "seven_day", usedPercent: 3, resetsAt: null, windowMinutes: 10_080 },
    ]);
    // Other lengths keep their slot's name; a second limit bucket keeps its windows apart.
    expect(codexRateWindows({ rateLimits: { limitId: "codex_other", primary: { usedPercent: 50, windowDurationMins: 60, resetsAt: RESET }, secondary: null } })).toEqual([
      { window: "codex_other/primary", usedPercent: 50, resetsAt: RESET_ISO, windowMinutes: 60 },
    ]);
    expect(codexRateWindows({ rateLimits: { primary: null, secondary: null } })).toEqual([]);
    expect(codexRateWindows("nonsense")).toEqual([]);
  });
});
