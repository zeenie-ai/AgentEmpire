import type { WaygateConfig } from "../../protocol/commands.js";

/** Server names the adapters use themselves; a Waygate may not take them. */
export const RESERVED_SERVER_NAMES = new Set(["aurelhaven"]);

/**
 * Environment references for a harness config. Waygate secrets live only in the Town Hall's
 * environment; every harness here expands "${NAME}" itself, so no secret value is ever written
 * into a config, a command line or a log.
 */
function envRefs(names: string[] | undefined): Record<string, string> {
  return Object.fromEntries((names ?? []).map((n) => [n, `\${${n}}`]));
}

function headerRefs(refs: Record<string, string> | undefined): Record<string, string> {
  return Object.fromEntries(Object.entries(refs ?? {}).map(([header, variable]) => [header, `\${${variable}}`]));
}

/**
 * A Waygate's MCP server name as the harnesses use it: Claude Code puts it in tool names
 * (mcp__<server>__<tool>) with anything outside [A-Za-z0-9_-] replaced, and Codex cannot
 * carry dots in a dotted `-c` path. All three harnesses get the same name.
 */
export function mcpServerName(name: string): string {
  return name.replace(/[^A-Za-z0-9_-]/g, "_");
}

/** Waygates a harness can use, minus reserved names and incomplete configs; the rest are reported. */
export function usableWaygates(waygates: WaygateConfig[]): { usable: WaygateConfig[]; skipped: Array<{ name: string; reason: string }> } {
  const usable: WaygateConfig[] = [];
  const skipped: Array<{ name: string; reason: string }> = [];
  const seen = new Set<string>();
  for (const w of waygates) {
    const name = mcpServerName(w.server_name).toLowerCase();
    if (RESERVED_SERVER_NAMES.has(name)) skipped.push({ name: w.server_name, reason: "the name is reserved" });
    else if (seen.has(name)) skipped.push({ name: w.server_name, reason: "another Waygate has the same name" });
    else if (w.transport === "stdio" && !w.command) skipped.push({ name: w.server_name, reason: "a stdio Waygate needs a command" });
    else if (w.transport === "http" && !w.url) skipped.push({ name: w.server_name, reason: "an http Waygate needs a url" });
    else {
      seen.add(name);
      usable.push(w);
    }
  }
  return { usable, skipped };
}

/** One Claude Code `--mcp-config` server entry. */
export function claudeMcpServer(w: WaygateConfig): Record<string, unknown> {
  if (w.transport === "http") {
    return { type: "http", url: w.url, ...(w.header_refs ? { headers: headerRefs(w.header_refs) } : {}) };
  }
  return { type: "stdio", command: w.command, args: w.args ?? [], ...(w.env_refs?.length ? { env: envRefs(w.env_refs) } : {}) };
}

function tomlString(s: string): string {
  // A JSON string is a valid TOML basic string (same escapes, including \uXXXX).
  return JSON.stringify(s);
}

function tomlArray(items: string[]): string {
  return `[${items.map(tomlString).join(", ")}]`;
}

function tomlTable(entries: Record<string, string>): string {
  return `{ ${Object.entries(entries)
    .map(([k, v]) => `${tomlString(k)} = ${tomlString(v)}`)
    .join(", ")} }`;
}

/** The mcp_servers key Codex uses for a Waygate (dotted `-c` paths cannot carry dots in a name). */
export function codexServerKey(name: string): string {
  return mcpServerName(name);
}

/**
 * `-c` overrides that add one Waygate to Codex. Secrets are named, never copied: `env_vars`
 * forwards variables from the Town Hall's environment and `env_http_headers` fills headers
 * from it. Every tool call asks first (default_tools_approval_mode = "prompt").
 */
export function codexMcpOverrides(w: WaygateConfig): string[] {
  const p = `mcp_servers.${codexServerKey(w.server_name)}`;
  const out: string[] = [];
  if (w.transport === "http") {
    out.push(`${p}.url=${tomlString(w.url ?? "")}`);
    if (w.header_refs && Object.keys(w.header_refs).length > 0) out.push(`${p}.env_http_headers=${tomlTable(w.header_refs)}`);
  } else {
    out.push(`${p}.command=${tomlString(w.command ?? "")}`);
    out.push(`${p}.args=${tomlArray(w.args ?? [])}`);
    if (w.env_refs?.length) out.push(`${p}.env_vars=${tomlArray(w.env_refs)}`);
  }
  if (w.allowed_tools?.length) out.push(`${p}.enabled_tools=${tomlArray(w.allowed_tools)}`);
  out.push(`${p}.default_tools_approval_mode="prompt"`);
  return out;
}

/** The mcp.json-shaped entry pi's registerMcpServer takes. */
export function piMcpServer(w: WaygateConfig): { name: string; config: Record<string, unknown> } {
  const name = mcpServerName(w.server_name);
  if (w.transport === "http") {
    return { name, config: { url: w.url, ...(w.header_refs ? { headers: headerRefs(w.header_refs) } : {}), exposure: "direct" } };
  }
  return {
    name,
    config: { command: w.command, args: w.args ?? [], ...(w.env_refs?.length ? { env: envRefs(w.env_refs) } : {}), exposure: "direct" },
  };
}
