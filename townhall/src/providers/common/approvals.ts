import path from "node:path";
import type { ApprovalCategory, Risk } from "../../protocol/objects.js";
import type { ApprovalRequest } from "../types.js";

type Input = Record<string, unknown>;

function asInput(input: unknown): Input {
  return input && typeof input === "object" && !Array.isArray(input) ? (input as Input) : {};
}

function str(v: unknown): string | null {
  return typeof v === "string" && v.trim() !== "" ? v : null;
}

/** Claude Code tool names by approval category. MCP tools are "mcp__<server>__<tool>". */
export function claudeCategory(tool: string): ApprovalCategory {
  if (tool.startsWith("mcp__")) return "mcp";
  switch (tool) {
    case "Read":
    case "Glob":
    case "Grep":
    case "LS":
    case "NotebookRead":
      return "read";
    case "Edit":
    case "MultiEdit":
    case "Write":
    case "NotebookEdit":
    case "ExitPlanMode":
      return "write";
    case "WebSearch":
    case "WebFetch":
      return "network";
    default:
      // Bash, PowerShell and anything unknown: treat as a command, which most modes ask about.
      return "command";
  }
}

/** pi built-in tool names by approval category. */
export function piCategory(tool: string): ApprovalCategory {
  if (tool.startsWith("mcp__")) return "mcp";
  switch (tool) {
    case "read":
    case "grep":
    case "find":
    case "ls":
      return "read";
    case "edit":
    case "write":
      return "write";
    default:
      return "command";
  }
}

/** Commands that can destroy work or reach far are high risk: they are only ever allowed once. */
const HIGH_RISK_COMMAND = [
  /\brm\s+-[a-z]*r[a-z]*f|\brm\s+-[a-z]*f[a-z]*r/i,
  /\bremove-item\b[^|;&]*-recurse/i,
  /\bgit\s+(push|reset\s+--hard|clean\b|checkout\s+--|stash\b)/i,
  /\b(curl|wget|iwr|invoke-webrequest)\b[^|;&]*\|\s*(sh|bash|pwsh|powershell|iex)\b/i,
  /\bformat\b\s+[a-z]:/i,
  /\bsudo\b/i,
];

export function commandRisk(command: string): Risk | undefined {
  return HIGH_RISK_COMMAND.some((re) => re.test(command)) ? "high" : undefined;
}

/** Shows paths inside the work folder relative to it, with forward slashes. */
export function displayTarget(target: string, cwd: string): string {
  const abs = path.resolve(cwd, target);
  const rel = path.relative(cwd, abs);
  if (rel && !rel.startsWith("..") && !path.isAbsolute(rel)) return rel.replace(/\\/g, "/");
  return abs.replace(/\\/g, "/");
}

/** One line, at most `max` characters. */
export function clip(text: string, max = 160): string {
  const oneLine = text.replace(/\s+/g, " ").trim();
  return oneLine.length > max ? `${oneLine.slice(0, max - 3)}...` : oneLine;
}

/** A one-line description of a tool call for approval cards and activity. */
export function describeToolCall(tool: string, rawInput: unknown, cwd: string): string {
  const input = asInput(rawInput);
  const file = str(input.file_path) ?? str(input.path) ?? str(input.notebook_path);
  const command = str(input.command);
  const lower = tool.toLowerCase();
  if (command) return `Run: ${clip(command)}`;
  if (lower === "webfetch" || str(input.url)) return `Fetch: ${clip(str(input.url) ?? tool)}`;
  if (lower === "websearch" || lower === "web_search") return `Search the web: ${clip(str(input.query) ?? "")}`;
  if (lower === "glob" || lower === "find") return `Find files: ${clip(str(input.pattern) ?? "*")}${file ? ` in ${displayTarget(file, cwd)}` : ""}`;
  if (lower === "grep") return `Search files for: ${clip(str(input.pattern) ?? "")}${file ? ` in ${displayTarget(file, cwd)}` : ""}`;
  if (lower === "exitplanmode") return `Approve the plan: ${clip(str(input.plan) ?? "")}`;
  if (tool.startsWith("mcp__")) {
    const [, server, name] = tool.split("__");
    return `Use ${name ?? tool} on ${server ?? "an MCP server"}`;
  }
  const verbs: Record<string, string> = {
    read: "Read",
    ls: "List",
    edit: "Edit",
    multiedit: "Edit",
    write: "Write",
    notebookedit: "Edit notebook",
  };
  const verb = verbs[lower] ?? tool;
  return file ? `${verb}: ${displayTarget(file, cwd)}` : verb;
}

/** Builds the host approval request for one harness tool call. */
export function approvalFor(tool: string, category: ApprovalCategory, input: unknown, cwd: string, reason?: string | null): ApprovalRequest {
  const command = str(asInput(input).command);
  const risk = command ? commandRisk(command) : undefined;
  return {
    tool,
    category,
    input,
    summary: describeToolCall(tool, input, cwd),
    ...(risk ? { risk } : {}),
    ...(reason ? { reason } : {}),
  };
}

/** File paths a write-type tool call changes, relative to the work folder. */
export function writtenPaths(rawInput: unknown, cwd: string): string[] {
  const input = asInput(rawInput);
  const file = str(input.file_path) ?? str(input.path) ?? str(input.notebook_path);
  return file ? [displayTarget(file, cwd)] : [];
}
