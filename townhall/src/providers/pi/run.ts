import { existsSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { approvalFor, describeToolCall, piCategory, writtenPaths } from "../common/approvals.js";
import { piPlan, type PiPlan } from "../common/capabilities.js";
import { harnessEnv } from "../common/env.js";
import type { Launch } from "../common/exec.js";
import { HarnessProcess, type ExitInfo } from "../common/process.js";
import { usdToMicros } from "../common/pricing.js";
import { firstMessageFor, nudgeMessage, systemPromptFor } from "../common/prompt.js";
import {
  asNumber,
  asString,
  classifyFailure,
  cleanText,
  isPlainObject,
  makeScratch,
  removeScratch,
  type HarnessDeps,
} from "../common/support.js";
import { piMcpServer, usableWaygates } from "../common/waygates.js";
import type { RunEvent, RunHandle, RunHost, RunOutcome, RunRequest } from "../types.js";

/** The dialog title the gate extension uses for approval requests. */
export const APPROVAL_TITLE = "aurelhaven:approval";

/** Adapter state saved through RunHost.checkpoint: where the task's pi session lives. */
export interface PiCheckpoint {
  v: 1;
  harness: "pi";
  sessionDir: string;
  sessionId: string;
  sessionFile: string | null;
}

function isCheckpoint(v: unknown): v is PiCheckpoint {
  return isPlainObject(v) && v.harness === "pi" && typeof v.sessionDir === "string" && typeof v.sessionId === "string";
}

export interface PiRunOptions {
  launch: Launch;
  deps: HarnessDeps;
  /** Path to aurelhaven-gate.ts. */
  extensionPath: string;
  /** Extra CLI arguments (tests load a scripted provider this way). */
  extraArgs?: string[];
  estimate: boolean | undefined;
  exitGraceMs?: number;
}

const WRITE_TOOLS = new Set(["edit", "write"]);
const DIALOGS = new Set(["select", "confirm", "input", "editor"]);

/** pi session ids: letters, digits, ".", "_" and "-", starting and ending with a letter or digit. */
export function piSessionId(taskId: string): string {
  return `aurelhaven-${taskId.replace(/[^A-Za-z0-9._-]/g, "_")}`.replace(/[^A-Za-z0-9]+$/, "") || "aurelhaven";
}

/** Splits "<pi provider>/<model id>"; a bare id is left to pi's own matching. */
export function splitPiModel(model: string): { provider: string | null; id: string } {
  const trimmed = model.trim();
  const slash = trimmed.indexOf("/");
  if (slash <= 0) return { provider: null, id: trimmed };
  return { provider: trimmed.slice(0, slash), id: trimmed.slice(slash + 1) };
}

function textOf(message: Record<string, unknown>): string {
  const content = message.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter(isPlainObject)
    .filter((b) => b.type === "text")
    .map((b) => String(b.text ?? ""))
    .join("");
}

/**
 * One attempt of a task on pi in RPC mode (JSON Lines commands and events). The gate extension
 * turns every tool call into an approval request; the session lives under the Town Hall's
 * data folder so a later attempt resumes it.
 */
export class PiRun implements RunHandle {
  readonly done: Promise<RunOutcome>;
  private proc: HarnessProcess | null = null;
  private scratch: string | null = null;
  private stop: "interrupt" | "kill" | null = null;
  private stopping: Promise<unknown> | null = null;
  private streaming = false;
  private piQueue = 0;
  private readonly queued: string[] = [];
  private readonly tools = new Map<string, { name: string; args: unknown }>();
  private messageCost = 0;
  private messageInput = 0;
  private messageOutput = 0;
  private lastText = "";
  private lastStop: string | null = null;
  private readonly errors: string[] = [];
  private commandError: string | null = null;
  private completed = false;
  private finishing = false;
  private settleWaiters: Array<() => void> = [];
  private readonly plan: PiPlan;
  private state: PiCheckpoint;
  private seq = 0;

  constructor(
    private readonly req: RunRequest,
    private readonly host: RunHost,
    private readonly opts: PiRunOptions,
  ) {
    this.plan = piPlan(opts.deps.tools, req.tools);
    const prior = isCheckpoint(req.resume?.state) ? req.resume.state : null;
    this.state = prior ?? {
      v: 1,
      harness: "pi",
      sessionDir: path.join(opts.deps.dataDir, "pi-sessions", req.taskId.replace(/[^A-Za-z0-9_-]/g, "_")),
      sessionId: piSessionId(req.taskId),
      sessionFile: null,
    };
    this.done = this.run();
  }

  // ---------- RunHandle ----------

  send(message: string): void {
    if (this.finishing || this.stop) return;
    const text = nudgeMessage(message);
    if (!this.proc) {
      this.queued.push(text);
      return;
    }
    // While pi streams, a steer reaches the agent after its current tool calls. When it is idle,
    // steer and follow_up only queue (verified with pi 0.87), so a prompt starts a new run.
    if (this.streaming) this.command({ type: "steer", message: text });
    else this.command({ type: "prompt", message: text, streamingBehavior: "steer" });
  }

  interrupt(): void {
    if (this.stop) return;
    this.stop = "interrupt";
    if (this.proc) this.stopping = this.abortProcess(this.proc);
  }

  kill(): void {
    if (this.stop === "kill") return;
    this.stop = "kill";
    if (this.proc) this.stopping = this.proc.kill();
  }

  // ---------- lifecycle ----------

  private emit(event: RunEvent): void {
    try {
      this.host.emit(event);
    } catch {
      // the supervisor logs its own errors
    }
  }

  private command(record: Record<string, unknown>): string {
    const id = `th-${++this.seq}`;
    this.proc?.send({ id, ...record });
    return id;
  }

  private sessionExists(): boolean {
    if (this.state.sessionFile && existsSync(this.state.sessionFile)) return true;
    try {
      return readdirSync(this.state.sessionDir).some((f) => f.endsWith(`_${this.state.sessionId}.jsonl`) || f === `${this.state.sessionId}.jsonl`);
    } catch {
      return false;
    }
  }

  private args(promptFile: string): string[] {
    const args = ["--mode", "rpc", "--no-approve", "--session-dir", this.state.sessionDir, "--session-id", this.state.sessionId];
    const model = splitPiModel(this.req.model);
    if (model.provider) args.push("--provider", model.provider);
    if (model.id) args.push("--model", model.id);
    if (this.plan.tools.length > 0) args.push("--tools", this.plan.tools.join(","));
    else args.push("--no-tools");
    args.push("--append-system-prompt", promptFile);
    if (!this.plan.charter) args.push("--no-context-files", "--no-skills");
    args.push("-e", this.opts.extensionPath, ...(this.opts.extraArgs ?? []));
    return args;
  }

  private async run(): Promise<RunOutcome> {
    await Promise.resolve();
    if (this.stop) return { kind: "interrupted" };
    try {
      mkdirSync(this.state.sessionDir, { recursive: true });
      const resumed = this.sessionExists();
      this.scratch = makeScratch(this.opts.deps.dataDir, "pi", this.req.taskId);
      const promptFile = path.join(this.scratch, "system-prompt.md");
      const notes =
        process.platform === "win32" && this.plan.tools.includes("bash")
          ? ["The bash tool runs Git Bash on Windows: use POSIX shell syntax."]
          : [];
      writeFileSync(promptFile, systemPromptFor(this.req, { names: this.opts.deps.names, notes }), "utf8");
      for (const u of this.plan.unavailable) this.emit({ kind: "activity", activity: "system", text: `The ${u.type} add-on does nothing for pi: ${u.note}.` });

      const waygates = this.plan.mcp ? usableWaygates(this.req.waygates) : { usable: [], skipped: [] };
      for (const s of waygates.skipped) this.emit({ kind: "activity", activity: "system", text: `Waygate ${s.name} was skipped: ${s.reason}.` });
      const env = harnessEnv(this.opts.deps.env, {
        AURELHAVEN_PI_GATE: JSON.stringify({ waygates: waygates.usable.map(piMcpServer) }),
        PI_SKIP_VERSION_CHECK: "1",
      });

      const proc = new HarnessProcess(this.opts.launch, this.args(promptFile), {
        cwd: this.req.cwd,
        env,
        onRecord: (r) => this.onRecord(r),
      });
      this.proc = proc;
      if (this.stop === "kill") this.stopping = proc.kill();
      proc.send({ id: "th-state", type: "get_state" });
      proc.send({ id: "th-prompt", type: "prompt", message: firstMessageFor(this.req, resumed) });
      for (const text of this.queued.splice(0)) proc.send({ id: `th-${++this.seq}`, type: "prompt", message: text, streamingBehavior: "steer" });
      if (this.stop === "interrupt") this.stopping = this.abortProcess(proc);

      const exit = await proc.exited;
      await this.stopping;
      return this.outcome(exit, proc);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return { kind: "failed", error: { code: "crash", message: cleanText(message, this.opts.deps.redactor), transient: true } };
    } finally {
      removeScratch(this.scratch);
    }
  }

  private async abortProcess(proc: HarnessProcess): Promise<void> {
    if (proc.running) {
      const settled = new Promise<void>((resolve) => this.settleWaiters.push(resolve));
      proc.send({ id: "th-abort", type: "abort" });
      await Promise.race([settled, proc.exited, new Promise((r) => setTimeout(r, 10_000))]);
    }
    await proc.stop(this.opts.exitGraceMs ?? 8_000);
  }

  private finish(): void {
    if (this.finishing) return;
    this.finishing = true;
    // Closing stdin asks pi to shut down after disposing the session.
    void this.proc?.stop(this.opts.exitGraceMs ?? 10_000);
  }

  private outcome(exit: ExitInfo, proc: HarnessProcess): RunOutcome {
    if (exit.spawnError) {
      return { kind: "failed", error: { code: "not_installed", message: `pi could not start: ${exit.spawnError}`, transient: false } };
    }
    if (this.stop) return { kind: "interrupted" };
    if (this.completed) return { kind: "completed", summary: this.lastText.trim() || "The agent finished." };
    // Retries replace the first error with later ones, so classify on all of them.
    const errors = [this.commandError, ...this.errors].filter((s): s is string => !!s && s.trim() !== "");
    const detail = errors.length > 0 ? errors.join(" | ") : proc.stderrTail();
    const cls = classifyFailure(detail);
    const message = detail ? cleanText(detail, this.opts.deps.redactor, 600) : `pi exited with code ${exit.code ?? "unknown"}`;
    return { kind: "failed", error: { code: cls.code, message, transient: cls.transient } };
  }

  // ---------- records ----------

  private onRecord(record: unknown): void {
    if (!isPlainObject(record)) return;
    try {
      switch (record.type) {
        case "response":
          this.onResponse(record);
          break;
        case "agent_start":
          this.streaming = true;
          break;
        case "agent_settled":
          this.onSettled();
          break;
        case "message_start":
          if (isPlainObject(record.message) && record.message.role === "assistant") {
            this.messageCost = 0;
            this.messageInput = 0;
            this.messageOutput = 0;
          }
          break;
        case "message_update":
          this.chargeUsage(record.usage);
          break;
        case "message_end":
          this.onMessageEnd(isPlainObject(record.message) ? record.message : {});
          break;
        case "tool_execution_start":
          this.onToolStart(record);
          break;
        case "tool_execution_end":
          this.onToolEnd(record);
          break;
        case "queue_update": {
          const steering = Array.isArray(record.steering) ? record.steering.length : 0;
          const followUp = Array.isArray(record.followUp) ? record.followUp.length : 0;
          this.piQueue = steering + followUp;
          break;
        }
        case "auto_retry_start":
          this.noteError(asString(record.errorMessage));
          this.emit({ kind: "activity", activity: "system", text: `pi is retrying a failed request: ${String(record.errorMessage ?? "error")}` });
          break;
        case "auto_retry_end":
          if (record.success === false) this.noteError(asString(record.finalError));
          break;
        case "compaction_end":
          this.emit({ kind: "activity", activity: "system", text: "pi compacted its conversation." });
          break;
        case "extension_ui_request":
          this.onUiRequest(record);
          break;
        case "extension_error":
          this.emit({ kind: "activity", activity: "error", text: cleanText(`pi extension error: ${String(record.error ?? "")}`, this.opts.deps.redactor) });
          break;
        default:
          break;
      }
    } catch (err) {
      this.opts.deps.log?.warn({ taskId: this.req.taskId, err: String(err) }, "pi record handling failed");
    }
  }

  private onResponse(r: Record<string, unknown>): void {
    const id = asString(r.id);
    if (id === "th-state" && r.success === true && isPlainObject(r.data)) {
      const sessionFile = asString(r.data.sessionFile);
      const sessionId = asString(r.data.sessionId) ?? this.state.sessionId;
      this.state = { ...this.state, sessionFile };
      this.emit({ kind: "session", sessionId });
      this.host.checkpoint({ ...this.state });
      return;
    }
    if (r.success === false && r.command !== "abort") {
      const error = asString(r.error) ?? `${String(r.command)} failed`;
      if (id === "th-prompt") {
        this.commandError = error;
        this.finish();
      } else {
        this.emit({ kind: "activity", activity: "system", text: cleanText(`pi refused ${String(r.command)}: ${error}`, this.opts.deps.redactor) });
      }
    }
  }

  private onSettled(): void {
    this.streaming = false;
    for (const w of this.settleWaiters.splice(0)) w();
    if (this.stop || this.finishing) return;
    if (this.lastStop === "error" || this.lastStop === "aborted") {
      this.finish();
      return;
    }
    if (this.piQueue > 0) {
      // Messages that arrived too late for the run are only queued: start a run to deliver them.
      this.command({ type: "prompt", message: "Continue with the messages above.", streamingBehavior: "steer" });
      return;
    }
    this.completed = true;
    this.finish();
  }

  private chargeUsage(raw: unknown): void {
    if (!isPlainObject(raw)) return;
    const cost = isPlainObject(raw.cost) ? (asNumber(raw.cost.total) ?? 0) : 0;
    const input = (asNumber(raw.input) ?? 0) + (asNumber(raw.cacheRead) ?? 0) + (asNumber(raw.cacheWrite) ?? 0);
    const output = asNumber(raw.output) ?? 0;
    // Usage is cumulative within one assistant message: charge only its growth.
    const micros = usdToMicros(Math.max(0, cost - this.messageCost));
    const inDelta = Math.max(0, input - this.messageInput);
    const outDelta = Math.max(0, output - this.messageOutput);
    this.messageCost = Math.max(this.messageCost, cost);
    this.messageInput = Math.max(this.messageInput, input);
    this.messageOutput = Math.max(this.messageOutput, output);
    if (micros > 0) {
      this.emit({
        kind: "usage",
        costMicros: micros,
        inputTokens: inDelta,
        outputTokens: outDelta,
        ...(this.opts.estimate !== undefined ? { estimate: this.opts.estimate } : {}),
      });
    }
  }

  private noteError(text: string | null): void {
    if (text && !this.errors.includes(text)) this.errors.push(text);
  }

  private onMessageEnd(message: Record<string, unknown>): void {
    if (message.role !== "assistant") return;
    this.chargeUsage(message.usage);
    this.lastStop = asString(message.stopReason);
    const error = asString(message.errorMessage);
    if (this.lastStop === "error") this.noteError(error);
    const text = textOf(message).trim();
    if (text) {
      this.lastText = text;
      this.emit({ kind: "activity", activity: "message", text: cleanText(text, this.opts.deps.redactor) });
    }
  }

  private onToolStart(r: Record<string, unknown>): void {
    const id = asString(r.toolCallId) ?? "";
    const name = asString(r.toolName) ?? "tool";
    this.tools.set(id, { name, args: r.args });
    this.emit({ kind: "tool_start", tool: name, input: r.args, text: describeToolCall(name, r.args, this.req.cwd) });
  }

  private onToolEnd(r: Record<string, unknown>): void {
    const id = asString(r.toolCallId) ?? "";
    const call = this.tools.get(id) ?? { name: asString(r.toolName) ?? "tool", args: undefined };
    this.tools.delete(id);
    const ok = r.isError !== true;
    const summary = describeToolCall(call.name, call.args, this.req.cwd);
    this.emit({ kind: "tool_end", tool: call.name, ok, text: ok ? summary : `${summary} (failed or denied)` });
    if (ok && WRITE_TOOLS.has(call.name)) {
      const paths = writtenPaths(call.args, this.req.cwd);
      if (paths.length > 0) this.emit({ kind: "files_touched", paths });
    }
  }

  private onUiRequest(r: Record<string, unknown>): void {
    const id = asString(r.id);
    const method = asString(r.method);
    if (!id || !method) return;
    if (method === "input" && r.title === APPROVAL_TITLE) {
      void this.onApproval(id, asString(r.placeholder) ?? "{}");
      return;
    }
    if (DIALOGS.has(method)) {
      // Another extension wants an answer the Town Hall cannot give; dismiss it.
      this.proc?.send({ type: "extension_ui_response", id, cancelled: true });
      this.emit({ kind: "activity", activity: "system", text: `Dismissed a pi dialog the Town Hall cannot answer: ${String(r.title ?? method)}` });
      return;
    }
    if (method === "notify") {
      const text = asString(r.message);
      if (text) this.emit({ kind: "activity", activity: r.notifyType === "error" ? "error" : "system", text: cleanText(`pi: ${text}`, this.opts.deps.redactor) });
    }
  }

  private async onApproval(dialogId: string, placeholder: string): Promise<void> {
    let payload: Record<string, unknown>;
    try {
      const parsed = JSON.parse(placeholder) as unknown;
      payload = isPlainObject(parsed) ? parsed : {};
    } catch {
      payload = {};
    }
    const tool = asString(payload.tool) ?? "tool";
    const input = payload.input ?? {};
    const answer = this.stop
      ? { decision: "deny" as const, cancelled: true }
      : await this.host.requestApproval(approvalFor(tool, piCategory(tool), input, this.req.cwd));
    const proc = this.proc;
    if (!proc?.acceptsInput) return;
    if (answer.cancelled) {
      proc.send({ type: "extension_ui_response", id: dialogId, cancelled: true });
      return;
    }
    const decision =
      answer.decision === "allow"
        ? { decision: "allow", ...(isPlainObject(answer.updatedInput) ? { updatedInput: answer.updatedInput } : {}) }
        : { decision: "deny", message: answer.message ? `The player denied this: ${answer.message}` : "The player denied this action." };
    proc.send({ type: "extension_ui_response", id: dialogId, value: JSON.stringify(decision) });
  }
}
