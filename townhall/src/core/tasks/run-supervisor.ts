import { toJson } from "../../db/db.js";
import { isTownError } from "../../protocol/errors.js";
import type { PauseReason, ProgressPhase, TaskResult } from "../../protocol/objects.js";
import { TASK_PROGRESS_MIN_INTERVAL_MS } from "../../protocol/version.js";
import type { RunEvent, RunHandle, RunHost, RunOutcome, RunRequest } from "../../providers/types.js";
import { canonicalJson } from "../approvals.js";
import type { AgentRow } from "../agents.js";
import type { TimerHandle } from "../clock.js";
import type { Ctx } from "../context.js";
import type { Size } from "../economy.js";
import { incidentKey } from "../incidents.js";
import type { TaskWorkspace } from "../workspace.js";
import type { TaskRow } from "./task-service.js";

export type StopRequest =
  | { kind: "pause"; reason: PauseReason }
  | { kind: "cancel" }
  | { kind: "stop_review" };

/** A rift (crash or expired login) is retried automatically once. */
const RIFT_AUTO_RETRIES = 1;
const ACTIVITY_PER_SECOND = 10;

const STOP_PRIORITY: Record<StopRequest["kind"], number> = { pause: 1, stop_review: 2, cancel: 3 };

interface ActiveRun {
  taskId: string;
  agentId: string;
  provider: AgentRow["provider"];
  attempt: number;
  size: Size;
  handle: RunHandle | null;
  abort: AbortController;
  /** Aborted when the run is asked to stop or has ended: ends a party lead's wait for its members. */
  stopped: AbortController;
  stop: StopRequest | null;
  workspace: TaskWorkspace | null;
  ended: boolean;
  pendingApprovals: number;
  waitingChildren: number;
  stuckTimer: TimerHandle | null;
  pauseTimer: TimerHandle | null;
  killTimer: TimerHandle | null;
  silenceAlarm: boolean;
  lastToolKey: string | null;
  repeatCount: number;
  repeatAlarm: boolean;
  filesTouched: Set<string>;
  currentTool: string | null;
  phase: ProgressPhase;
  progressSentAt: number;
  progressTimer: TimerHandle | null;
  activityWindowStart: number;
  activityCount: number;
  activityDropped: number;
}

function withTimeout<T>(p: Promise<T>, ms: number, signal: AbortSignal, schedule: (fn: () => void, ms: number) => TimerHandle, cancel: (h: TimerHandle) => void): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = schedule(() => reject(new Error(`preparation timed out after ${Math.round(ms / 1000)} s`)), ms);
    const onAbort = () => {
      cancel(timer);
      reject(new Error("preparation stopped"));
    };
    if (signal.aborted) onAbort();
    signal.addEventListener("abort", onAbort, { once: true });
    p.then(
      (v) => {
        cancel(timer);
        signal.removeEventListener("abort", onAbort);
        resolve(v);
      },
      (e: unknown) => {
        cancel(timer);
        signal.removeEventListener("abort", onAbort);
        reject(e instanceof Error ? e : new Error(String(e)));
      },
    );
  });
}

export class RunSupervisor {
  private readonly runs = new Map<string, ActiveRun>();
  private stopping = false;

  constructor(private readonly ctx: Ctx) {}

  isActive(taskId: string): boolean {
    return this.runs.has(taskId);
  }

  activeCount(): number {
    return this.runs.size;
  }

  // ---------- starting ----------

