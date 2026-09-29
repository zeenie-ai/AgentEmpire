#!/usr/bin/env node
// A stand-in for the Codex CLI in tests: `--version`, `login status`, and `app-server`, which
// speaks the app server's JSON-RPC (one object per line, no "jsonrpc" member) and asks for
// approvals with server-to-client requests, as codex app-server 0.144 does.
//
// Controlled by environment variables:
//   FAKE_CODEX_SCENARIO  JSON file: {"turns":[{"steps":[...]}]} (see runStep for step kinds)
//   FAKE_CODEX_HOME      folder for fake threads (<id>.json), which makes thread/resume work
//   FAKE_CODEX_LOG       JSON-lines file recording argv, requests and approval answers
//   FAKE_CODEX_AUTH      "chatgpt" (default), "api" or "none"
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

const argv = process.argv.slice(2);
const env = process.env;

function log(entry) {
  if (env.FAKE_CODEX_LOG) appendFileSync(env.FAKE_CODEX_LOG, `${JSON.stringify({ pid: process.pid, ...entry })}\n`);
}

if (argv[0] === "--version") {
  process.stdout.write("codex-cli 0.144.2\n");
  process.exit(0);
}
if (argv[0] === "login" && argv[1] === "status") {
  const kind = env.FAKE_CODEX_AUTH ?? "chatgpt";
  if (kind === "none") {
    process.stdout.write("Not logged in\n");
    process.exit(1);
  }
  process.stdout.write(kind === "api" ? "Logged in using an API key - sk-proj-***abcd\n" : "Logged in using ChatGPT\n");
  process.exit(0);
}
if (argv[0] !== "app-server") {
  process.stderr.write(`fake codex: unsupported command ${argv.join(" ")}\n`);
  process.exit(2);
}

const home = env.FAKE_CODEX_HOME ?? path.join(process.cwd(), ".fake-codex");
mkdirSync(home, { recursive: true });
const scenario = env.FAKE_CODEX_SCENARIO ? JSON.parse(readFileSync(env.FAKE_CODEX_SCENARIO, "utf8")) : { turns: [] };
const overrides = [];
for (let i = 1; i < argv.length; i++) if (argv[i] === "-c") overrides.push(argv[++i]);
log({ kind: "start", argv, overrides, cwd: process.cwd() });

