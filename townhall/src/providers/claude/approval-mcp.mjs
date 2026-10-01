#!/usr/bin/env node
// AgentEmpire approval server for Claude Code's `--permission-prompt-tool`.
//
// A dependency-free MCP server (JSON-RPC 2.0 over stdio, one message per line) with a single
// tool, `approve`. Claude Code calls it whenever a tool call needs permission. Each call is
// forwarded to the Town Hall's per-run loopback listener, which asks the player (or applies the
// agent's approval mode) and answers with Claude Code's permission result:
//   {"behavior":"allow","updatedInput":{...}}  or  {"behavior":"deny","message":"..."}
//
// Environment (set by the Town Hall for this run only):
//   AURELHAVEN_APPROVAL_URL    http://127.0.0.1:<port>/approve
//   AURELHAVEN_APPROVAL_TOKEN  bearer secret for that listener
//
// Any failure is answered with a deny: this server never allows anything on its own.
import http from "node:http";

const APPROVAL_URL = process.env.AURELHAVEN_APPROVAL_URL ?? "";
const APPROVAL_TOKEN = process.env.AURELHAVEN_APPROVAL_TOKEN ?? "";
const SUPPORTED_PROTOCOLS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
const PROGRESS_EVERY_MS = 20_000;
const MAX_BODY_BYTES = 4 * 1024 * 1024;

const APPROVE_TOOL = {
  name: "approve",
  description:
    "Asks the AgentEmpire Town Hall whether a tool call may run. Used by Claude Code as its permission prompt tool; the model should not call it directly.",
  inputSchema: {
    type: "object",
    properties: {
      tool_name: { type: "string", description: "The tool that wants to run." },
      input: { type: "object", description: "The tool's input.", additionalProperties: true },
      tool_use_id: { type: "string", description: "The tool use id, when known." },
    },
    required: ["tool_name", "input"],
  },
};

/** In-flight tools/call requests by JSON-RPC id, so a cancellation can abort the HTTP wait. */
const inflight = new Map();

function write(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function reply(id, result) {
  write({ jsonrpc: "2.0", id, result });
}

function replyError(id, code, message) {
  write({ jsonrpc: "2.0", id, error: { code, message } });
}

function deny(message) {
  return { behavior: "deny", message };
}

function textResult(decision) {
  return { content: [{ type: "text", text: JSON.stringify(decision) }] };
}

/** POSTs the request to the Town Hall and resolves with its decision. No timeout: approvals may wait for hours. */
function askTownHall(payload, signal) {
  return new Promise((resolve) => {
    if (!APPROVAL_URL || !APPROVAL_TOKEN) {
      resolve(deny("The Town Hall approval channel is not configured."));
      return;
    }
    let url;
    try {
      url = new URL(APPROVAL_URL);
    } catch {
      resolve(deny("The Town Hall approval channel address is invalid."));
      return;
    }
    const body = Buffer.from(JSON.stringify(payload), "utf8");
    const req = http.request(
      {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname,
        method: "POST",
        headers: {
          authorization: `Bearer ${APPROVAL_TOKEN}`,
          "content-type": "application/json",
          "content-length": body.length,
        },
      },
      (res) => {
        const chunks = [];
        let size = 0;
        res.on("data", (chunk) => {
          size += chunk.length;
          if (size <= MAX_BODY_BYTES) chunks.push(chunk);
        });
        res.on("end", () => {
          if (res.statusCode !== 200) {
            resolve(deny(`The Town Hall refused the approval request (HTTP ${res.statusCode}).`));
            return;
          }
          try {
            const decision = JSON.parse(Buffer.concat(chunks).toString("utf8"));
            if (decision && (decision.behavior === "allow" || decision.behavior === "deny")) resolve(decision);
            else resolve(deny("The Town Hall sent an unreadable decision."));
          } catch {
            resolve(deny("The Town Hall sent an unreadable decision."));
          }
        });
        res.on("error", () => resolve(deny("The connection to the Town Hall broke.")));
      },
    );
    req.on("error", () => resolve(deny("The Town Hall could not be reached.")));
    if (signal) {
      const onAbort = () => {
        req.destroy();
        resolve(deny("The approval request was cancelled."));
      };
      if (signal.aborted) onAbort();
      else signal.addEventListener("abort", onAbort, { once: true });
    }
    req.end(body);
  });
}

async function callApprove(id, params) {
  const args = params && typeof params.arguments === "object" && params.arguments !== null ? params.arguments : {};
  const toolName = typeof args.tool_name === "string" ? args.tool_name : "";
  if (!toolName) {
    reply(id, textResult(deny("The permission request named no tool.")));
    return;
  }
  const input = args.input && typeof args.input === "object" ? args.input : {};
  const payload = { tool_name: toolName, input };
  if (typeof args.tool_use_id === "string") payload.tool_use_id = args.tool_use_id;

  const controller = new AbortController();
  inflight.set(id, controller);
  const progressToken = params?._meta?.progressToken;
  let progress = 0;
  const timer =
    progressToken === undefined
      ? null
      : setInterval(() => {
          progress += 1;
          write({
            jsonrpc: "2.0",
            method: "notifications/progress",
            params: { progressToken, progress, message: "Waiting for the Town Hall" },
          });
        }, PROGRESS_EVERY_MS);
  try {
    const decision = await askTownHall(payload, controller.signal);
    if (inflight.has(id)) reply(id, textResult(decision));
  } finally {
    if (timer) clearInterval(timer);
    inflight.delete(id);
  }
}

function handle(message) {
  if (!message || typeof message !== "object") return;
  const { id, method, params } = message;
  const isRequest = id !== undefined && id !== null && typeof method === "string";
  if (typeof method !== "string") return; // a response to something we never sent
  switch (method) {
    case "initialize": {
      const requested = params?.protocolVersion;
      reply(id, {
        protocolVersion: SUPPORTED_PROTOCOLS.includes(requested) ? requested : SUPPORTED_PROTOCOLS[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "aurelhaven", version: "1.0.0" },
      });
      return;
    }
    case "ping":
      if (isRequest) reply(id, {});
      return;
    case "tools/list":
      reply(id, { tools: [APPROVE_TOOL] });
      return;
    case "tools/call":
      if (params?.name !== APPROVE_TOOL.name) {
        replyError(id, -32602, `unknown tool ${String(params?.name)}`);
        return;
      }
      void callApprove(id, params);
      return;
    case "notifications/cancelled": {
      const controller = inflight.get(params?.requestId);
      inflight.delete(params?.requestId);
      controller?.abort();
      return;
    }
    default:
      if (isRequest) replyError(id, -32601, `method not found: ${method}`);
  }
}

// Strict LF framing: split only on "\n" (JSON strings may contain U+2028/U+2029).
let buffered = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffered += chunk;
  let newline;
  while ((newline = buffered.indexOf("\n")) >= 0) {
    let line = buffered.slice(0, newline);
    buffered = buffered.slice(newline + 1);
    if (line.endsWith("\r")) line = line.slice(0, -1);
    if (line.trim() === "") continue;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      write({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
      continue;
    }
    handle(message);
  }
});
process.stdin.on("end", () => {
  for (const controller of inflight.values()) controller.abort();
  process.exit(0);
});
