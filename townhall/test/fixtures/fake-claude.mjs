#!/usr/bin/env node
// A stand-in for the Claude Code CLI in tests. It speaks the same headless protocol the
// adapter uses (`-p` with stream-json in and out), reads `--mcp-config`, starts the approval
// MCP server listed there and calls its `approve` tool for every tool call, exactly as
// `--permission-prompt-tool` does, so the whole approval path runs for real.
//
// Controlled by environment variables:
//   FAKE_CLAUDE_SCENARIO  JSON file: {"turns":[{"steps":[...]}]} (see runStep for step kinds)
//   FAKE_CLAUDE_HOME      folder for fake sessions (<id>.json), which makes --resume work
//   FAKE_CLAUDE_LOG       JSON-lines file recording each invocation (argv, env names, approvals)
//   FAKE_CLAUDE_AUTH      "max" (default), "api" or "none" for `auth status`
import { spawn } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

const argv = process.argv.slice(2);
const env = process.env;

function log(entry) {
  if (!env.FAKE_CLAUDE_LOG) return;
  appendFileSync(env.FAKE_CLAUDE_LOG, `${JSON.stringify({ pid: process.pid, ...entry })}\n`);
}

function flag(name) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
}

if (argv[0] === "--version") {
  process.stdout.write("2.1.281 (Claude Code)\n");
  process.exit(0);
}
if (argv[0] === "auth" && argv[1] === "status") {
  const kind = env.FAKE_CLAUDE_AUTH ?? "max";
  const status =
    kind === "none"
      ? { loggedIn: false, authMethod: "none", apiProvider: "firstParty" }
      : kind === "api"
        ? { loggedIn: true, authMethod: "api_key", apiProvider: "firstParty" }
        : { loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty", email: "player@example.invalid", subscriptionType: "max" };
  process.stdout.write(`${JSON.stringify(status, null, 2)}\n`);
  process.exit(kind === "none" ? 1 : 0);
}

const home = env.FAKE_CLAUDE_HOME ?? path.join(process.cwd(), ".fake-claude");
mkdirSync(home, { recursive: true });
const scenario = env.FAKE_CLAUDE_SCENARIO ? JSON.parse(readFileSync(env.FAKE_CLAUDE_SCENARIO, "utf8")) : { turns: [] };

log({
  kind: "start",
  argv,
  cwd: process.cwd(),
  envNames: Object.keys(env).filter((k) => /^(AURELHAVEN|MCP_|CLAUDE|DISABLE_)/.test(k)),
  claudeMdsDisabled: env.CLAUDE_CODE_DISABLE_CLAUDE_MDS === "1",
});

function out(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

// ---------- sessions ----------

let sessionId = flag("--session-id");
let totalCost = 0;
const resumeId = flag("--resume");
if (resumeId) {
  const file = path.join(home, `${resumeId}.json`);
  if (!existsSync(file)) {
    process.stderr.write(`No conversation found with session ID: ${resumeId}\n`);
    out({
      type: "result",
      subtype: "error_during_execution",
      is_error: true,
      num_turns: 0,
      session_id: resumeId,
      total_cost_usd: 0,
      errors: [`No conversation found with session ID: ${resumeId}`],
    });
    process.exit(1);
  }
  sessionId = resumeId;
  // Claude Code 2.1.277+ restores the session's cost total saved at its last clean exit.
  totalCost = JSON.parse(readFileSync(file, "utf8")).totalCost ?? 0;
}
sessionId ??= "00000000-0000-4000-8000-000000000000";

function saveSession() {
  writeFileSync(path.join(home, `${sessionId}.json`), JSON.stringify({ totalCost }));
}

// ---------- the approval MCP server from --mcp-config ----------

function expand(value) {
  return typeof value === "string" ? value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_m, name) => env[name] ?? "") : value;
}