  /** Called by the scheduler once the task is `preparing` and Mana is reserved. */
  async start(taskId: string): Promise<void> {
    const task = this.ctx.tasks.row(taskId);
    const agent = this.ctx.agents.row(task.agent_id);
    const run: ActiveRun = {
      taskId,
      agentId: agent.id,
      provider: agent.provider,
      attempt: task.attempt,
      size: task.size as Size,
      handle: null,
      abort: new AbortController(),
      stopped: new AbortController(),
      stop: null,
      workspace: null,
      ended: false,
      pendingApprovals: 0,
      waitingChildren: 0,
      stuckTimer: null,
      pauseTimer: null,
      killTimer: null,
      silenceAlarm: false,
      lastToolKey: null,
      repeatCount: 0,
      repeatAlarm: false,
      filesTouched: new Set(),
      currentTool: null,
      phase: "preparing",
      progressSentAt: 0,
      progressTimer: null,
      activityWindowStart: 0,
      activityCount: 0,
      activityDropped: 0,
    };
    this.runs.set(taskId, run);
    this.progress(run, "preparing");

    let ws: TaskWorkspace;
    const prep = this.ctx.workspace.prepareTask(task, agent);
    try {
      ws = await withTimeout(
        prep,
        this.ctx.econ.data.incidents.preparing_timeout_s * 1000,
        run.abort.signal,
        (fn, ms) => this.ctx.clock.setTimeout(fn, ms),
        (h) => this.ctx.clock.clearTimeout(h),
      );
    } catch (err) {
      // Keep a late-finishing worktree so a later attempt reuses it.
      prep.then((late) => this.ctx.db.tx(() => {
        const cur = this.ctx.tasks.rowOrNull(taskId);
        if (cur && !cur.workspace_json) this.ctx.tasks.saveWorkspace(taskId, late);
      }), () => undefined);
      this.runs.delete(taskId);
      this.clearTimers(run);
      if (this.stopping) return;
      if (run.stop) this.applyStop(taskId, run.stop, null);
      else this.failTask(taskId, isTownError(err) ? err.code : "INTERNAL", err instanceof Error ? err.message : String(err));
      this.ctx.scheduler.kick();
      return;
    }
    run.workspace = ws;

    const request = this.ctx.db.tx((): RunRequest | null => {
      this.ctx.tasks.saveWorkspace(taskId, ws);
      const cur = this.ctx.tasks.row(taskId);
      if (cur.state !== "preparing" || run.stop || this.stopping) return null;
      // Build the request before the pending feedback is consumed below.
      const req = this.buildRequest(cur, this.ctx.agents.row(agent.id), ws);
      this.ctx.tasks.setState(taskId, "running");
      const now = this.ctx.clock.iso();
      this.ctx.db.run(
        "UPDATE tasks SET started_at = COALESCE(started_at, ?), run_started_at = ?, pending_feedback = NULL WHERE id = ?",
        [now, now, taskId],
      );
      this.ctx.incidents.resolve(incidentKey.rift(taskId));
      return req;
    });
    if (!request) {
      this.runs.delete(taskId);
      this.clearTimers(run);
      if (!this.stopping && run.stop) this.applyStop(taskId, run.stop, ws);
      this.ctx.scheduler.kick();
      return;
    }

    let handle: RunHandle;
    try {
      handle = this.ctx.providers.get(agent.provider).start(request, this.hostFor(run, ws, agent));
    } catch (err) {
      void this.onRunEnded(run, {
        kind: "failed",
        error: { code: "PROVIDER_UNAVAILABLE", message: err instanceof Error ? err.message : String(err), transient: false },
      });
      return;
    }
    run.handle = handle;
    this.progress(run, "working");
    this.armStallTimers(run);
    handle.done.then(
      (outcome) => void this.onRunEnded(run, outcome),
      (err: unknown) =>
        void this.onRunEnded(run, { kind: "failed", error: { code: "crash", message: String(err), transient: true } }),
    );
    if (run.stop) this.sendInterrupt(run);
  }

