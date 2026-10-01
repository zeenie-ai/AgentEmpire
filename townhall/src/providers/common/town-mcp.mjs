#!/usr/bin/env node
// Aurelhaven town tools for a party lead: the MCP server "town".
//
// A dependency-free MCP server (JSON-RPC 2.0 over stdio, one message per line). Its tools
// (delegate, check_status, collect_results) are defined by the Town Hall: tools/list and every
// tools/call are forwarded to the run's loopback listener, which answers with the tool list or
// the tool's result. collect_results can wait for minutes; while it waits, MCP progress
// notifications keep the call alive.
//
// Environment (set by the Town Hall in this run's MCP config only):
//   AURELHAVEN_TOWN_URL    http://127.0.0.1:<port>/town
//   AURELHAVEN_TOWN_TOKEN  bearer secret for that listener
import http from "node:http";

const TOWN_URL = process.env.AURELHAVEN_TOWN_URL ?? "";
const TOWN_TOKEN = process.env.AURELHAVEN_TOWN_TOKEN ?? "";
const SUPPORTED_PROTOCOLS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
const PROGRESS_EVERY_MS = 20_000;
const MAX_BODY_BYTES = 4 * 1024 * 1024;

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

function toolError(message) {
  return { content: [{ type: "text", text: message }], isError: true };
}

/** POSTs to the Town Hall and resolves with its JSON answer, or { error } when that fails. */
function askTownHall(payload, signal) {
  return new Promise((resolve) => {
    if (!TOWN_URL || !TOWN_TOKEN) {
      resolve({ error: "The Town Hall channel for town tools is not configured." });
      return;
    }
    let url;
    try {
      url = new URL(TOWN_URL);
    } catch {
      resolve({ error: "The Town Hall channel address is invalid." });
      return;
    }
    const body = Buffer.from(JSON.stringify(payload), "utf8");
    const req = http.request(
      {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname,
        method: "POST",
        headers: { authorization: `Bearer ${TOWN_TOKEN}`, "content-type": "application/json", "content-length": body.length },
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
            resolve({ error: `The Town Hall refused the request (HTTP ${res.statusCode}).` });
            return;
          }
          try {
            resolve({ answer: JSON.parse(Buffer.concat(chunks).toString("utf8")) });
          } catch {
            resolve({ error: "The Town Hall sent an unreadable answer." });
          }
        });
        res.on("error", () => resolve({ error: "The connection to the Town Hall broke." }));
      },
    );
    req.on("error", () => resolve({ error: "The Town Hall could not be reached." }));
    if (signal) {
      const onAbort = () => {
        req.destroy();
        resolve({ error: "The request was cancelled." });
      };
      if (signal.aborted) onAbort();
      else signal.addEventListener("abort", onAbort, { once: true });
    }
    req.end(body);
  });
}

async function listTools(id) {
  const r = await askTownHall({ op: "list" });
  const tools = r.answer && Array.isArray(r.answer.tools) ? r.answer.tools : [];
  reply(id, { tools });
}

async function callTool(id, params) {
  const name = typeof params?.name === "string" ? params.name : "";
  if (!name) {
    reply(id, toolError("The call named no tool."));
    return;
  }
  const args = params && typeof params.arguments === "object" && params.arguments !== null ? params.arguments : {};
  const controller = new AbortController();
  inflight.set(id, controller);
  const progressToken = params?._meta?.progressToken;
  let progress = 0;
  const timer =
    progressToken === undefined
      ? null
      : setInterval(() => {
          progress += 1;
          write({ jsonrpc: "2.0", method: "notifications/progress", params: { progressToken, progress, message: "Waiting for the party" } });
        }, PROGRESS_EVERY_MS);
  try {
    const r = await askTownHall({ op: "call", name, arguments: args }, controller.signal);
    if (!inflight.has(id)) return;
    const answer = r.answer;
    if (answer && Array.isArray(answer.content)) reply(id, answer);
    else reply(id, toolError(r.error ?? "The Town Hall sent no result."));
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
        serverInfo: { name: "town", version: "1.0.0" },
        instructions: "The Aurelhaven town tools: delegate parts of your task to your party, check on them, and collect their results.",
      });
      return;
    }
    case "ping":
      if (isRequest) reply(id, {});
      return;
    case "tools/list":
      void listTools(id);
      return;
    case "tools/call":
      void callTool(id, params);
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
