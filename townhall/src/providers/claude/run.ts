import { randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";
import path from "node:path";
import { approvalFor, claudeCategory, describeToolCall, writtenPaths } from "../common/approvals.js";
import { claudePlan } from "../common/capabilities.js";
import { harnessEnv } from "../common/env.js";
import type { Launch } from "../common/exec.js";
import { HarnessProcess, type ExitInfo } from "../common/process.js";
import { RunningTotal } from "../common/pricing.js";
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
import { claudeMcpServer, usableWaygates } from "../common/waygates.js";
import type { RunEvent, RunHandle, RunHost, RunOutcome, RunRequest } from "../types.js";
import { ApprovalBridge, type PermissionPrompt, type PermissionResult } from "./bridge.js";

/** The MCP server and tool Claude Code asks for permission (`--permission-prompt-tool`). */
export const APPROVAL_SERVER = "aurelhaven";
export const APPROVAL_TOOL = `mcp__${APPROVAL_SERVER}__approve`;

/** Adapter state saved through RunHost.checkpoint. */
export interface ClaudeCheckpoint {
  v: 1;
  harness: "claude";
  sessionId: string;
  /** The last `total_cost_usd` seen (Claude Code's running total for the session). */
  costSeenUsd: number;
  /** What Claude Code will restore when the session resumes: the total at its last exit on its own. */
  costSavedUsd: number;
}

function isCheckpoint(v: unknown): v is ClaudeCheckpoint {
  const c = v as ClaudeCheckpoint;
  return isPlainObject(v) && c.harness === "claude" && typeof c.sessionId === "string";
}

export interface ClaudeRunOptions {
  launch: Launch;
  deps: HarnessDeps;
  /** Path to approval-mcp.mjs. */
  approvalScript: string;
  /** Claude Code 2.1.277+ restores a session's cost total on resume. */
  restoresCostOnResume: boolean;
  /** True when the CLI is signed in with a subscription: costs are API-equivalent estimates. */
  estimate: boolean | undefined;
  /** Milliseconds to wait for a clean exit after closing stdin. */
  exitGraceMs?: number;
}

/** Long enough for any approval to wait (7 days); below the 2^31 ms timer limit. */
const MCP_TOOL_TIMEOUT_MS = "604800000";
const WRITE_TOOLS = new Set(["Edit", "MultiEdit", "Write", "NotebookEdit"]);

type Mode = "fresh" | "resume";
type ProcessEnd = RunOutcome | { kind: "resume_failed" };

interface ResultMessage {
  subtype: string;
  is_error: boolean;
  result?: string;
  total_cost_usd?: number;
  errors?: string[];
  user_message_uuids?: string[];
  terminal_reason?: string;
}

/**
 * One attempt of a task on Claude Code: `claude -p` in stream-json mode, with every permission
 * prompt sent to the Town Hall through the approval MCP server and the per-run bridge.
 */
export class ClaudeRun implements RunHandle {
  readonly done: Promise<RunOutcome>;
  private proc: HarnessProcess | null = null;
  private bridge: ApprovalBridge | null = null;
  private scratch: string | null = null;
  private stop: "interrupt" | "kill" | null = null;
  private stopping: Promise<unknown> | null = null;
  private readonly pending = new Set<string>();
  private readonly queued: string[] = [];
  private readonly tools = new Map<string, { name: string; input: unknown }>();
  private lifecycle = false;
  private finishing = false;
  private sawInit = false;
  private lastResult: ResultMessage | null = null;
  private lastError: string | null = null;
  private resultWaiters: Array<() => void> = [];
  private cost = new RunningTotal(0);
  private tokenCost = new RunningTotal(0);
  private state: ClaudeCheckpoint;
  private interruptSeq = 0;
  private readonly allowedMcpTools = new Map<string, Set<string>>();

  constructor(
    private readonly req: RunRequest,
    private readonly host: RunHost,
    private readonly opts: ClaudeRunOptions,
  ) {
    const prior = isCheckpoint(req.resume?.state) ? req.resume.state : null;
    const sessionId = req.resume?.sessionId ?? prior?.sessionId ?? randomUUID();
    this.state = {
      v: 1,
      harness: "claude",
      sessionId,
      costSeenUsd: prior?.costSeenUsd ?? 0,
      costSavedUsd: prior?.costSavedUsd ?? 0,
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
    this.sendUser(text);
  }

  interrupt(): void {
    if (this.stop) return;
    this.stop = "interrupt";
    if (this.proc) this.stopping = this.interruptProcess(this.proc);
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

  private checkpoint(): void {
    try {
      this.host.checkpoint({ ...this.state });
    } catch {
      // best effort
    }
  }

  private async run(): Promise<RunOutcome> {
    await Promise.resolve();
    try {
      if (this.stop) return { kind: "interrupted" };
      this.bridge = await ApprovalBridge.open((p) => this.onPermission(p));
      this.scratch = makeScratch(this.opts.deps.dataDir, "claude", this.req.taskId);
      let mode: Mode = this.req.resume?.sessionId || isCheckpoint(this.req.resume?.state) ? "resume" : "fresh";
      for (;;) {
        const end = await this.runProcess(mode);
        if (end.kind === "resume_failed") {
          this.emit({ kind: "activity", activity: "system", text: "The earlier Claude session could not be resumed; starting a new one." });
          mode = "fresh";
          this.state = { v: 1, harness: "claude", sessionId: randomUUID(), costSeenUsd: 0, costSavedUsd: 0 };
          continue;
        }
        return end;
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return { kind: "failed", error: { code: "crash", message: cleanText(message, this.opts.deps.redactor), transient: true } };
    } finally {
      this.bridge?.close();
      removeScratch(this.scratch);
    }
  }

  private buildArgs(mode: Mode): string[] {
    const req = this.req;
    const plan = claudePlan(this.opts.deps.tools, req.tools);
    const tools = [...plan.tools];
    if (req.approvalMode === "plan_first" && !tools.includes("ExitPlanMode")) tools.push("ExitPlanMode");

    const scratch = this.scratch!;
    const promptFile = path.join(scratch, "system-prompt.md");
    writeFileSync(promptFile, systemPromptFor(req, { names: this.opts.deps.names }), "utf8");

    const servers: Record<string, unknown> = {
      [APPROVAL_SERVER]: {
        type: "stdio",
        command: process.execPath,
        args: [this.opts.approvalScript],
        // Kept out of Claude Code's own environment so its shell tools never see the secret.
        env: { AURELHAVEN_APPROVAL_URL: this.bridge!.url, AURELHAVEN_APPROVAL_TOKEN: this.bridge!.token },
      },
    };
    if (plan.mcp) {
      const { usable, skipped } = usableWaygates(req.waygates);
      for (const w of usable) {
        servers[w.server_name] = claudeMcpServer(w);
        if (w.allowed_tools?.length) this.allowedMcpTools.set(w.server_name, new Set(w.allowed_tools));
      }
      for (const s of skipped) this.emit({ kind: "activity", activity: "system", text: `Waygate ${s.name} was skipped: ${s.reason}.` });
    }
    const mcpFile = path.join(scratch, "mcp.json");
    writeFileSync(mcpFile, JSON.stringify({ mcpServers: servers }, null, 2), "utf8");

    const remainingUsd = Math.max(0, req.budget.sealMicros - req.budget.spentMicros) / 1_000_000;
    const args = [
      "-p",
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--verbose",
      // No user, project or local settings: their allow rules and hooks would bypass the Town Hall.
      "--setting-sources",
      "",
      // Every tool call prompts (even reads and read-only commands), so every one reaches the Town Hall.
      "--settings",
      JSON.stringify({ permissions: { ask: ["*"] } }),
      "--strict-mcp-config",
      "--mcp-config",
      mcpFile,
      "--permission-prompt-tool",
      APPROVAL_TOOL,
      "--permission-mode",
      req.approvalMode === "plan_first" ? "plan" : "manual",
      "--tools",
      tools.join(","),
      "--append-system-prompt-file",
      promptFile,
    ];
    const model = req.model.trim();
    if (model && model !== "default") args.push("--model", model);
    if (mode === "resume") args.push("--resume", this.state.sessionId);
    else args.push("--session-id", this.state.sessionId);
    // A backstop only: the Town Hall pauses the task at its seal first.
    if (remainingUsd > 0) args.push("--max-budget-usd", (remainingUsd * 1.1 + 0.01).toFixed(4));
    return args;
  }

  private async runProcess(mode: Mode): Promise<ProcessEnd> {
    const plan = claudePlan(this.opts.deps.tools, this.req.tools);
    const args = this.buildArgs(mode);
    const env = harnessEnv(this.opts.deps.env, {
      MCP_TOOL_TIMEOUT: MCP_TOOL_TIMEOUT_MS,
      // Approvals wait for the player: no idle limit on MCP tool calls.
      CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT: "0",
      DISABLE_AUTOUPDATER: "1",
      ...(plan.charter ? {} : { CLAUDE_CODE_DISABLE_CLAUDE_MDS: "1" }),
    });

    if (this.stop) return { kind: "interrupted" };
    // Cost baseline: a resumed session restores the total saved at its last clean exit.
    const baseline = mode === "resume" && this.opts.restoresCostOnResume ? this.state.costSavedUsd : 0;
    this.cost = new RunningTotal(baseline);
    this.tokenCost = new RunningTotal(0);
    this.sawInit = false;
    this.lastResult = null;
    this.lastError = null;
    this.finishing = false;
    this.pending.clear();

    const proc = new HarnessProcess(this.opts.launch, args, {
      cwd: this.req.cwd,
      env,
      onRecord: (r) => this.onRecord(r),
    });
    this.proc = proc;
    this.sendUser(firstMessageFor(this.req, mode === "resume"));
    for (const text of this.queued.splice(0)) this.sendUser(text);
    if (this.stop === "interrupt") this.stopping = this.interruptProcess(proc);
    else if (this.stop === "kill") this.stopping = proc.kill();

    const exit = await proc.exited;
    await this.stopping;
    // Claude Code saves the session's cost total when it exits on its own (whatever the exit
    // code, and also when the Town Hall itself dies and closes its stdin), not when its process
    // tree is ended from outside: then the next resume restores this process's starting total.
    const exitedOnItsOwn = !exit.spawnError && !proc.forced && this.stop !== "kill";
    this.state.costSavedUsd = exitedOnItsOwn ? this.state.costSeenUsd : baseline;
    this.checkpoint();
    return this.outcome(mode, exit, proc);
  }

  private outcome(mode: Mode, exit: ExitInfo, proc: HarnessProcess): ProcessEnd {
    const redactor = this.opts.deps.redactor;
    if (exit.spawnError) {
      return { kind: "failed", error: { code: "not_installed", message: `Claude Code could not start: ${exit.spawnError}`, transient: false } };
    }
    const errors = this.lastResult?.errors?.join("; ") ?? "";
    if (mode === "resume" && !this.sawInit && /no conversation found/i.test(`${errors}\n${proc.stderrTail()}`)) {
      return { kind: "resume_failed" };
    }
    if (this.stop) return { kind: "interrupted" };
    const r = this.lastResult;
    if (r && r.subtype === "success" && !r.is_error) {
      return { kind: "completed", summary: (r.result ?? "").trim() || "The agent finished." };
    }
    if (r?.subtype === "error_max_budget_usd") {
      return { kind: "failed", error: { code: "budget_limit", message: "Claude Code stopped at its spending cap for this attempt.", transient: false } };
    }
    const detail = [this.lastError, errors, r?.result, proc.stderrTail()].filter((s) => s && s.trim()).join(" | ");
    const cls = classifyFailure(detail);
    const message = detail ? cleanText(detail, redactor, 600) : `Claude Code exited with code ${exit.code ?? exit.signal ?? "unknown"}`;
    return { kind: "failed", error: { code: cls.code, message, transient: cls.transient } };
  }

  private sendUser(text: string): void {
    const proc = this.proc;
    if (!proc) return;
    const uuid = randomUUID();
    const ok = proc.send({
      type: "user",
      uuid,
      session_id: "",
      parent_tool_use_id: null,
      message: { role: "user", content: [{ type: "text", text }] },
    });
    if (ok) this.pending.add(uuid);
  }

  /** Asks Claude Code to stop the turn (documented `interrupt` control request), then ends the process. */
  private async interruptProcess(proc: HarnessProcess): Promise<void> {
    if (!proc.running) return;
    proc.send({
      type: "control_request",
      request_id: `interrupt-${++this.interruptSeq}`,
      request: { subtype: "interrupt", cancel_queued: true },
    });
    await Promise.race([
      new Promise<void>((resolve) => this.resultWaiters.push(resolve)),
      proc.exited,
      new Promise((resolve) => setTimeout(resolve, 5_000)),
    ]);
    // End of input lets Claude Code save the session and exit; then taskkill /T, then /F.
    await proc.stop(this.opts.exitGraceMs ?? 8_000);
  }

  private maybeFinish(): void {
    const proc = this.proc;
    if (!proc || this.finishing || this.stop || !this.lastResult) return;
    if (this.pending.size > 0) return;
    this.finishing = true;
    // All sent messages are answered: close stdin so Claude Code saves the session and exits.
    void proc.stop(this.opts.exitGraceMs ?? 15_000);
  }

  // ---------- stream-json records ----------

  private onRecord(record: unknown): void {
    if (!isPlainObject(record)) return;
    try {
      switch (record.type) {
        case "system":
          this.onSystem(record);
          break;
        case "assistant":
          this.onAssistant(record);
          break;
        case "user":
          this.onUser(record);
          break;
        case "result":
          this.onResult(record);
          break;
        case "command_lifecycle":
          this.onLifecycle(record);
          break;
        case "control_request":
          this.onControlRequest(record);
          break;
        default:
          break;
      }
    } catch (err) {
      this.opts.deps.log?.warn({ taskId: this.req.taskId, err: String(err) }, "claude record handling failed");
    }
  }

  private onSystem(r: Record<string, unknown>): void {
    const subtype = asString(r.subtype);
    if (subtype === "init") {
      this.sawInit = true;
      const sessionId = asString(r.session_id);
      if (sessionId) {
        this.state.sessionId = sessionId;
        this.emit({ kind: "session", sessionId });
        this.checkpoint();
      }
      const caps = Array.isArray(r.capabilities) ? r.capabilities : [];
      this.lifecycle = caps.includes("msg_lifecycle_v1");
      const servers = Array.isArray(r.mcp_servers) ? (r.mcp_servers as Array<Record<string, unknown>>) : [];
      const approval = servers.find((s) => s.name === APPROVAL_SERVER);
      if (!approval || approval.status !== "connected") {
        this.emit({
          kind: "activity",
          activity: "error",
          text: "The Town Hall approval channel did not connect; Claude Code will not be able to ask before acting.",
        });
      }
      for (const s of servers) {
        if (s.name !== APPROVAL_SERVER && s.status !== "connected") {
          this.emit({ kind: "activity", activity: "system", text: `Waygate ${String(s.name)} is ${String(s.status)}.` });
        }
      }
    } else if (subtype === "api_retry") {
      const attempt = asNumber(r.attempt) ?? 0;
      const max = asNumber(r.max_retries) ?? 0;
      this.emit({ kind: "activity", activity: "system", text: `Claude is retrying a failed request (${attempt}/${max}): ${String(r.error ?? "error")}` });
    } else if (subtype === "compact_boundary") {
      this.emit({ kind: "activity", activity: "system", text: "Claude compacted its conversation." });
    }
  }

  private onAssistant(r: Record<string, unknown>): void {
    const error = asString(r.error);
    if (error) this.lastError = error;
    const message = isPlainObject(r.message) ? r.message : null;
    const content = Array.isArray(message?.content) ? message.content : [];
    for (const block of content) {
      if (!isPlainObject(block)) continue;
      if (block.type === "text") {
        const text = asString(block.text)?.trim();
        if (text) this.emit({ kind: "activity", activity: "message", text: cleanText(text, this.opts.deps.redactor) });
      } else if (block.type === "tool_use") {
        const id = asString(block.id) ?? "";
        const name = asString(block.name) ?? "tool";
        this.tools.set(id, { name, input: block.input });
        this.emit({ kind: "tool_start", tool: name, input: block.input, text: describeToolCall(name, block.input, this.req.cwd) });
      }
    }
  }

  private onUser(r: Record<string, unknown>): void {
    const message = isPlainObject(r.message) ? r.message : null;
    const content = Array.isArray(message?.content) ? message.content : [];
    for (const block of content) {
      if (!isPlainObject(block) || block.type !== "tool_result") continue;
      const id = asString(block.tool_use_id) ?? "";
      const call = this.tools.get(id);
      if (!call) continue;
      this.tools.delete(id);
      const ok = block.is_error !== true;
      const summary = describeToolCall(call.name, call.input, this.req.cwd);
      this.emit({ kind: "tool_end", tool: call.name, ok, text: ok ? summary : `${summary} (failed or denied)` });
      if (ok && WRITE_TOOLS.has(call.name)) {
        const paths = writtenPaths(call.input, this.req.cwd);
        if (paths.length > 0) this.emit({ kind: "files_touched", paths });
      }
    }
  }

  private onResult(r: Record<string, unknown>): void {
    const result: ResultMessage = {
      subtype: asString(r.subtype) ?? "unknown",
      is_error: r.is_error === true,
      ...(typeof r.result === "string" ? { result: r.result } : {}),
      ...(typeof r.total_cost_usd === "number" ? { total_cost_usd: r.total_cost_usd } : {}),
      ...(Array.isArray(r.errors) ? { errors: r.errors.map(String) } : {}),
      ...(Array.isArray(r.user_message_uuids) ? { user_message_uuids: r.user_message_uuids.map(String) } : {}),
      ...(typeof r.terminal_reason === "string" ? { terminal_reason: r.terminal_reason } : {}),
    };
    this.lastResult = result;
    let micros = 0;
    if (result.total_cost_usd !== undefined) {
      micros = this.cost.update(result.total_cost_usd);
      // Checkpointed as saved too: if the Town Hall dies now, Claude Code sees stdin close, exits
      // on its own and saves this total, which the next resume restores.
      this.state.costSeenUsd = this.cost.value;
      this.state.costSavedUsd = this.cost.value;
      this.checkpoint();
    } else if (isPlainObject(r.usage)) {
      // No cost in the result: price this process's token totals with pricing.json instead.
      const u = r.usage;
      const models = isPlainObject(r.modelUsage) ? Object.keys(r.modelUsage) : [];
      const usd = this.opts.deps.pricing.costUsd("claude", models[0] ?? this.req.model, {
        input: asNumber(u.input_tokens) ?? 0,
        cacheWrite: asNumber(u.cache_creation_input_tokens) ?? 0,
        cacheRead: asNumber(u.cache_read_input_tokens) ?? 0,
        output: asNumber(u.output_tokens) ?? 0,
      });
      if (usd !== null) micros = this.tokenCost.update(usd);
    }
    if (micros > 0) {
      this.emit({ kind: "usage", costMicros: micros, ...(this.opts.estimate !== undefined ? { estimate: this.opts.estimate } : {}) });
    }
    if (!this.lifecycle) {
      if (result.user_message_uuids) for (const id of result.user_message_uuids) this.pending.delete(id);
      else this.pending.clear();
    }
    const waiters = this.resultWaiters.splice(0);
    for (const w of waiters) w();
    this.maybeFinish();
  }

  private onLifecycle(r: Record<string, unknown>): void {
    const id = asString(r.command_uuid);
    const state = asString(r.state);
    if (!id || !state) return;
    if (state === "completed" || state === "cancelled" || state === "failed" || state === "discarded") {
      this.pending.delete(id);
      this.maybeFinish();
    }
  }

  /** The SDK-host permission route, in case Claude Code ever asks over stdin instead of the MCP tool. */
  private onControlRequest(r: Record<string, unknown>): void {
    const requestId = asString(r.request_id);
    const request = isPlainObject(r.request) ? r.request : null;
    if (!requestId || !request) return;
    if (request.subtype !== "can_use_tool") {
      this.proc?.send({
        type: "control_response",
        response: { subtype: "error", request_id: requestId, error: `unsupported control request ${String(request.subtype)}` },
      });
      return;
    }
    const prompt: PermissionPrompt = {
      tool_name: asString(request.tool_name) ?? "tool",
      input: isPlainObject(request.input) ? request.input : {},
    };
    void this.onPermission(prompt).then((result) => {
      this.proc?.send({ type: "control_response", response: { subtype: "success", request_id: requestId, response: result } });
    });
  }

  // ---------- approvals ----------

  private async onPermission(prompt: PermissionPrompt): Promise<PermissionResult> {
    if (this.stop) return { behavior: "deny", message: "The task is stopping.", interrupt: true };
    const tool = prompt.tool_name;
    if (tool.startsWith("mcp__")) {
      const [, server, name] = tool.split("__");
      const allowed = server ? this.allowedMcpTools.get(server) : undefined;
      if (allowed && name && !allowed.has(name)) {
        // Capability, not approval: this Waygate does not offer the tool to the agent.
        return { behavior: "deny", message: `The ${server} Waygate does not allow the tool ${name}.` };
      }
    }
    const answer = await this.host.requestApproval(approvalFor(tool, claudeCategory(tool), prompt.input, this.req.cwd));
    if (answer.cancelled) {
      return { behavior: "deny", message: "The Town Hall withdrew this request because the task is stopping.", interrupt: true };
    }
    if (answer.decision === "allow") {
      return { behavior: "allow", updatedInput: isPlainObject(answer.updatedInput) ? answer.updatedInput : prompt.input };
    }
    return { behavior: "deny", message: answer.message ? `The player denied this: ${answer.message}` : "The player denied this action." };
  }
}