  private buildRequest(task: TaskRow, agent: AgentRow, ws: TaskWorkspace): RunRequest {
    const fresh = this.ctx.tasks.row(task.id);
    const hasResume = !!(fresh.session_id || fresh.provider_state_json || fresh.pending_feedback);
    let party: RunRequest["party"] = null;
    if (fresh.party_id && fresh.depth === 0) {
      party = {
        partyId: fresh.party_id,
        members: this.ctx.parties.members(fresh.party_id).map((m) => ({
          agentId: m.id,
          name: m.name,
          provider: m.provider,
          role: m.role,
        })),
      };
    }
    return {
      taskId: fresh.id,
      agentId: agent.id,
      attempt: fresh.attempt,
      provider: agent.provider,
      model: agent.model,
      role: agent.role,
      size: fresh.size,
      cwd: ws.cwd,
      workspaceRoot: ws.worktree,
      title: fresh.title,
      prompt: fresh.prompt,
      acceptance: JSON.parse(fresh.acceptance_json) as string[],
      instructions: agent.instructions,
      approvalMode: agent.approval_mode,
      tools: [...this.ctx.tools.activeTypes(agent.id)],
      waygates: this.ctx.tools.waygateConfigs(agent.id),
      budget: { sealMicros: fresh.seal_micros, spentMicros: fresh.spent_micros },
      resume: hasResume
        ? {
            sessionId: fresh.session_id,
            state: fresh.provider_state_json ? (JSON.parse(fresh.provider_state_json) as unknown) : null,
            feedback: fresh.pending_feedback,
          }
        : null,
      party,
      depth: fresh.depth,
    };
  }

  private hostFor(run: ActiveRun, ws: TaskWorkspace, agent: AgentRow): RunHost {
    return {
      taskId: run.taskId,
      clock: this.ctx.clock,
      emit: (event) => this.onRunEvent(run, event),
      requestApproval: async (req) => {
        if (run.ended || run.stop) return { decision: "deny", cancelled: true };
        run.pendingApprovals++;
        this.suspendStall(run);
        try {
          const mode = this.ctx.agents.row(agent.id).approval_mode;
          return await this.ctx.approvals.request(
            {
              taskId: run.taskId,
              agentId: run.agentId,
              attempt: run.attempt,
              workspaceRoot: ws.worktree,
              cwd: ws.cwd,
              approvalMode: mode,
            },
            req,
          );
        } finally {
          run.pendingApprovals--;
          this.touch(run);
        }
      },
      delegate: async (req) => {
        const handle = this.ctx.parties.delegate(run.taskId, run.agentId, req);
        this.progress(run, "delegating");
        return {
          taskId: handle.taskId,
          wait: async (timeoutMs?: number) => {
            run.waitingChildren++;
            this.suspendStall(run);
            try {
              return await handle.wait(timeoutMs);
            } finally {
              run.waitingChildren--;
              this.progress(run, "working");
              this.touch(run);
            }
          },
        };
      },
      partyStatus: () => this.ctx.parties.status(run.taskId),
      waitSubtasks: async (taskIds, timeoutMs) => {
        // Waiting on the party is not silence: no stall alarm while members work.
        run.waitingChildren++;
        this.suspendStall(run);
        this.progress(run, "delegating");
        try {
          return await this.ctx.parties.waitAll(run.taskId, taskIds, timeoutMs, run.stopped.signal);
        } finally {
          run.waitingChildren--;
          this.progress(run, "working");
          this.touch(run);
        }
      },
      checkpoint: (state) => {
        if (run.ended) return;
        this.ctx.db.run("UPDATE tasks SET provider_state_json = ? WHERE id = ?", [toJson(state), run.taskId]);
      },
    };
  }

  // ---------- events from the adapter ----------