function out(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

let nextServerId = 1000;
const waiting = new Map();
function serverRequest(method, params) {
  const id = nextServerId++;
  return new Promise((resolve) => {
    waiting.set(id, resolve);
    out({ id, method, params });
  });
}

let thread = null; // { id, total: {inputTokens, cachedInputTokens, outputTokens, ...} }
let turnCounter = 0;
let turnIndex = 0;
let active = null; // { id, interrupted, wake, steers }
let itemSeq = 0;

function saveThread() {
  if (thread) writeFileSync(path.join(home, `${thread.id}.json`), JSON.stringify(thread));
}

function breakdown(t) {
  return { totalTokens: t.inputTokens + t.outputTokens, inputTokens: t.inputTokens, cachedInputTokens: t.cachedInputTokens, outputTokens: t.outputTokens, reasoningOutputTokens: 0 };
}

async function runStep(step, turn) {
  if (turn.interrupted) return;
  const threadId = thread.id;
  if (step.text !== undefined) {
    const id = `item_${++itemSeq}`;
    out({ method: "item/started", params: { threadId, turnId: turn.id, item: { type: "agentMessage", id, text: "", phase: null, memoryCitation: null }, startedAtMs: Date.now() } });
    out({ method: "item/completed", params: { threadId, turnId: turn.id, item: { type: "agentMessage", id, text: step.text, phase: null, memoryCitation: null }, completedAtMs: Date.now() } });
  } else if (step.command !== undefined) {
    const id = `item_${++itemSeq}`;
    const item = { type: "commandExecution", id, command: step.command, cwd: process.cwd(), processId: null, source: "agent", status: "inProgress", commandActions: [], aggregatedOutput: null, exitCode: null, durationMs: null };
    out({ method: "item/started", params: { threadId, turnId: turn.id, item, startedAtMs: Date.now() } });
    const res = await serverRequest("item/commandExecution/requestApproval", {
      threadId,
      turnId: turn.id,
      itemId: id,
      startedAtMs: Date.now(),
      environmentId: null,
      command: step.command,
      cwd: process.cwd(),
      ...(step.network ? { networkApprovalContext: { host: "example.org" } } : {}),
      ...(step.reason ? { reason: step.reason } : {}),
    });
    log({ kind: "approval", method: "item/commandExecution/requestApproval", response: res });
    const accepted = res.result?.decision === "accept";
    if (res.result?.decision === "cancel") turn.interrupted = true;
    out({
      method: "item/completed",
      params: { threadId, turnId: turn.id, item: { ...item, status: accepted ? "completed" : "declined", exitCode: accepted ? (step.exitCode ?? 0) : null }, completedAtMs: Date.now() },
    });
  } else if (step.patch !== undefined) {
    const id = `item_${++itemSeq}`;
    const changes = step.patch.map((f) => ({ path: path.resolve(process.cwd(), f.path), kind: { type: "add" }, diff: f.content }));
    const item = { type: "fileChange", id, changes, status: "inProgress" };
    out({ method: "item/started", params: { threadId, turnId: turn.id, item, startedAtMs: Date.now() } });
    const res = await serverRequest("item/fileChange/requestApproval", { threadId, turnId: turn.id, itemId: id, startedAtMs: Date.now(), reason: null });
    log({ kind: "approval", method: "item/fileChange/requestApproval", response: res });
    const accepted = res.result?.decision === "accept";
    if (accepted) {
      for (const f of step.patch) {
        const target = path.resolve(process.cwd(), f.path);
        mkdirSync(path.dirname(target), { recursive: true });
        writeFileSync(target, f.content);
      }
    }
    if (res.result?.decision === "cancel") turn.interrupted = true;
    out({ method: "item/completed", params: { threadId, turnId: turn.id, item: { ...item, status: accepted ? "completed" : "declined" }, completedAtMs: Date.now() } });
  } else if (step.mcp !== undefined) {
    const res = await serverRequest("mcpServer/elicitation/request", {
      threadId,
      turnId: turn.id,
      serverName: step.mcp.server,
      mode: "form",
      message: `Allow the ${step.mcp.server} MCP server to run tool "${step.mcp.tool}"?`,
      _meta: { codex_approval_kind: "mcp_tool_call", tool_name: step.mcp.tool, tool_params: step.mcp.params ?? {} },
      requestedSchema: { type: "object", properties: {} },
    });
    log({ kind: "approval", method: "mcpServer/elicitation/request", response: res });
  } else if (step.tokens !== undefined) {
    const last = { inputTokens: step.tokens.input, cachedInputTokens: step.tokens.cached ?? 0, outputTokens: step.tokens.output };
    thread.total = {
      inputTokens: thread.total.inputTokens + last.inputTokens,
      cachedInputTokens: thread.total.cachedInputTokens + last.cachedInputTokens,
      outputTokens: thread.total.outputTokens + last.outputTokens,
    };
    out({ method: "thread/tokenUsage/updated", params: { threadId, turnId: turn.id, tokenUsage: { total: breakdown(thread.total), last: breakdown(last), modelContextWindow: 272000 } } });
  } else if (step.sleep !== undefined) {
    await new Promise((resolve) => setTimeout(resolve, step.sleep));
  } else if (step.hang) {
    await new Promise((resolve) => {
      turn.wake = resolve;
    });
  } else if (step.fail !== undefined) {
    turn.failure = { message: step.message ?? "the turn failed", codexErrorInfo: step.fail, additionalDetails: null };
  }
}

async function runTurn(turn, text) {
  out({ method: "turn/started", params: { threadId: thread.id, turn: { id: turn.id, items: [], status: "inProgress", error: null } } });
  log({ kind: "turn", text });
  const script = scenario.turns?.[turnIndex++] ?? { steps: [{ text: `Noted: ${text}` }] };
  for (const step of script.steps ?? []) {
    await runStep(step, turn);
    if (turn.interrupted || turn.failure) break;
  }
  const status = turn.interrupted ? "interrupted" : turn.failure ? "failed" : "completed";
  active = null;
  saveThread();
  out({ method: "turn/completed", params: { threadId: thread.id, turn: { id: turn.id, items: [], status, error: turn.failure ?? null } } });
}

function handleRequest(msg) {
  const { id, method, params } = msg;
  log({ kind: "request", method, params: method === "thread/start" || method === "thread/resume" ? { ...params, developerInstructions: params.developerInstructions?.slice(0, 80) } : params });
  switch (method) {
    case "initialize":
      out({ id, result: { userAgent: "fake-codex/0.144.2", codexHome: home, platformFamily: "windows", platformOs: "windows" } });
      return;
    case "model/list":
      out({
        id,
        result: {
          data: [
            { id: "gpt-5.6-sol", model: "gpt-5.6-sol", displayName: "GPT-5.6-Sol", description: "Coding", hidden: false, isDefault: true },
            { id: "gpt-5.6-luna", model: "gpt-5.6-luna", displayName: "GPT-5.6-Luna", description: "Small", hidden: false, isDefault: false },
            { id: "secret-internal", model: "secret-internal", displayName: "Hidden", description: "", hidden: true, isDefault: false },
          ],
          nextCursor: null,
        },
      });
      return;
    case "thread/start":
      thread = { id: `thr_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`, total: { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0 }, params };
      saveThread();
      out({ id, result: { thread: { id: thread.id, status: { type: "idle" } }, model: params.model ?? "gpt-5.6-sol", cwd: params.cwd, approvalPolicy: params.approvalPolicy, sandbox: { type: params.sandbox } } });
      out({ method: "thread/started", params: { thread: { id: thread.id } } });
      return;
    case "thread/resume": {
      const file = path.join(home, `${params.threadId}.json`);
      if (!existsSync(file)) {
        out({ id, error: { code: -32600, message: `no rollout found for thread id ${params.threadId}` } });
        return;
      }
      thread = JSON.parse(readFileSync(file, "utf8"));
      out({ id, result: { thread: { id: thread.id, status: { type: "idle" } }, model: params.model ?? "gpt-5.6-sol" } });
      return;
    }
    case "turn/start": {
      const turn = { id: `turn_${++turnCounter}`, interrupted: false, wake: null };
      active = turn;
      out({ id, result: { turn: { id: turn.id, items: [], status: "inProgress", error: null } } });
      void runTurn(turn, params.input?.[0]?.text ?? "");
      return;
    }
    case "turn/steer":
      if (!active || active.id !== params.expectedTurnId) {
        out({ id, error: { code: -32600, message: "no active turn to steer" } });
        return;
      }
      log({ kind: "steer", text: params.input?.[0]?.text ?? "" });
      out({ id, result: { turnId: active.id } });
      return;
    case "turn/interrupt":
      log({ kind: "interrupt", turnId: params.turnId });
      if (active && active.id === params.turnId) {
        active.interrupted = true;
        active.wake?.();
      }
      out({ id, result: {} });
      return;
    default:
      out({ id, error: { code: -32601, message: `method not found: ${method}` } });
  }
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let i;
  while ((i = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, i);
    buffer = buffer.slice(i + 1);
    if (!line.trim()) continue;
    const msg = JSON.parse(line);
    if (msg.method !== undefined && msg.id !== undefined) handleRequest(msg);
    else if (msg.method !== undefined) log({ kind: "notification", method: msg.method });
    else if (msg.id !== undefined && waiting.has(msg.id)) {
      waiting.get(msg.id)(msg);
      waiting.delete(msg.id);
    }
  }
});
process.stdin.on("end", () => {
  saveThread();
  log({ kind: "exit" });
  process.exit(0);
});
