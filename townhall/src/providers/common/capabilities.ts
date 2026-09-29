import { z } from "zod";
import type { ToolType } from "../../protocol/objects.js";

/** The "tools" section of economy.json: each add-on lists what it grants per provider. */
export type EconomyTools = Record<string, Record<string, unknown>>;

const ClaudeGrant = z.looseObject({
  tools: z.array(z.string()).optional(),
  charter: z.boolean().optional(),
  mcp: z.boolean().optional(),
});

const CodexGrant = z.looseObject({
  sandbox: z.enum(["read-only", "workspace-write"]).optional(),
  commands: z.boolean().optional(),
  web_search: z.string().optional(),
  charter: z.boolean().optional(),
  mcp: z.boolean().optional(),
});

const PiGrant = z.looseObject({
  tools: z.array(z.string()).optional(),
  charter: z.boolean().optional(),
  mcp: z.boolean().optional(),
  available: z.boolean().optional(),
  note: z.string().optional(),
});

function grants<T extends z.ZodType>(econ: EconomyTools, tools: Iterable<ToolType>, provider: string, schema: T): Array<{ type: ToolType; grant: z.infer<T> }> {
  const out: Array<{ type: ToolType; grant: z.infer<T> }> = [];
  for (const type of tools) {
    const parsed = schema.safeParse(econ[type]?.[provider]);
    if (parsed.success) out.push({ type, grant: parsed.data });
  }
  return out;
}

function unique(values: string[]): string[] {
  return [...new Set(values)];
}

export interface ClaudePlan {
  /** Built-in tools for `--tools`. */
  tools: string[];
  /** Archive: load CLAUDE.md files. */
  charter: boolean;
  /** Waygate: pass the configured MCP servers. */
  mcp: boolean;
}

export function claudePlan(econ: EconomyTools, tools: Iterable<ToolType>): ClaudePlan {
  const list = grants(econ, tools, "claude", ClaudeGrant);
  return {
    tools: unique(list.flatMap((g) => g.grant.tools ?? [])),
    charter: list.some((g) => g.grant.charter === true),
    mcp: list.some((g) => g.grant.mcp === true),
  };
}

export interface CodexPlan {
  sandbox: "read-only" | "workspace-write";
  /** Forge: commands beyond Codex's known-safe reads may run (each one still asks). */
  commands: boolean;
  /** Rookery: web_search mode ("live"), or "disabled". */
  webSearch: string;
  charter: boolean;
  mcp: boolean;
}

export function codexPlan(econ: EconomyTools, tools: Iterable<ToolType>): CodexPlan {
  const list = grants(econ, tools, "codex", CodexGrant);
  const sandboxes = list.map((g) => g.grant.sandbox).filter((s): s is "read-only" | "workspace-write" => !!s);
  return {
    sandbox: sandboxes.includes("workspace-write") ? "workspace-write" : "read-only",
    commands: list.some((g) => g.grant.commands === true),
    webSearch: list.find((g) => g.grant.web_search)?.grant.web_search ?? "disabled",
    charter: list.some((g) => g.grant.charter === true),
    mcp: list.some((g) => g.grant.mcp === true),
  };
}

export interface PiPlan {
  /** Built-in tools for `--tools`. */
  tools: string[];
  charter: boolean;
  mcp: boolean;
  /** Add-ons the agent has that give pi nothing, with the reason from economy.json. */
  unavailable: Array<{ type: ToolType; note: string }>;
}

export function piPlan(econ: EconomyTools, tools: Iterable<ToolType>): PiPlan {
  const list = grants(econ, tools, "pi", PiGrant);
  return {
    tools: unique(list.flatMap((g) => g.grant.tools ?? [])),
    charter: list.some((g) => g.grant.charter === true),
    mcp: list.some((g) => g.grant.mcp === true),
    unavailable: list
      .filter((g) => g.grant.available === false)
      .map((g) => ({ type: g.type, note: g.grant.note ?? "not available for pi" })),
  };
}