  private onRunEvent(run: ActiveRun, ev: RunEvent): void {
    if (run.ended) return;
    try {
      switch (ev.kind) {
        case "activity":
          this.activity(run, ev.activity, ev.text);
          break;
        case "tool_start": {
          run.currentTool = ev.tool;
          this.trackRepeat(run, `${ev.tool}\n${canonicalJson(ev.input ?? null)}`);
          this.activity(run, "tool_start", ev.text ?? ev.tool);
          this.progress(run, "tool");
          break;
        }
        case "tool_end":
          run.currentTool = null;
          this.activity(run, "tool_end", ev.text ?? `${ev.tool} ${ev.ok ? "done" : "failed"}`);
          this.progress(run, "working");
          break;
        case "usage": {
          const agent = this.ctx.agents.row(run.agentId);
          const res = this.ctx.mana.charge(run.taskId, run.provider, Math.max(0, Math.round(ev.costMicros)), ev.estimate ?? agent.billing === "subscription");
          this.progress(run, run.phase);
          if (res.sealWarning) this.activity(run, "system", "The Mana Seal is 80% spent.");
          if (res.sealExhausted) {
            this.activity(run, "system", "The Mana Seal is spent; the task pauses.");
            this.interrupt(run.taskId, { kind: "pause", reason: "budget" });
          }
          break;
        }
        case "session":
          this.ctx.db.tx(() => {
            this.ctx.db.run("UPDATE tasks SET session_id = ? WHERE id = ?", [ev.sessionId, run.taskId]);
          });
          break;
        case "files_touched":
          for (const p of ev.paths) run.filesTouched.add(p);
          this.progress(run, run.phase);
          break;
        case "rate_limits":
          this.ctx.mana.updateProviderWindows(run.provider, ev.windows);
          break;
      }
    } catch (err) {
      this.ctx.log.error({ taskId: run.taskId, err: String(err) }, "run event failed");
    }
    this.touch(run);
  }

  private activity(run: ActiveRun, kind: "message" | "system" | "error" | "tool_start" | "tool_end", text: string): void {
    const now = this.ctx.clock.now();
    if (now - run.activityWindowStart >= 1000) {
      if (run.activityDropped > 0) {
        this.ctx.tasks.appendActivity(run.taskId, "system", `${run.activityDropped} activity entries were not broadcast`, true);
      }
      run.activityWindowStart = now;
      run.activityCount = 0;
      run.activityDropped = 0;
    }
    const broadcast = run.activityCount < ACTIVITY_PER_SECOND;
    if (broadcast) run.activityCount++;
    else run.activityDropped++;
    this.ctx.tasks.appendActivity(run.taskId, kind, text, broadcast);
  }

  private progress(run: ActiveRun, phase: ProgressPhase): void {
    run.phase = phase;
    const now = this.ctx.clock.now();
    const since = now - run.progressSentAt;
    if (since >= TASK_PROGRESS_MIN_INTERVAL_MS) {
      this.emitProgress(run);
    } else if (!run.progressTimer) {
      run.progressTimer = this.ctx.clock.setTimeout(() => {
        run.progressTimer = null;
        this.emitProgress(run);
      }, TASK_PROGRESS_MIN_INTERVAL_MS - since);
    }
  }

  private emitProgress(run: ActiveRun): void {
    const t = this.ctx.tasks.rowOrNull(run.taskId);
    if (!t) return;
    run.progressSentAt = this.ctx.clock.now();
    this.ctx.bus.emit(
      "task_progress",
      {
        task_id: run.taskId,
        phase: run.phase,
        current_tool: run.currentTool,
        files_touched: run.filesTouched.size,
        spent_micros: t.spent_micros,
      },
      `task/${run.taskId}`,
    );
  }

  // ---------- stall detection ----------

  private trackRepeat(run: ActiveRun, key: string): void {
    if (key === run.lastToolKey) run.repeatCount++;
    else {
      run.lastToolKey = key;
      run.repeatCount = 1;
      if (run.repeatAlarm) {
        run.repeatAlarm = false;
        if (!run.silenceAlarm) this.ctx.incidents.resolve(incidentKey.alarm(run.taskId));
      }
    }
    if (run.repeatCount >= this.ctx.econ.data.incidents.repeat_tool_calls && !run.repeatAlarm) {
      run.repeatAlarm = true;
      this.ctx.incidents.open("alarm_bell", incidentKey.alarm(run.taskId), {
        severity: "warn",
        message: "The agent keeps repeating the same action",
        agentId: run.agentId,
        taskId: run.taskId,
      });
    }
  }

  private touch(run: ActiveRun): void {
    if (run.ended) return;
    if (run.silenceAlarm) {
      run.silenceAlarm = false;
      if (!run.repeatAlarm) this.ctx.incidents.resolve(incidentKey.alarm(run.taskId));
    }
    this.armStallTimers(run);
  }

