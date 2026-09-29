import path from "node:path";
import { DAEMON_VERSION } from "../../protocol/version.js";
import { approvalFor, displayTarget } from "../common/approvals.js";
import { codexPlan, type CodexPlan } from "../common/capabilities.js";
import { harnessEnv } from "../common/env.js";
import type { Launch } from "../common/exec.js";
import { HarnessProcess, type ExitInfo } from "../common/process.js";
import { usdToMicros } from "../common/pricing.js";
import { firstMessageFor, nudgeMessage, systemPromptFor } from "../common/prompt.js";
import { asNumber, asString, classifyFailure, cleanText, isPlainObject, type HarnessDeps } from "../common/support.js";
import { codexMcpOverrides, usableWaygates } from "../common/waygates.js";
import type { ApprovalAnswer, ApprovalRequest, RunEvent, RunHandle, RunHost, RunOutcome, RunRequest } from "../types.js";
import { RpcClient, RpcError, type RpcId } from "./rpc.js";

/** Adapter state saved through RunHost.checkpoint. */
export interface CodexCheckpoint {
  v: 1;
  harness: "codex";
  threadId: string;
}

function isCheckpoint(v: unknown): v is CodexCheckpoint {
  return isPlainObject(v) && v.harness === "codex" && typeof v.threadId === "string";
}

/** Codex features a town agent does not get: they bring their own tools or agents. */
const DISABLED_FEATURES = ["apps", "plugins", "multi_agent", "computer_use", "browser_use", "browser_use_external", "in_app_browser", "image_generation"];
const MCP_APPROVAL_QUESTION = "mcp_tool_call_approval";

export interface CodexRunOptions {
  launch: Launch;
  deps: HarnessDeps;
  /** True when Codex is signed in with a ChatGPT plan: priced usage is an API-equivalent estimate. */
  estimate: boolean | undefined;
  exitGraceMs?: number;
}

interface Tokens {
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
}

function tokensOf(v: unknown): Tokens | null {
  if (!isPlainObject(v)) return null;
  return {
    inputTokens: asNumber(v.inputTokens) ?? 0,
    cachedInputTokens: asNumber(v.cachedInputTokens) ?? 0,
    outputTokens: asNumber(v.outputTokens) ?? 0,
  };
}

function textInput(text: string): unknown[] {
  return [{ type: "text", text, text_elements: [] }];
}

/** A TurnError as text: its message plus the codexErrorInfo kind, for example "(usageLimitExceeded)". */
function describeError(error: Record<string, unknown>): string {
  const info = error.codexErrorInfo;
  const kind = typeof info === "string" ? info : isPlainObject(info) ? Object.keys(info)[0] : null;
  const message = asString(error.message) ?? "the turn failed";
  return kind ? `${message} (${kind})` : message;
}

type Decision = "accept" | "decline" | "cancel";

function decisionOf(answer: ApprovalAnswer): Decision {
  if (answer.cancelled) return "cancel";
  return answer.decision === "allow" ? "accept" : "decline";
}

/**
 * One attempt of a task on the Codex CLI through `codex app-server`, the JSON-RPC interface
 * Codex's own IDE integrations use. Codex asks for approval with server-to-client requests,
 * which go to the Town Hall.
 */
export class CodexRun implements RunHandle {
  readonly done: Promise<RunOutcome>;
  private proc: HarnessProcess | null = null;
  private rpc: RpcClient | null = null;
  private stop: "interrupt" | "kill" | null = null;
  private stopping: Promise<unknown> | null = null;
  private threadId: string | null = null;
  private model: string;
  private activeTurn: string | null = null;
  private readonly ourTurns = new Set<string>();
  private readonly queued: string[] = [];
  private readonly items = new Map<string, Record<string, unknown>>();
  private prevTotal: Tokens | null = null;
  private lastAgentText = "";
  private turnError: string | null = null;
  private lastError: string | null = null;
  private completed = false;
  private finishing = false;
  private turnWaiters: Array<() => void> = [];
  private readonly plan: CodexPlan;

  constructor(
    private readonly req: RunRequest,
    private readonly host: RunHost,
    private readonly opts: CodexRunOptions,
  ) {
    this.plan = codexPlan(opts.deps.tools, req.tools);
    this.model = req.model;
    this.done = this.run();
  }

