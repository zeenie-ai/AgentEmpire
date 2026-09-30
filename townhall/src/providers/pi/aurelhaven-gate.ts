// Aurelhaven gate: a pi extension the Town Hall loads with `pi --mode rpc -e <this file>`.
// pi runs it in its own process (through jiti), so it imports nothing from the Town Hall.
//
// - Every tool call waits for the Town Hall: the `tool_call` hook opens a `ctx.ui.input`
//   dialog titled "aurelhaven:approval" whose placeholder carries the call as JSON. In RPC
//   mode that dialog reaches the Town Hall as an `extension_ui_request`; it answers with
//   {"decision":"allow"|"deny","message"?,"updatedInput"?} and a denial blocks the call with
//   the player's message.
// - Waygates arrive as JSON in AURELHAVEN_PI_GATE and are registered with
//   pi.registerMcpServer when this pi version has it.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const APPROVAL_TITLE = "aurelhaven:approval";

interface GateConfig {
  waygates?: Array<{ name: string; config: Record<string, unknown> }>;
}

interface Decision {
  decision?: string;
  message?: string;
  updatedInput?: unknown;
}

function readConfig(): GateConfig {
  try {
    const parsed = JSON.parse(process.env.AURELHAVEN_PI_GATE ?? "{}") as unknown;
    return parsed && typeof parsed === "object" ? (parsed as GateConfig) : {};
  } catch {
    return {};
  }
}

export default function aurelhavenGate(pi: ExtensionAPI): void {
  const skipped: string[] = [];
  const register = (pi as unknown as { registerMcpServer?: (name: string, config: Record<string, unknown>) => void }).registerMcpServer;
  for (const waygate of readConfig().waygates ?? []) {
    if (typeof register !== "function") {
      skipped.push(waygate.name);
      continue;
    }
    try {
      register.call(pi, waygate.name, waygate.config);
    } catch (err) {
      skipped.push(`${waygate.name} (${err instanceof Error ? err.message : String(err)})`);
    }
  }
  if (skipped.length > 0) {
    pi.on("session_start", async (_event, ctx) => {
      ctx.ui.notify(`This pi version cannot connect MCP servers, so these Waygates are skipped: ${skipped.join(", ")}`, "warning");
    });
  }

  pi.on("tool_call", async (event, ctx) => {
    if (!ctx.hasUI) return { block: true, reason: "The Town Hall approval channel is not available." };
    const payload = JSON.stringify({ v: 1, tool: event.toolName, toolCallId: event.toolCallId, input: event.input });
    const answer = await ctx.ui.input(APPROVAL_TITLE, payload, ctx.signal ? { signal: ctx.signal } : undefined);
    if (answer === undefined) return { block: true, reason: "The approval request was withdrawn." };
    let decision: Decision;
    try {
      decision = JSON.parse(answer) as Decision;
    } catch {
      return { block: true, reason: "The Town Hall's answer could not be read." };
    }
    if (decision.decision !== "allow") return { block: true, reason: decision.message || "The player denied this action." };
    const updated = decision.updatedInput;
    if (updated && typeof updated === "object" && !Array.isArray(updated)) {
      // The player edited the call: replace the input in place, as the tool_call contract asks.
      const input = event.input as Record<string, unknown>;
      for (const key of Object.keys(input)) delete input[key];
      Object.assign(input, updated);
    }
    return undefined;
  });
}
