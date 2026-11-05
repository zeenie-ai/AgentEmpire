import { createHash } from "node:crypto";
import path from "node:path";
import { fromJson, toJson } from "../db/db.js";
import { fail } from "../protocol/errors.js";
import type {
  Approval,
  ApprovalCategory,
  ApprovalDecision,
  ApprovalMode,
  ApprovalResolvedBy,
  ApprovalScope,
  Risk,
} from "../protocol/objects.js";
import { APPROVAL_PREVIEW_MAX_BYTES, PRE_APPROVAL_TTL_MS } from "../protocol/version.js";
import type { ApprovalAnswer, ApprovalRequest } from "../providers/types.js";
import { capBytes } from "../security/redact.js";
import { reachesOutside, targetInside } from "../security/target-path.js";
import { commandShapeOf } from "./command-shape.js";
import type { Ctx } from "./context.js";
import { incidentKey } from "./incidents.js";

interface ApprovalRow {
  id: string;
  task_id: string;
  agent_id: string;
  attempt: number;
  tool: string;
  category: ApprovalCategory;
  risk: Risk;
  summary: string;
  input_preview: string;
  input_hash: string;
  signature: string;
  /** 1 when a rule from this approval covers only its exact words; null for rows stored before. */
  rule_exact: number | null;
  reason: string | null;
  status: "pending" | "orphaned" | "resolved";
  scopes_json: string;
  seal_exhausted: number;
  decision: ApprovalDecision | null;
  scope: ApprovalScope | null;
  resolved_by: ApprovalResolvedBy | null;
  message: string | null;
  updated_input_json: string | null;
  created_at: string;
  resolved_at: string | null;
}

interface RuleRow {
  id: string;
  kind: "task" | "agent" | "pre_approval";
  decision: ApprovalDecision;
  message: string | null;
}

export interface ApprovalRunContext {
  taskId: string;
  agentId: string;
  attempt: number;
  /** The worktree root the agent must stay inside. */
  workspaceRoot: string;
  /** Where relative paths in tool inputs are resolved from. */
  cwd: string;
  approvalMode: ApprovalMode;
}

interface Waiter {
  taskId: string;
  resolve: (answer: ApprovalAnswer) => void;
}

/** Canonical JSON (sorted keys) so equal inputs hash equally. */
export function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value ?? null);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  const obj = value as Record<string, unknown>;
  return `{${Object.keys(obj)
    .sort()
    .filter((k) => obj[k] !== undefined)
    .map((k) => `${JSON.stringify(k)}:${canonicalJson(obj[k])}`)
    .join(",")}}`;
}

export function inputHash(tool: string, input: unknown): string {
  return createHash("sha256").update(`${tool}\n${canonicalJson(input)}`).digest("hex");
}

/**
 * What an agent-scope or task-scope rule matches: the tool plus a description of the input. For a
 * command, its program and subcommand ("npm run build") or all its words, each command of a chain
 * in turn (see command-shape.ts).
 */
export function signatureOf(tool: string, category: ApprovalCategory, input: unknown): string {
  const obj = (input && typeof input === "object" ? input : {}) as Record<string, unknown>;
  if (category === "command") return commandShapeOf(tool, input).signature;
  if (category === "network") {
    const url = typeof obj.url === "string" ? obj.url : "";
    try {
      return new URL(url).hostname.toLowerCase();
    } catch {
      return tool;
    }
  }
  return tool;
}

/** Actions an approval mode lets through without asking. Outside-workspace actions always ask. */
export function autoAllowed(mode: ApprovalMode, category: ApprovalCategory): boolean {
  if (category === "outside_workspace") return false;
  switch (mode) {
    case "ask_every_time":
      return false;
    case "trusted_edits":
      return category === "read" || category === "write";
    case "plan_first":
      return category === "read";
    case "free_hand":
      return category === "read" || category === "write" || category === "command";
  }
}