  // ---------- RunHandle ----------

  send(message: string): void {
    if (this.finishing || this.stop) return;
    const text = nudgeMessage(message);
    const turn = this.activeTurn;
    if (!this.rpc || !this.threadId || !turn) {
      this.queued.push(text);
      return;
    }
    this.rpc.request("turn/steer", { threadId: this.threadId, expectedTurnId: turn, input: textInput(text) }).catch(() => {
      // Not steerable right now: deliver it as the next turn instead.
      this.queued.push(text);
      if (!this.activeTurn) this.startQueuedTurn();
    });
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

  private args(): string[] {
    const args = ["app-server"];
    for (const f of DISABLED_FEATURES) args.push("-c", `features.${f}=false`);
    args.push("-c", `web_search=${JSON.stringify(this.plan.webSearch)}`);
    if (!this.plan.charter) args.push("-c", "project_doc_max_bytes=0");
    if (this.plan.mcp) {
      const { usable, skipped } = usableWaygates(this.req.waygates);
      for (const w of usable) for (const o of codexMcpOverrides(w)) args.push("-c", o);
      for (const s of skipped) this.emit({ kind: "activity", activity: "system", text: `Waygate ${s.name} was skipped: ${s.reason}.` });
    }
    return args;
  }

  private instructions(): string {
    const notes =
      process.platform === "win32"
        ? [
            "Shell commands run in PowerShell 7 (pwsh) on Windows: use PowerShell syntax such as Set-Content, Get-Content and Remove-Item. cmd.exe syntax such as `echo text> file` does not redirect.",
          ]
        : [];
    if (!this.plan.commands) notes.push("You may read files, but this agent has no Forge: do not run commands that change anything.");
    return systemPromptFor(this.req, { names: this.opts.deps.names, notes });
  }

  private async run(): Promise<RunOutcome> {
    await Promise.resolve();
    if (this.stop) return { kind: "interrupted" };
    const proc = new HarnessProcess(this.opts.launch, this.args(), {
      cwd: this.req.cwd,
      env: harnessEnv(this.opts.deps.env),
      onRecord: (r) => this.rpc?.handle(r),
    });
    this.proc = proc;
    const rpc = new RpcClient((m) => proc.send(m), {
      onNotification: (method, params) => this.onNotification(method, params),
      onRequest: (method, params, id) => this.onRequest(method, params, id),
    });
    this.rpc = rpc;
    void proc.exited.then((exit) => rpc.close(exit.spawnError ?? `exited with code ${exit.code}`));
    if (this.stop === "kill") this.stopping = proc.kill();

    try {
      await rpc.request("initialize", { clientInfo: { name: "aurelhaven_townhall", title: "Aurelhaven Town Hall", version: DAEMON_VERSION }, capabilities: null }, 60_000);
      rpc.notify("initialized");
      const resumed = await this.openThread(rpc);
      if (this.stop) {
        await this.stopProcess(proc);
      } else {
        await this.startTurn(firstMessageFor(this.req, resumed));
      }
    } catch (err) {
      if (!this.stop) {
        this.lastError = err instanceof Error ? err.message : String(err);
        void proc.stop(this.opts.exitGraceMs ?? 5_000);
      }
    }
    const exit = await proc.exited;
    await this.stopping;
    return this.outcome(exit, proc);
  }

  /** Resumes the saved thread, or starts a new one. Returns true when a thread was resumed. */
  private async openThread(rpc: RpcClient): Promise<boolean> {
    // Marking the work folder as an untrusted project keeps a repository's own .codex config
    // (which can start processes) from loading, and stops the app server from writing a
    // `trust_level = "trusted"` entry for every worktree into the player's ~/.codex/config.toml.
    const untrusted = { trust_level: "untrusted" };
    const settings: Record<string, unknown> = {
      cwd: this.req.cwd,
      approvalPolicy: "untrusted",
      sandbox: this.plan.sandbox,
      developerInstructions: this.instructions(),
      config: { projects: { [this.req.cwd]: untrusted, [this.req.workspaceRoot]: untrusted } },
    };
    const model = this.req.model.trim();
    if (model && model !== "default") settings.model = model;
    const prior = isCheckpoint(this.req.resume?.state) ? this.req.resume.state.threadId : (this.req.resume?.sessionId ?? null);
    let response: unknown = null;
    let resumed = false;
    if (prior) {
      try {
        response = await rpc.request("thread/resume", { threadId: prior, ...settings }, 60_000);
        resumed = true;
      } catch {
        this.emit({ kind: "activity", activity: "system", text: "The earlier Codex thread could not be resumed; starting a new one." });
      }
    }
    if (!resumed) response = await rpc.request("thread/start", { ...settings, ephemeral: false }, 60_000);
    const r = isPlainObject(response) ? response : {};
    const thread = isPlainObject(r.thread) ? r.thread : {};
    const threadId = asString(thread.id);
    if (!threadId) throw new Error("the app server started no thread");
    this.threadId = threadId;
    this.model = asString(r.model) ?? this.model;
    this.emit({ kind: "session", sessionId: threadId });
    this.host.checkpoint({ v: 1, harness: "codex", threadId } satisfies CodexCheckpoint);
    return resumed;
  }

  private async startTurn(text: string): Promise<void> {
    const rpc = this.rpc!;
    const response = await rpc.request("turn/start", { threadId: this.threadId, input: textInput(text) }, 60_000);
    const turn = isPlainObject(response) && isPlainObject(response.turn) ? response.turn : {};
    const id = asString(turn.id);
    if (id) {
      this.ourTurns.add(id);
      this.activeTurn ??= id;
    }
  }

  private startQueuedTurn(): void {
    const text = this.queued.splice(0).join("\n\n");
    if (!text) return;
    this.startTurn(text).catch((err: unknown) => {
      this.lastError = err instanceof Error ? err.message : String(err);
      void this.proc?.stop(this.opts.exitGraceMs ?? 10_000);
    });
  }

  private finish(): void {
    if (this.finishing) return;
    this.finishing = true;
    void this.proc?.stop(this.opts.exitGraceMs ?? 10_000);
  }

  private async interruptProcess(proc: HarnessProcess): Promise<void> {
    if (this.rpc && this.threadId && this.activeTurn) {
      const waiting = new Promise<void>((resolve) => this.turnWaiters.push(resolve));
      this.rpc.request("turn/interrupt", { threadId: this.threadId, turnId: this.activeTurn }, 10_000).catch(() => undefined);
      await Promise.race([waiting, proc.exited, new Promise((r) => setTimeout(r, 5_000))]);
    }
    await this.stopProcess(proc);
  }

  private stopProcess(proc: HarnessProcess): Promise<unknown> {
    return proc.stop(this.opts.exitGraceMs ?? 8_000);
  }

  private outcome(exit: ExitInfo, proc: HarnessProcess): RunOutcome {
    if (exit.spawnError) {
      return { kind: "failed", error: { code: "not_installed", message: `Codex could not start: ${exit.spawnError}`, transient: false } };
    }
    if (this.stop) return { kind: "interrupted" };
    if (this.completed && !this.turnError) {
      return { kind: "completed", summary: this.lastAgentText.trim() || "The agent finished." };
    }
    const errors = [...new Set([this.turnError, this.lastError].filter((s): s is string => !!s && s.trim() !== ""))];
    const detail = errors.length > 0 ? errors.join(" | ") : proc.stderrTail();
    const cls = classifyFailure(detail);
    const message = detail ? cleanText(detail, this.opts.deps.redactor, 600) : `Codex exited with code ${exit.code ?? "unknown"}`;
    return { kind: "failed", error: { code: cls.code, message, transient: cls.transient } };
  }

  // ---------- notifications ----------

  private onNotification(method: string, raw: unknown): void {
    const p = isPlainObject(raw) ? raw : {};
    try {
      switch (method) {
        case "turn/started": {
          const turn = isPlainObject(p.turn) ? p.turn : {};
          const id = asString(turn.id);
          if (id && asString(p.threadId) === this.threadId) {
            this.ourTurns.add(id);
            this.activeTurn = id;
          }
          break;
        }
        case "item/started":
          this.onItemStarted(isPlainObject(p.item) ? p.item : {});
          break;
        case "item/completed":
          this.onItemCompleted(isPlainObject(p.item) ? p.item : {});
          break;
        case "thread/tokenUsage/updated":
          this.onTokenUsage(p);
          break;
        case "turn/completed":
          this.onTurnCompleted(isPlainObject(p.turn) ? p.turn : {});
          break;
        case "error": {
          const error = isPlainObject(p.error) ? p.error : {};
          if (p.willRetry === true) {
            this.emit({ kind: "activity", activity: "system", text: `Codex is retrying: ${String(error.message ?? "error")}` });
          } else {
            this.lastError = describeError(error);
          }
          break;
        }
        case "warning": {
          const message = asString(p.message);
          if (message) this.emit({ kind: "activity", activity: "system", text: cleanText(`Codex: ${message}`, this.opts.deps.redactor) });
          break;
        }
        case "mcpServer/startupStatus/updated": {
          if (p.status === "failed") {
            this.emit({ kind: "activity", activity: "system", text: `MCP server ${String(p.name)} did not start: ${String(p.error ?? "unknown error")}` });
          }
          break;
        }
        default:
          break;
      }
    } catch (err) {
      this.opts.deps.log?.warn({ taskId: this.req.taskId, method, err: String(err) }, "codex notification handling failed");
    }
  }

  private toolOf(item: Record<string, unknown>): { tool: string; input: unknown; text: string } | null {
    switch (item.type) {
      case "commandExecution": {
        const command = asString(item.command) ?? "";
        return { tool: "shell", input: { command, cwd: item.cwd }, text: `Run: ${command}` };
      }
      case "fileChange": {
        const paths = this.changePaths(item);
        return { tool: "apply_patch", input: { changes: paths }, text: `Edit: ${paths.map((p) => displayTarget(p, this.req.cwd)).join(", ")}` };
      }
      case "mcpToolCall":
        return { tool: `mcp__${String(item.server)}__${String(item.tool)}`, input: item.arguments, text: `Use ${String(item.tool)} on ${String(item.server)}` };
      case "webSearch":
        return { tool: "web_search", input: { query: item.query }, text: `Search the web${typeof item.query === "string" ? `: ${item.query}` : ""}` };
      case "dynamicToolCall":
        return { tool: String(item.tool), input: item.arguments, text: String(item.tool) };
      default:
        return null;
    }
  }

  private changePaths(item: Record<string, unknown>): string[] {
    const changes = Array.isArray(item.changes) ? item.changes : [];
    return changes.filter(isPlainObject).map((c) => String(c.path));
  }

  private onItemStarted(item: Record<string, unknown>): void {
    const id = asString(item.id);
    if (id) this.items.set(id, item);
    const tool = this.toolOf(item);
    if (tool) this.emit({ kind: "tool_start", tool: tool.tool, input: tool.input, text: tool.text });
  }

  private onItemCompleted(item: Record<string, unknown>): void {
    const id = asString(item.id);
    if (id) this.items.delete(id);
    if (item.type === "agentMessage") {
      const text = asString(item.text)?.trim();
      if (text) {
        this.lastAgentText = text;
        this.emit({ kind: "activity", activity: "message", text: cleanText(text, this.opts.deps.redactor) });
      }
      return;
    }
    if (item.type === "plan") {
      const text = asString(item.text)?.trim();
      if (text) this.emit({ kind: "activity", activity: "message", text: cleanText(`Plan: ${text}`, this.opts.deps.redactor) });
      return;
    }
    if (item.type === "contextCompaction") {
      this.emit({ kind: "activity", activity: "system", text: "Codex compacted its conversation." });
      return;
    }
    const tool = this.toolOf(item);
    if (!tool) return;
    let ok = item.status === "completed";
    if (item.type === "commandExecution") ok = ok && (item.exitCode === 0 || item.exitCode === null || item.exitCode === undefined);
    this.emit({ kind: "tool_end", tool: tool.tool, ok, text: ok ? tool.text : `${tool.text} (failed or declined)` });
    if (ok && item.type === "fileChange") {
      const paths = this.changePaths(item).map((p) => displayTarget(p, this.req.cwd));
      if (paths.length > 0) this.emit({ kind: "files_touched", paths });
    }
  }

  private onTokenUsage(p: Record<string, unknown>): void {
    const turnId = asString(p.turnId);
    if (!turnId || !this.ourTurns.has(turnId)) return;
    const usage = isPlainObject(p.tokenUsage) ? p.tokenUsage : {};
    const total = tokensOf(usage.total);
    const last = tokensOf(usage.last);
    let delta: Tokens | null;
    if (total && this.prevTotal) {
      delta = {
        inputTokens: Math.max(0, total.inputTokens - this.prevTotal.inputTokens),
        cachedInputTokens: Math.max(0, total.cachedInputTokens - this.prevTotal.cachedInputTokens),
        outputTokens: Math.max(0, total.outputTokens - this.prevTotal.outputTokens),
      };
    } else {
      // First update of this process: the thread total may include earlier attempts.
      delta = last;
    }
    if (total) this.prevTotal = total;
    if (!delta || delta.inputTokens + delta.outputTokens === 0) return;
    const cached = Math.min(delta.cachedInputTokens, delta.inputTokens);
    const usd = this.opts.deps.pricing.costUsd("codex", this.model, {
      input: delta.inputTokens - cached,
      cacheRead: cached,
      cacheWrite: 0,
      output: delta.outputTokens,
    });
    if (usd === null) return;
    this.emit({
      kind: "usage",
      costMicros: usdToMicros(usd),
      inputTokens: delta.inputTokens,
      outputTokens: delta.outputTokens,
      ...(this.opts.estimate !== undefined ? { estimate: this.opts.estimate } : {}),
    });
  }

  private onTurnCompleted(turn: Record<string, unknown>): void {
    const id = asString(turn.id);
    if (!id || !this.ourTurns.has(id)) return;
    if (this.activeTurn === id) this.activeTurn = null;
    for (const w of this.turnWaiters.splice(0)) w();
    const status = asString(turn.status);
    if (status === "failed") {
      const error = isPlainObject(turn.error) ? turn.error : {};
      this.turnError = describeError(error);
      this.finish();
      return;
    }
    if (this.stop) return;
    if (status === "interrupted") {
      this.turnError = "Codex interrupted the turn";
      this.finish();
      return;
    }
    if (this.queued.length > 0) {
      this.startQueuedTurn();
      return;
    }
    this.completed = true;
    this.finish();
  }

  // ---------- approvals and other server requests ----------

  private async ask(req: ApprovalRequest): Promise<ApprovalAnswer> {
    if (this.stop) return { decision: "deny", cancelled: true };
    return this.host.requestApproval(req);
  }

  private async onRequest(method: string, raw: unknown, _id: RpcId): Promise<unknown> {
    const p = isPlainObject(raw) ? raw : {};
    switch (method) {
      case "item/commandExecution/requestApproval":
        return { decision: await this.commandApproval(p) };
      case "item/fileChange/requestApproval":
        return { decision: await this.fileApproval(p) };
      case "item/permissions/requestApproval":
        return this.permissionsApproval(p);
      case "mcpServer/elicitation/request":
        return this.elicitation(p);
      case "item/tool/requestUserInput":
        return this.userInput(p);
      case "execCommandApproval": {
        const command = Array.isArray(p.command) ? p.command.map(String).join(" ") : String(p.command ?? "");
        const d = await this.commandApproval({ command, cwd: p.cwd, reason: p.reason });
        return { decision: d === "accept" ? "approved" : d === "cancel" ? "abort" : "denied" };
      }
      case "applyPatchApproval": {
        const changes = isPlainObject(p.fileChanges) ? Object.keys(p.fileChanges) : [];
        const d = await this.fileApprovalFor(changes, asString(p.reason), asString(p.grantRoot));
        return { decision: d === "accept" ? "approved" : d === "cancel" ? "abort" : "denied" };
      }
      default:
        throw new RpcError(-32601, `the Town Hall does not handle ${method}`);
    }
  }

  private async commandApproval(p: Record<string, unknown>): Promise<Decision> {
    const command = asString(p.command) ?? "";
    const cwd = asString(p.cwd) ?? this.req.cwd;
    if (!this.plan.commands) {
      // Capability, not approval: without a Forge the agent may only run Codex's known-safe reads.
      this.emit({ kind: "activity", activity: "system", text: `Refused a command (the agent has no Forge): ${command}` });
      return "decline";
    }
    const network = isPlainObject(p.networkApprovalContext);
    const input: Record<string, unknown> = { command, cwd };
    const answer = await this.ask(approvalFor("shell", network ? "network" : "command", input, this.req.cwd, asString(p.reason)));
    return decisionOf(answer);
  }

  private fileApproval(p: Record<string, unknown>): Promise<Decision> {
    const item = this.items.get(asString(p.itemId) ?? "");
    const changes = item ? this.changePaths(item) : [];
    return this.fileApprovalFor(changes, asString(p.reason), asString(p.grantRoot));
  }

  private async fileApprovalFor(changes: string[], reason: string | null, grantRoot: string | null): Promise<Decision> {
    const outside = changes.find((c) => {
      const rel = path.relative(this.req.workspaceRoot, path.resolve(this.req.cwd, c));
      return rel.startsWith("..") || path.isAbsolute(rel);
    });
    // `path` lets the Town Hall spot a write outside the work folder.
    const target = grantRoot ?? outside ?? changes[0];
    const input: Record<string, unknown> = { ...(target ? { path: target } : {}), changes };
    const req = approvalFor("apply_patch", "write", input, this.req.cwd, reason);
    const shown = changes.map((c) => displayTarget(c, this.req.cwd));
    const answer = await this.ask({ ...req, summary: shown.length > 0 ? `Edit: ${shown.join(", ")}` : "Edit files" });
    return decisionOf(answer);
  }

  private async permissionsApproval(p: Record<string, unknown>): Promise<unknown> {
    const permissions = isPlainObject(p.permissions) ? p.permissions : {};
    const network = isPlainObject(permissions.network) && permissions.network.enabled === true;
    const fs = isPlainObject(permissions.fileSystem) ? permissions.fileSystem : null;
    const paths = fs ? [...(Array.isArray(fs.write) ? fs.write : []), ...(Array.isArray(fs.read) ? fs.read : [])].map(String) : [];
    const input: Record<string, unknown> = { ...(paths[0] ? { path: paths[0] } : {}), permissions };
    const answer = await this.ask({
      ...approvalFor("permissions", network ? "network" : paths.length > 0 ? "outside_workspace" : "command", input, this.req.cwd, asString(p.reason)),
      summary: network ? "Allow network access for this turn" : `Allow access to ${paths.join(", ") || "more files"} for this turn`,
    });
    if (answer.decision === "allow" && !answer.cancelled) return { permissions, scope: "turn" };
    return { permissions: {}, scope: "turn" };
  }

  private async elicitation(p: Record<string, unknown>): Promise<unknown> {
    const meta = isPlainObject(p._meta) ? p._meta : {};
    const server = asString(p.serverName) ?? "mcp";
    const message = asString(p.message) ?? "";
    if (meta.codex_approval_kind === "mcp_tool_call" || /run tool/i.test(message)) {
      const tool = asString(meta.tool_name) ?? "tool";
      const input = isPlainObject(meta.tool_params) ? meta.tool_params : {};
      const answer = await this.ask({ ...approvalFor(`mcp__${server}__${tool}`, "mcp", input, this.req.cwd), summary: `Use ${tool} on ${server}` });
      const d = decisionOf(answer);
      return { action: d, content: d === "accept" ? {} : null, _meta: null };
    }
    // Any other form: the Town Hall has no way to fill it in.
    this.emit({ kind: "activity", activity: "system", text: `Declined a request for input from ${server}: ${cleanText(message, this.opts.deps.redactor, 300)}` });
    return { action: "decline", content: null, _meta: null };
  }

  private async userInput(p: Record<string, unknown>): Promise<unknown> {
    const questions = Array.isArray(p.questions) ? p.questions.filter(isPlainObject) : [];
    const answers: Record<string, { answers: string[] }> = {};
    for (const q of questions) {
      const id = asString(q.id) ?? "";
      if (id.startsWith(MCP_APPROVAL_QUESTION)) {
        const text = asString(q.question) ?? "Allow an MCP tool call?";
        const answer = await this.ask({ tool: "mcp", category: "mcp", input: { question: text }, summary: text });
        answers[id] = { answers: [answer.decision === "allow" && !answer.cancelled ? "Allow" : "Cancel"] };
      } else {
        this.emit({ kind: "activity", activity: "system", text: `The agent asked a question the Town Hall cannot pass on: ${asString(q.question) ?? id}` });
      }
    }
    return { answers };
  }
}