  private suspendStall(run: ActiveRun): void {
    this.ctx.clock.clearTimeout(run.stuckTimer);
    this.ctx.clock.clearTimeout(run.pauseTimer);
    run.stuckTimer = null;
    run.pauseTimer = null;
  }

  private armStallTimers(run: ActiveRun): void {
    this.suspendStall(run);
    if (run.ended || run.stop || !run.handle || run.pendingApprovals > 0 || run.waitingChildren > 0) return;
    const inc = this.ctx.econ.data.incidents;
    const stuckMs = inc.stuck_minutes_by_size[run.size] * 60_000;
    const pauseMs = inc.stall_pause_minutes * 60_000;
    run.stuckTimer = this.ctx.clock.setTimeout(() => {
      run.stuckTimer = null;
      if (run.ended) return;
      run.silenceAlarm = true;
      this.ctx.incidents.open("alarm_bell", incidentKey.alarm(run.taskId), {
        severity: "warn",
        message: `No activity for ${inc.stuck_minutes_by_size[run.size]} minutes`,
        agentId: run.agentId,
        taskId: run.taskId,
      });
    }, stuckMs);
    run.pauseTimer = this.ctx.clock.setTimeout(() => {
      run.pauseTimer = null;
      if (run.ended) return;
      run.silenceAlarm = true;
      this.ctx.incidents.open("alarm_bell", incidentKey.alarm(run.taskId), {
        severity: "urgent",
        message: `No activity for ${inc.stall_pause_minutes} minutes; the task was paused`,
        agentId: run.agentId,
        taskId: run.taskId,
      });
      this.interrupt(run.taskId, { kind: "pause", reason: "stalled" });
    }, pauseMs);
  }

  // ---------- stopping ----------

  /** Asks a live run to stop. Returns false when no run is active for the task. */
  interrupt(taskId: string, stop: StopRequest): boolean {
    const run = this.runs.get(taskId);
    if (!run || run.ended) return false;
    if (run.stop && STOP_PRIORITY[run.stop.kind] >= STOP_PRIORITY[stop.kind]) return true;
    run.stop = stop;
    run.stopped.abort();
    this.suspendStall(run);
    this.ctx.approvals.cancelForTask(taskId, "cancelled");
    if (run.handle) this.sendInterrupt(run);
    else run.abort.abort();
    return true;
  }

  private sendInterrupt(run: ActiveRun): void {
    if (!run.handle) return;
    run.handle.interrupt();
    this.ctx.clock.clearTimeout(run.killTimer);
    run.killTimer = this.ctx.clock.setTimeout(() => {
      run.killTimer = null;
      if (!run.ended) run.handle?.kill();
    }, this.ctx.econ.data.mana.kill_after_interrupt_s * 1000);
  }

  pauseAll(reason: PauseReason): void {
    for (const taskId of [...this.runs.keys()]) this.interrupt(taskId, { kind: "pause", reason });
  }

  nudge(taskId: string, message: string): boolean {
    const run = this.runs.get(taskId);
    if (!run || run.ended || !run.handle) return false;
    run.handle.send(message);
    this.activity(run, "system", `Nudge: ${message}`);
    this.touch(run);
    return true;
  }

  private clearTimers(run: ActiveRun): void {
    this.suspendStall(run);
    this.ctx.clock.clearTimeout(run.killTimer);
    this.ctx.clock.clearTimeout(run.progressTimer);
    run.killTimer = null;
    run.progressTimer = null;
  }