const DEFAULT_RISK: Record<ApprovalCategory, Risk> = {
  read: "low",
  write: "low",
  command: "medium",
  network: "medium",
  outside_workspace: "high",
  mcp: "medium",
};

function defaultSummary(tool: string, category: ApprovalCategory, input: unknown): string {
  const obj = (input && typeof input === "object" ? input : {}) as Record<string, unknown>;
  const target = obj.command ?? obj.path ?? obj.file_path ?? obj.url ?? obj.query;
  const verb: Record<ApprovalCategory, string> = {
    read: "Read",
    write: "Write",
    command: "Run",
    network: "Fetch",
    outside_workspace: "Outside the work folder",
    mcp: "Use",
  };
  return typeof target === "string" ? `${verb[category]}: ${target}` : `${verb[category]}: ${tool}`;
}

export class ApprovalService {
  private readonly waiters = new Map<string, Waiter>();

  constructor(private readonly ctx: Ctx) {}

  private row(id: string): ApprovalRow {
    const r = this.ctx.db.get<ApprovalRow>("SELECT * FROM approvals WHERE id = ?", [id]);
    if (!r) throw fail.notFound("approval", id);
    return r;
  }

  toProtocol(r: ApprovalRow): Approval {
    const scopes = fromJson<ApprovalScope[]>(r.scopes_json, ["once"]);
    // What "Allow for this task" and "Always for" would store. An older row's reach is unknown:
    // it is shown as the wider one, never as narrower than it is.
    const rule = scopes.some((s) => s !== "once") ? { signature: this.ctx.redactor.redact(r.signature), exact: r.rule_exact === 1 } : null;
    return {
      id: r.id,
      task_id: r.task_id,
      agent_id: r.agent_id,
      tool: r.tool,
      category: r.category,
      risk: r.risk,
      summary: r.summary,
      input_preview: r.input_preview,
      reason: r.reason,
      status: r.status === "orphaned" ? "orphaned" : "pending",
      scopes,
      rule,
      seal_exhausted: r.seal_exhausted === 1,
      created_at: r.created_at,
    };
  }

  listOpen(): Approval[] {
    return this.ctx.db
      .all<ApprovalRow>("SELECT * FROM approvals WHERE status IN ('pending','orphaned') ORDER BY created_at ASC")
      .map((r) => this.toProtocol(r));
  }

  pendingCount(taskId: string): number {
    return (
      this.ctx.db.get<{ n: number }>("SELECT COUNT(*) AS n FROM approvals WHERE task_id = ? AND status = 'pending'", [taskId])
        ?.n ?? 0
    );
  }

  orphanedCount(taskId: string): number {
    return (
      this.ctx.db.get<{ n: number }>("SELECT COUNT(*) AS n FROM approvals WHERE task_id = ? AND status = 'orphaned'", [taskId])
        ?.n ?? 0
    );
  }

  /**
   * Treats a call that names a place outside the worktree (any path field, search folder or glob
   * pattern, read the way the harness reads it, links followed) as an outside-workspace action,
   * and so a command chain whose leading `cd` leaves it.
   */
  private effectiveCategory(req: ApprovalRequest, run: ApprovalRunContext): ApprovalCategory {
    if (req.category === "outside_workspace") return req.category;
    const scope = { cwd: run.cwd, root: run.workspaceRoot, write: req.category === "write" };
    if (reachesOutside(req.tool, req.input, scope)) return "outside_workspace";
    const folder = req.category === "command" ? commandShapeOf(req.tool, req.input).folder : null;
    if (folder !== null) {
      // The shell starts where the command runs: Codex names that folder, the others run in the agent's.
      const cwd = (req.input as Record<string, unknown>).cwd;
      const from = typeof cwd === "string" ? path.resolve(run.cwd, cwd) : run.cwd;
      // bash reads /c/... as C:\ in Git Bash.
      if (!targetInside(folder, { cwd: from, root: run.workspaceRoot }, { drives: "letter" })) return "outside_workspace";
    }
    return req.category;
  }

