import { fail } from "../protocol/errors.js";
import { TOWN_SAVES_KEPT } from "../protocol/version.js";
import type { Ctx } from "./context.js";

interface SaveRow {
  rev: number;
  schema_version: number;
  snapshot_json: string;
  created_at: string;
}

/** Client simulation saves (map, units, buildings) with optimistic revision checks. */
export class TownService {
  constructor(private readonly ctx: Ctx) {}

  latestRef(): { rev: number; schema_version: number } | null {
    const row = this.ctx.db.get<{ rev: number; schema_version: number }>(
      "SELECT rev, schema_version FROM town_saves ORDER BY rev DESC LIMIT 1",
    );
    return row ?? null;
  }

  save(baseRev: number, schemaVersion: number, snapshot: unknown): { rev: number } {
    if (snapshot === undefined) throw fail.badRequest("snapshot is required");
    return this.ctx.db.tx(() => {
      const latest = this.latestRef()?.rev ?? 0;
      if (baseRev !== latest) throw fail.conflict(`base_rev ${baseRev} is stale; the latest save is rev ${latest}`);
      const rev = latest + 1;
      this.ctx.db.run("INSERT INTO town_saves (rev, schema_version, snapshot_json, created_at) VALUES (?, ?, ?, ?)", [
        rev,
        schemaVersion,
        JSON.stringify(snapshot),
        this.ctx.clock.iso(),
      ]);
      this.ctx.db.run("DELETE FROM town_saves WHERE rev <= ?", [rev - TOWN_SAVES_KEPT]);
      this.ctx.bus.emit("town_saved", { rev }, "town");
      return { rev };
    });
  }

  load(): { rev: number; schema_version: number; snapshot: unknown } | null {
    const row = this.ctx.db.get<SaveRow>("SELECT * FROM town_saves ORDER BY rev DESC LIMIT 1");
    if (!row) return null;
    return { rev: row.rev, schema_version: row.schema_version, snapshot: JSON.parse(row.snapshot_json) as unknown };
  }
}
