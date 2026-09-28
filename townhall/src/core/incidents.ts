import type { Incident, IncidentKind, IncidentSeverity } from "../protocol/objects.js";
import type { Ctx } from "./context.js";

interface IncidentRow {
  id: string;
  kind: IncidentKind;
  severity: IncidentSeverity;
  agent_id: string | null;
  task_id: string | null;
  key: string;
  message: string;
  opened_at: string;
  resolved_at: string | null;
}

export interface OpenIncident {
  severity: IncidentSeverity;
  message: string;
  agentId?: string | null;
  taskId?: string | null;
}

/** Keys identify one open incident per condition, so opening twice is a no-op. */
export const incidentKey = {
  smoke: (taskId: string) => `smoke:${taskId}`,
  alarm: (taskId: string) => `alarm:${taskId}`,
  handApproval: (approvalId: string) => `hand:${approvalId}`,
  handSeal: (taskId: string) => `hand:seal:${taskId}`,
  dimLanterns: () => "dim_lanterns",
  fontDark: () => "font_dark",
  fontDarkProvider: (provider: string) => `font_dark:provider:${provider}`,
  rift: (taskId: string) => `rift:${taskId}`,
  merge: (taskId: string) => `merge:${taskId}`,
};

function toIncident(r: IncidentRow): Incident {
  return {
    id: r.id,
    kind: r.kind,
    severity: r.severity,
    subject: { agent_id: r.agent_id, task_id: r.task_id },
    message: r.message,
    opened_at: r.opened_at,
  };
}

export class IncidentService {
  constructor(private readonly ctx: Ctx) {}

  open(kind: IncidentKind, key: string, spec: OpenIncident): Incident {
    return this.ctx.db.tx(() => {
      const existing = this.ctx.db.get<IncidentRow>("SELECT * FROM incidents WHERE key = ? AND resolved_at IS NULL", [
        key,
      ]);
      if (existing) return toIncident(existing);
      const row: IncidentRow = {
        id: this.ctx.ids.next("inc"),
        kind,
        severity: spec.severity,
        agent_id: spec.agentId ?? null,
        task_id: spec.taskId ?? null,
        key,
        message: this.ctx.redactor.redact(spec.message),
        opened_at: this.ctx.clock.iso(),
        resolved_at: null,
      };
      this.ctx.db.run(
        "INSERT INTO incidents (id, kind, severity, agent_id, task_id, key, message, opened_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [row.id, row.kind, row.severity, row.agent_id, row.task_id, row.key, row.message, row.opened_at],
      );
      const incident = toIncident(row);
      this.ctx.bus.emit("incident_opened", { incident }, `incident/${row.id}`);
      return incident;
    });
  }

  resolve(key: string): boolean {
    return this.ctx.db.tx(() => {
      const row = this.ctx.db.get<IncidentRow>("SELECT * FROM incidents WHERE key = ? AND resolved_at IS NULL", [key]);
      if (!row) return false;
      this.ctx.db.run("UPDATE incidents SET resolved_at = ? WHERE id = ?", [this.ctx.clock.iso(), row.id]);
      this.ctx.bus.emit("incident_resolved", { incident_id: row.id }, `incident/${row.id}`);
      return true;
    });
  }

  resolveForTask(taskId: string, kinds: IncidentKind[]): void {
    this.ctx.db.tx(() => {
      const rows = this.ctx.db.all<IncidentRow>(
        "SELECT * FROM incidents WHERE task_id = ? AND resolved_at IS NULL",
        [taskId],
      );
      for (const r of rows) if (kinds.includes(r.kind)) this.resolve(r.key);
    });
  }

  isOpen(key: string): boolean {
    return !!this.ctx.db.get("SELECT id FROM incidents WHERE key = ? AND resolved_at IS NULL", [key]);
  }

  listOpen(): Incident[] {
    return this.ctx.db
      .all<IncidentRow>("SELECT * FROM incidents WHERE resolved_at IS NULL ORDER BY opened_at ASC")
      .map(toIncident);
  }
}