  private insertResolved(run: ApprovalRunContext, req: ApprovalRequest, category: ApprovalCategory, hash: string, signature: string, exact: boolean, decision: ApprovalDecision, by: ApprovalResolvedBy, message: string | null): string {
    const id = this.ctx.ids.next("apv");
    const now = this.ctx.clock.iso();
    this.ctx.db.run(
      `INSERT INTO approvals (id, task_id, agent_id, attempt, tool, category, risk, summary, input_preview, input_hash, signature,
         rule_exact, reason, status, scopes_json, decision, scope, resolved_by, message, created_at, resolved_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'resolved', ?, ?, 'once', ?, ?, ?, ?)`,
      [
        id,
        run.taskId,
        run.agentId,
        run.attempt,
        req.tool,
        category,
        req.risk ?? DEFAULT_RISK[category],
        this.ctx.redactor.redact(req.summary ?? defaultSummary(req.tool, category, req.input)),
        this.preview(req.input),
        hash,
        signature,
        exact ? 1 : 0,
        req.reason ?? null,
        toJson(["once"]),
        decision,
        by,
        message,
        now,
        now,
      ],
    );
    this.ctx.bus.emit("approval_resolved", { approval_id: id, decision, scope: "once", by }, `approval/${id}`);
    return id;
  }

  private preview(input: unknown): string {
    let text: string;
    try {
      text = JSON.stringify(input ?? null, null, 2);
    } catch {
      text = String(input);
    }
    return capBytes(this.ctx.redactor.redact(text), APPROVAL_PREVIEW_MAX_BYTES);
  }

  /**
   * Called by a running adapter through RunHost. Applies the approval mode, single-use
   * pre-approvals and task/agent rules; otherwise creates a pending approval and waits.
   */
  async request(run: ApprovalRunContext, req: ApprovalRequest): Promise<ApprovalAnswer> {
    const category = this.effectiveCategory(req, run);
    const hash = inputHash(req.tool, req.input);
    const signature = signatureOf(req.tool, category, req.input);
    // High risk asks in every mode, and no rule passes it. A command counts as high risk unless it
    // is simple (see command-shape.ts), and so do commands that can destroy work or reach far.
    const shape = category === "command" ? commandShapeOf(req.tool, req.input) : null;
    const risk: Risk =
      req.risk === "high" || DEFAULT_RISK[category] === "high" || shape?.risk === "high" ? "high" : (req.risk ?? DEFAULT_RISK[category]);
    const rated = { ...req, risk };
    // A command rule covers only these words, or further arguments too; other rules cover a host or a tool.
    const exact = shape?.exact ?? false;

    const auto = this.ctx.db.tx((): ApprovalAnswer | null => {
      const now = this.ctx.clock.iso();
      const pre = this.ctx.db.get<RuleRow>(
        `SELECT id, kind, decision, message FROM approval_rules
         WHERE kind = 'pre_approval' AND agent_id = ? AND tool = ? AND input_hash = ? AND uses_left > 0 AND expires_at > ?
         ORDER BY created_at DESC LIMIT 1`,
        [run.agentId, req.tool, hash, now],
      );
      if (pre) {
        // The player's own answer to this exact call, given after a restart.
        this.ctx.db.run("UPDATE approval_rules SET uses_left = 0, used_at = ? WHERE id = ?", [now, pre.id]);
        this.insertResolved(run, rated, category, hash, signature, exact, pre.decision, "pre_approval", pre.message);
        return { decision: pre.decision, ...(pre.message ? { message: pre.message } : {}) };
      }
      if (risk === "high") return null;
      if (autoAllowed(run.approvalMode, category)) return { decision: "allow" };
      const rule = this.ctx.db.get<RuleRow>(
        `SELECT id, kind, decision, message FROM approval_rules
         WHERE tool = ? AND category = ? AND signature = ?
           AND ((kind = 'task' AND task_id = ?) OR (kind = 'agent' AND agent_id = ?))
         ORDER BY CASE kind WHEN 'task' THEN 0 ELSE 1 END, created_at DESC LIMIT 1`,
        [req.tool, category, signature, run.taskId, run.agentId],
      );
      if (rule) {
        this.insertResolved(run, rated, category, hash, signature, exact, rule.decision, "rule", rule.message);
        return { decision: rule.decision, ...(rule.message ? { message: rule.message } : {}) };
      }
      return null;
    });
    if (auto) return auto;

    const id = this.ctx.ids.next("apv");
    const scopes: ApprovalScope[] = risk === "high" ? ["once"] : ["once", "task", "agent"];
    this.ctx.db.tx(() => {
      const task = this.ctx.tasks.row(run.taskId);
      const summary = this.ctx.redactor.redact(req.summary ?? defaultSummary(req.tool, category, req.input));
      this.ctx.db.run(
        `INSERT INTO approvals (id, task_id, agent_id, attempt, tool, category, risk, summary, input_preview, input_hash, signature,
           rule_exact, reason, status, scopes_json, seal_exhausted, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)`,
        [
          id,
          run.taskId,
          run.agentId,
          run.attempt,
          req.tool,
          category,
          risk,
          summary,
          this.preview(req.input),
          hash,
          signature,
          exact ? 1 : 0,
          req.reason ? this.ctx.redactor.redact(req.reason) : null,
          toJson(scopes),
          task.spent_micros >= task.seal_micros ? 1 : 0,
          this.ctx.clock.iso(),
        ],
      );
      this.ctx.bus.emit("approval_requested", { approval: this.toProtocol(this.row(id)) }, `approval/${id}`);
      this.ctx.incidents.open("hand_bell", incidentKey.handApproval(id), {
        severity: "warn",
        message: summary,
        agentId: run.agentId,
        taskId: run.taskId,
      });
      this.ctx.tasks.onApprovalPending(run.taskId);
    });
    return new Promise<ApprovalAnswer>((resolve) => this.waiters.set(id, { taskId: run.taskId, resolve }));
  }