const promptTool = flag("--permission-prompt-tool");
const mcpConfigPath = flag("--mcp-config");
const mcpConfig = mcpConfigPath ? JSON.parse(readFileSync(mcpConfigPath, "utf8")) : { mcpServers: {} };
log({ kind: "mcp_config", servers: mcpConfig.mcpServers });

let mcp = null;
function startMcp() {
  const [, serverName] = (promptTool ?? "").split("__");
  const server = mcpConfig.mcpServers?.[serverName];
  if (!server) return null;
  const childEnv = { ...env };
  for (const [k, v] of Object.entries(server.env ?? {})) childEnv[k] = expand(v);
  const child = spawn(expand(server.command), (server.args ?? []).map(expand), { env: childEnv, stdio: ["pipe", "pipe", "inherit"], windowsHide: true });
  log({ kind: "mcp_started", pid: child.pid });
  const waiting = new Map();
  let buffer = "";
  let nextId = 1;
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    let i;
    while ((i = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, i);
      buffer = buffer.slice(i + 1);
      if (!line.trim()) continue;
      const msg = JSON.parse(line);
      if (msg.id !== undefined && waiting.has(msg.id)) {
        waiting.get(msg.id)(msg);
        waiting.delete(msg.id);
      }
    }
  });
  const request = (method, params) =>
    new Promise((resolve) => {
      const id = nextId++;
      waiting.set(id, resolve);
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });
  const ready = (async () => {
    const init = await request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "fake-claude", version: "1" } });
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`);
    const list = await request("tools/list", {});
    return { init: init.result, tools: list.result.tools.map((t) => t.name) };
  })();
  return { child, request, ready };
}

async function askPermission(toolName, input, toolUseId) {
  mcp ??= startMcp();
  if (!mcp) return { behavior: "deny", message: "no permission prompt tool" };
  await mcp.ready;
  const [, , tool] = promptTool.split("__");
  const res = await mcp.request("tools/call", { name: tool, arguments: { tool_name: toolName, input, tool_use_id: toolUseId } });
  const decision = JSON.parse(res.result.content[0].text);
  log({ kind: "approval", tool: toolName, decision });
  return decision;
}

// ---------- turns ----------

let initSent = false;
let turnIndex = 0;
let interrupted = false;
let wakeHang = null;
const queue = [];
let busy = false;
let inputClosed = false;
let toolSeq = 0;

function sendInit() {
  if (initSent) return;
  initSent = true;
  out({
    type: "system",
    subtype: "init",
    session_id: sessionId,
    cwd: process.cwd(),
    tools: (flag("--tools") ?? "").split(",").filter(Boolean),
    mcp_servers: Object.keys(mcpConfig.mcpServers ?? {}).map((name) => ({ name, status: "connected" })),
    model: flag("--model") ?? "default",
    permissionMode: flag("--permission-mode") ?? "default",
    capabilities: ["interrupt_receipt_v1", "interrupt_cancel_queued_v1", "msg_lifecycle_v1"],
  });
}

function assistant(content, extra = {}) {
  out({ type: "assistant", session_id: sessionId, parent_tool_use_id: null, message: { role: "assistant", content }, ...extra });
}

async function runStep(step, state) {
  if (interrupted) return;
  if (step.text !== undefined) {
    assistant([{ type: "text", text: step.text }]);
    state.lastText = step.text;
  } else if (step.tool) {
    const id = `toolu_${++toolSeq}`;
    const input = step.input ?? {};
    assistant([{ type: "tool_use", id, name: step.tool, input }]);
    const decision = await askPermission(step.tool, input, id);
    if (decision.behavior === "allow") {
      const used = decision.updatedInput ?? input;
      if (step.tool === "Write" && used.file_path) {
        const target = path.resolve(process.cwd(), used.file_path);
        mkdirSync(path.dirname(target), { recursive: true });
        writeFileSync(target, used.content ?? "");
      }
      out({ type: "user", session_id: sessionId, message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content: "ok" }] } });
    } else {
      out({
        type: "user",
        session_id: sessionId,
        message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content: decision.message, is_error: true }] },
      });
      if (decision.interrupt) interrupted = true;
    }
  } else if (step.cost !== undefined) {
    totalCost += step.cost;
  } else if (step.sleep !== undefined) {
    await new Promise((r) => setTimeout(r, step.sleep));
  } else if (step.hang) {
    await new Promise((resolve) => {
      wakeHang = resolve;
    });
  } else if (step.error) {
    assistant([{ type: "text", text: step.error_text ?? "API Error" }], { error: step.error });
    state.error = step.error_text ?? step.error;
  }
}

async function runTurn(message) {
  busy = true;
  interrupted = false;
  sendInit();
  const uuid = message.uuid;
  out({ type: "command_lifecycle", command_uuid: uuid, state: "started", session_id: sessionId });
  const text = message.message?.content?.[0]?.text ?? "";
  log({ kind: "message", text });
  const turn = scenario.turns?.[turnIndex++] ?? { steps: [{ text: `Noted: ${text}` }] };
  const state = { lastText: "" };
  for (const step of turn.steps ?? []) {
    await runStep(step, state);
    if (interrupted) break;
  }
  if (interrupted) {
    out({ type: "result", subtype: "error_during_execution", is_error: true, session_id: sessionId, total_cost_usd: totalCost, user_message_uuids: [uuid], terminal_reason: "aborted" });
  } else if (state.error) {
    out({ type: "result", subtype: "success", is_error: true, result: state.error, session_id: sessionId, total_cost_usd: totalCost, user_message_uuids: [uuid] });
  } else {
    out({ type: "result", subtype: "success", is_error: false, result: state.lastText, session_id: sessionId, total_cost_usd: totalCost, user_message_uuids: [uuid], num_turns: 1 });
  }
  out({ type: "command_lifecycle", command_uuid: uuid, state: "completed", session_id: sessionId });
  busy = false;
  pump();
}

function pump() {
  if (busy) return;
  const next = queue.shift();
  if (next) {
    void runTurn(next);
    return;
  }
  if (inputClosed) finish(0);
}

function finish(code) {
  saveSession();
  log({ kind: "exit", code, totalCost });
  mcp?.child.stdin.end();
  process.exit(code);
}

let stdinBuffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  stdinBuffer += chunk;
  let i;
  while ((i = stdinBuffer.indexOf("\n")) >= 0) {
    const line = stdinBuffer.slice(0, i);
    stdinBuffer = stdinBuffer.slice(i + 1);
    if (!line.trim()) continue;
    const msg = JSON.parse(line);
    if (msg.type === "user") {
      out({ type: "command_lifecycle", command_uuid: msg.uuid, state: "queued", session_id: sessionId });
      queue.push(msg);
      pump();
    } else if (msg.type === "control_request") {
      const sub = msg.request?.subtype;
      if (sub === "interrupt") {
        log({ kind: "interrupt", cancel_queued: msg.request.cancel_queued === true });
        const cancelled = msg.request.cancel_queued ? queue.splice(0).map((m) => m.uuid) : [];
        out({ type: "control_response", response: { subtype: "success", request_id: msg.request_id, response: { still_queued: [], cancelled } } });
        if (busy) {
          interrupted = true;
          wakeHang?.();
        }
      } else if (sub === "initialize") {
        out({
          type: "control_response",
          response: {
            subtype: "success",
            request_id: msg.request_id,
            response: {
              models: [
                { value: "default", resolvedModel: "claude-opus-5-5[1m]", displayName: "Default (recommended)", description: "Opus 5.5" },
                { value: "haiku", resolvedModel: "claude-haiku-4-5-20251001", displayName: "Haiku", description: "Haiku 4.5" },
              ],
              account: { subscriptionType: "Claude Max" },
            },
          },
        });
      } else {
        out({ type: "control_response", response: { subtype: "error", request_id: msg.request_id, error: `Unsupported control request subtype: ${sub}` } });
      }
    }
  }
});
process.stdin.on("end", () => {
  inputClosed = true;
  wakeHang?.();
  pump();
});