  private async onRunEnded(run: ActiveRun, outcome: RunOutcome): Promise<void> {
    if (run.ended) return;
    run.ended = true;
    run.stopped.abort();
    this.clearTimers(run);
    this.runs.delete(run.taskId);
    if (this.stopping) return;
    this.ctx.approvals.cancelForTask(run.taskId, "cancelled");
    this.ctx.db.tx(() => {
      const t = this.ctx.tasks.row(run.taskId);
      const segment = t.run_started_at ? Math.max(0, this.ctx.clock.now() - Date.parse(t.run_started_at)) : 0;
      this.ctx.db.run("UPDATE tasks SET run_ms = run_ms + ?, run_started_at = NULL WHERE id = ?", [segment, run.taskId]);
    });
    this.emitProgress(run);
    try {
      // A run that finished anyway goes to review; only a cancel overrides a completed run.
      if (run.stop && !(outcome.kind === "completed" && run.stop.kind !== "cancel")) {
        await this.applyStop(run.taskId, run.stop, run.workspace, outcome.kind === "completed" ? outcome.summary : null);
      } else if (outcome.kind === "completed") {
        await this.finalize(run.taskId, run.workspace, outcome.summary);
      } else if (outcome.kind === "failed") {
        this.handleFailure(run.taskId, outcome.error);
      } else {
        this.handleFailure(run.taskId, { code: "interrupted", message: "the agent stopped unexpectedly", transient: true });
      }
    } catch (err) {
      this.ctx.log.error({ taskId: run.taskId, err: String(err) }, "run end handling failed");
    }
    this.ctx.agents.maybeRetireAfterCurrent(run.agentId);
    this.ctx.scheduler.kick();
  }

  private async applyStop(taskId: string, stop: StopRequest, ws: TaskWorkspace | null, summary: string | null = null): Promise<void> {
    if (stop.kind === "cancel") {
      this.ctx.tasks.finishCancelled(taskId);
      return;
    }
    if (stop.kind === "stop_review") {
      const workspace = ws ?? this.ctx.tasks.workspaceOf(this.ctx.tasks.row(taskId));
      if (workspace) {
        await this.finalize(taskId, workspace, summary ?? "Stopped for review before the agent finished.");
        return;
      }
      this.pauseTask(taskId, "restart");
      return;
    }
    this.pauseTask(taskId, stop.reason);
  }

  private pauseTask(taskId: string, reason: PauseReason): void {
    this.ctx.db.tx(() => {
      const t = this.ctx.tasks.row(taskId);
      if (t.state === "paused") return;
      this.ctx.tasks.setState(taskId, "paused", reason);
      this.ctx.mana.release(taskId);
      if (reason === "budget") {
        this.ctx.incidents.open("hand_bell", incidentKey.handSeal(taskId), {
          severity: "warn",
          message: "The Mana Seal is spent: extend it or stop and review",
          agentId: t.agent_id,
          taskId,
        });
      }
      if (reason === "provider_limit") {
        const agent = this.ctx.agents.row(t.agent_id);
        this.ctx.incidents.open("font_dark", incidentKey.fontDarkProvider(agent.provider), {
          severity: "warn",
          message: `${agent.provider} reached its usage limit`,
          agentId: t.agent_id,
          taskId,
        });
      }
    });
  }

  private handleFailure(taskId: string, error: { code: string; message: string; transient: boolean }): void {
    if (error.code === "provider_limit") {
      this.pauseTask(taskId, "provider_limit");
      return;
    }
    const t = this.ctx.tasks.row(taskId);
    if (error.transient && t.rift_retries < RIFT_AUTO_RETRIES) {
      this.ctx.db.tx(() => {
        this.ctx.tasks.setState(taskId, "failed", "PROVIDER_UNAVAILABLE");
        this.ctx.db.run("UPDATE tasks SET rift_retries = rift_retries + 1 WHERE id = ?", [taskId]);
        this.ctx.mana.release(taskId);
        this.ctx.incidents.open("rift", incidentKey.rift(taskId), {
          severity: "warn",
          message: `The agent's link broke (${error.message}); retrying in ${this.ctx.econ.data.incidents.rift_auto_retry_after_s} s`,
          agentId: t.agent_id,
          taskId,
        });
      });
      this.ctx.tasks.scheduleRiftRetry(taskId);
      return;
    }
    this.failTask(taskId, error.transient ? "PROVIDER_UNAVAILABLE" : "INTERNAL", error.message);
  }