  respond(input: {
    approval_id: string;
    decision: ApprovalDecision;
    scope: ApprovalScope;
    message?: string | undefined;
    updated_input?: unknown;
  }): void {
    let wake: (() => void) | null = null;
    let resumeTaskId: string | null = null;
    this.ctx.db.tx(() => {
      const r = this.row(input.approval_id);
      if (r.status === "resolved") return; // the first reply wins
      const scopes = fromJson<ApprovalScope[]>(r.scopes_json, ["once"]);
      if (!scopes.includes(input.scope)) throw fail.badRequest(`scope ${input.scope} is not offered for this approval`);
      const now = this.ctx.clock.iso();
      const message = input.message ?? null;
      this.ctx.db.run(
        "UPDATE approvals SET status = 'resolved', decision = ?, scope = ?, resolved_by = 'player', message = ?, updated_input_json = ?, resolved_at = ? WHERE id = ?",
        [
          input.decision,
          input.scope,
          message,
          input.updated_input === undefined ? null : toJson(input.updated_input),
          now,
          r.id,
        ],
      );
      this.ctx.bus.emit(
        "approval_resolved",
        { approval_id: r.id, decision: input.decision, scope: input.scope, by: "player" },
        `approval/${r.id}`,
      );
      this.ctx.incidents.resolve(incidentKey.handApproval(r.id));
      if (input.scope !== "once") {
        this.ctx.db.run(
          `INSERT INTO approval_rules (id, kind, agent_id, task_id, tool, category, signature, decision, message, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          [
            this.ctx.ids.next("rule"),
            input.scope,
            r.agent_id,
            input.scope === "task" ? r.task_id : null,
            r.tool,
            r.category,
            r.signature,
            input.decision,
            message,
            now,
          ],
        );
      }
      if (r.status === "pending") {
        const waiter = this.waiters.get(r.id);
        this.waiters.delete(r.id);
        if (waiter) {
          const answer: ApprovalAnswer = {
            decision: input.decision,
            ...(message ? { message } : {}),
            ...(input.updated_input !== undefined ? { updatedInput: input.updated_input } : {}),
          };
          wake = () => waiter.resolve(answer);
        }
        this.ctx.tasks.onApprovalResolved(r.task_id);
      } else {
        // Orphaned by a restart: remember the answer for the call the resumed session re-issues.
        this.ctx.db.run(
          `INSERT INTO approval_rules (id, kind, agent_id, task_id, tool, category, signature, input_hash, decision, message, uses_left, expires_at, created_at)
           VALUES (?, 'pre_approval', ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)`,
          [
            this.ctx.ids.next("rule"),
            r.agent_id,
            r.task_id,
            r.tool,
            r.category,
            r.signature,
            r.input_hash,
            input.decision,
            message,
            new Date(this.ctx.clock.now() + PRE_APPROVAL_TTL_MS).toISOString(),
            now,
          ],
        );
        if (this.orphanedCount(r.task_id) === 0) resumeTaskId = r.task_id;
      }
    });
    if (wake) (wake as () => void)();
    if (resumeTaskId) this.ctx.tasks.resumeAfterOrphan(resumeTaskId);
  }

  /** Withdraws open approvals of a task (the run is stopping). Their waiters get a deny. */
  cancelForTask(taskId: string, by: "cancelled" | "restart"): void {
    const wakes: Array<() => void> = [];
    this.ctx.db.tx(() => {
      const rows = this.ctx.db.all<ApprovalRow>(
        "SELECT * FROM approvals WHERE task_id = ? AND status IN ('pending','orphaned')",
        [taskId],
      );
      for (const r of rows) {
        this.ctx.db.run(
          "UPDATE approvals SET status = 'resolved', decision = 'deny', scope = 'once', resolved_by = ?, resolved_at = ? WHERE id = ?",
          [by, this.ctx.clock.iso(), r.id],
        );
        this.ctx.bus.emit("approval_resolved", { approval_id: r.id, decision: "deny", scope: "once", by }, `approval/${r.id}`);
        this.ctx.incidents.resolve(incidentKey.handApproval(r.id));
        const waiter = this.waiters.get(r.id);
        this.waiters.delete(r.id);
        if (waiter) wakes.push(() => waiter.resolve({ decision: "deny", cancelled: true }));
      }
    });
    for (const w of wakes) w();
  }

  /** After a restart no session is waiting any more; pending approvals become orphaned. */
  orphanAllPending(): void {
    this.ctx.db.tx(() => {
      const rows = this.ctx.db.all<ApprovalRow>("SELECT * FROM approvals WHERE status = 'pending'");
      for (const r of rows) {
        this.ctx.db.run("UPDATE approvals SET status = 'orphaned' WHERE id = ?", [r.id]);
        this.ctx.bus.emit("approval_requested", { approval: this.toProtocol(this.row(r.id)) }, `approval/${r.id}`);
      }
    });
  }

  /** The player resumed the task without answering: the resumed session will ask again. */
  supersedeOrphaned(taskId: string): void {
    this.ctx.db.tx(() => {
      const rows = this.ctx.db.all<ApprovalRow>("SELECT * FROM approvals WHERE task_id = ? AND status = 'orphaned'", [taskId]);
      for (const r of rows) {
        this.ctx.db.run(
          "UPDATE approvals SET status = 'resolved', decision = 'deny', scope = 'once', resolved_by = 'restart', resolved_at = ? WHERE id = ?",
          [this.ctx.clock.iso(), r.id],
        );
        this.ctx.bus.emit("approval_resolved", { approval_id: r.id, decision: "deny", scope: "once", by: "restart" }, `approval/${r.id}`);
        this.ctx.incidents.resolve(incidentKey.handApproval(r.id));
      }
    });
  }
}
