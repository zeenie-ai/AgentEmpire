import { fromJson, toJson } from "../db/db.js";
import type { Settings } from "../protocol/objects.js";
import type { Ctx } from "./context.js";

export const DEFAULT_SETTINGS: Settings = {
  work_while_away: true,
  express_dispatch: false,
  lantern_hours: { start: 20, end: 7 },
};

type SettingKey = keyof Settings;

export class SettingsService {
  constructor(private readonly ctx: Ctx) {}

  get(): Settings {
    const rows = this.ctx.db.all<{ key: string; value_json: string }>("SELECT key, value_json FROM settings");
    const out: Settings = structuredClone(DEFAULT_SETTINGS);
    for (const r of rows) {
      if (r.key in out) (out as Record<string, unknown>)[r.key] = JSON.parse(r.value_json) as unknown;
    }
    return out;
  }

  set<K extends SettingKey>(key: K, value: Settings[K]): Settings {
    this.ctx.db.tx(() => {
      this.ctx.db.run(
        "INSERT INTO settings (key, value_json) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json",
        [key, toJson(value)],
      );
    });
    if (key === "work_while_away") this.ctx.scheduler.kick();
    return this.get();
  }

  /** Internal Town Hall state (not player settings). */
  getState<T>(key: string, fallback: T): T {
    const row = this.ctx.db.get<{ value_json: string }>("SELECT value_json FROM town_state WHERE key = ?", [key]);
    return fromJson(row?.value_json, fallback);
  }

  setState(key: string, value: unknown): void {
    this.ctx.db.run(
      "INSERT INTO town_state (key, value_json) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json",
      [key, toJson(value)],
    );
  }
}