  private failTask(taskId: string, code: string, message: string): void {
    this.ctx.db.tx(() => {
      const t = this.ctx.tasks.row(taskId);
      if (t.state === "failed" || t.state === "cancelled") return;
      this.ctx.tasks.setState(taskId, "failed", code);
      this.ctx.db.run("UPDATE tasks SET finished_at = ? WHERE id = ?", [this.ctx.clock.iso(), taskId]);
      this.ctx.mana.release(taskId);
      this.ctx.incidents.resolve(incidentKey.rift(taskId));
      this.ctx.incidents.resolve(incidentKey.alarm(taskId));
      this.ctx.incidents.open("smoke", incidentKey.smoke(taskId), {
        severity: "warn",
        message: `The task failed: ${message}`,
        agentId: t.agent_id,
        taskId,
      });
      this.ctx.agents.bumpStats(t.agent_id, { failed: 1 });
      this.ctx.tasks.appendActivity(taskId, "error", message, true);
    });
    if (this.ctx.tasks.row(taskId).parent_task_id) this.ctx.parties.notifyChildFinished(taskId);
  }

  /** Snapshot commit, diff stats, optional Rite, then `awaiting_review`. */
  async finalize(taskId: string, ws: TaskWorkspace | null, summary: string): Promise<void> {
    const task = this.ctx.tasks.row(taskId);
    const workspace = ws ?? this.ctx.tasks.workspaceOf(task);
    try {
      if (!workspace) throw new Error("the task has no workspace");
      this.emitPhase(taskId, "finishing");
      const snap = await this.ctx.workspace.snapshot(workspace, `Aurelhaven snapshot: ${task.title} (attempt ${task.attempt})`);
      workspace.snapshot_sha = snap.snapshot_sha;
      let rite: TaskResult["rite"] = null;
      if (task.rite) {
        this.emitPhase(taskId, "rite");
        rite = await this.ctx.workspace.runRite(workspace.cwd, task.rite, this.ctx.config.riteTimeoutMs);
      }
      const canWrite = this.ctx.tools.activeTypes(task.agent_id).has("quillworks");
      const cleanSummary = this.ctx.redactor.redact(summary.trim());
      const result: TaskResult = {
        summary: cleanSummary,
        diff_stat: snap.diff_stat,
        rite,
        deliverable: snap.diff_stat.files > 0 || (!canWrite && cleanSummary.length > 0),
      };
      this.ctx.db.tx(() => {
        this.ctx.tasks.saveWorkspace(taskId, workspace);
        const cur = this.ctx.tasks.row(taskId);
        if (cur.state === "cancelled") return;
        this.ctx.tasks.setState(taskId, "awaiting_review");
        this.ctx.db.run("UPDATE tasks SET result_json = ?, finished_at = ? WHERE id = ?", [
          toJson(result),
          this.ctx.clock.iso(),
          taskId,
        ]);
        this.ctx.mana.release(taskId);
        this.ctx.incidents.resolveForTask(taskId, ["alarm_bell", "hand_bell"]);
      });
      if (task.parent_task_id) this.ctx.parties.notifyChildFinished(taskId);
    } catch (err) {
      this.ctx.log.error({ taskId, err: String(err) }, "finishing the run failed");
      this.failTask(taskId, isTownError(err) ? err.code : "INTERNAL", err instanceof Error ? err.message : String(err));
    }
  }

  private emitPhase(taskId: string, phase: ProgressPhase): void {
    const t = this.ctx.tasks.rowOrNull(taskId);
    if (!t) return;
    this.ctx.bus.emit(
      "task_progress",
      { task_id: taskId, phase, current_tool: null, files_touched: 0, spent_micros: t.spent_micros },
      `task/${taskId}`,
    );
  }

  /** Stops every run without touching task state; startup recovery handles them next time. */
  async shutdown(): Promise<void> {
    this.stopping = true;
    const pending: Array<Promise<unknown>> = [];
    for (const run of this.runs.values()) {
      this.clearTimers(run);
      run.stopped.abort();
      if (run.handle) {
        run.handle.kill();
        pending.push(run.handle.done.catch(() => undefined));
      } else {
        run.abort.abort();
      }
    }
    await Promise.race([Promise.allSettled(pending), new Promise((r) => setTimeout(r, 2000))]);
    this.runs.clear();
  }
}
