import { z } from "zod";
import { isTownError } from "../../protocol/errors.js";
import { TaskSize } from "../../protocol/objects.js";
import type { PartyStatus, RunHost, RunParty, SubtaskInfo } from "../types.js";
import { LoopbackListener } from "./loopback.js";

/**
 * The built-in town tools a party lead delegates with (the plan's `town_*` tools), offered by
 * town-mcp.mjs as the MCP server "town": delegate, check_status and collect_results. They work
 * on the lead's own task only, through the RunHost: every sub-task lands on a member's queue
 * with a budget carved out of the lead's Mana Seal, every member asks the player before acting,
 * and sub-tasks pay only through the party task.
 */
export const TOWN_SERVER = "town";
export const TOWN_TOOLS = {
  delegate: "delegate",
  status: "check_status",
  collect: "collect_results",
} as const;
/** The longest a single collect_results waits; the Town Hall also caps it (parties.await_timeout_max_s). */
export const TOWN_WAIT_MAX_S = 600;

/** The tool names as Claude Code shows them to the model (mcp__<server>__<tool>). */
export function claudeTownToolNames(): { delegate: string; status: string; collect: string } {
  const name = (t: string) => `mcp__${TOWN_SERVER}__${t}`;
  return { delegate: name(TOWN_TOOLS.delegate), status: name(TOWN_TOOLS.status), collect: name(TOWN_TOOLS.collect) };
}

export interface McpTool {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

/** An MCP tools/call result. */
export interface McpToolResult {
  content: Array<{ type: "text"; text: string }>;
  isError?: boolean;
}

/** The three tools, with the party's members named in the schema. */
export function townTools(party: RunParty): McpTool[] {
  const names = party.members.map((m) => m.name);
  const roster = party.members.map((m) => `${m.name} (${m.role}, ${m.provider})`).join(", ");
  return [
    {
      name: TOWN_TOOLS.delegate,
      description:
        `Hands part of this task to a member of your party as a sub-task, and returns at once: the member works in their own folder while you carry on. ` +
        `Members: ${roster || "none"}. Each member asks the player before acting, as you do. The sub-task's Mana comes out of this task's Mana Seal. ` +
        `Use collect_results to wait for what they did.`,
      inputSchema: {
        type: "object",
        properties: {
          member: { type: "string", ...(names.length > 0 ? { enum: names } : {}), description: "The member who does it, by name." },
          title: { type: "string", maxLength: 200, description: "A short title for the sub-task." },
          prompt: {
            type: "string",
            maxLength: 32000,
            description: "Everything the member needs: what to do, where, and what done looks like. They cannot see your conversation or your folder.",
          },
          size: { type: "string", enum: TaskSize.options, description: "S (an errand) to XL (a campaign). Default S." },
          budget_mana: {
            type: "integer",
            minimum: 1,
            description: "Mana for the sub-task (1 Mana = $0.01). Left out: the member's usual seal for the size, at most half of what this task has left.",
          },
        },
        required: ["member", "title", "prompt"],
        additionalProperties: false,
      },
    },
    {
      name: TOWN_TOOLS.status,
      description:
        "Shows how your party's sub-tasks are doing (queued, working, waiting_for_player, paused, done, failed, cancelled), the Mana each used, and how much Mana this task's seal has left to give. Returns at once.",
      inputSchema: {
        type: "object",
        properties: { task_id: { type: "string", description: "One sub-task; left out, all of them." } },
        additionalProperties: false,
      },
    },
    {
      name: TOWN_TOOLS.collect,
      description:
        `Waits until your party's sub-tasks are finished, then returns their results: each member's summary, the files they changed and the Mana they used. ` +
        `Without task_ids it waits for every unfinished sub-task. It stops waiting after wait_seconds (default and most ${TOWN_WAIT_MAX_S}); call it again if some are still working.`,
      inputSchema: {
        type: "object",
        properties: {
          task_ids: { type: "array", items: { type: "string" }, description: "The sub-tasks to wait for; left out, every unfinished one." },
          wait_seconds: { type: "integer", minimum: 0, maximum: TOWN_WAIT_MAX_S, description: `How long to wait at most (default ${TOWN_WAIT_MAX_S}).` },
        },
        additionalProperties: false,
      },
    },
  ];
}

const DelegateArgs = z.object({
  member: z.string().trim().min(1).max(128),
  title: z.string().trim().min(1).max(200),
  prompt: z.string().trim().min(1).max(32_000),
  size: TaskSize.default("S"),
  budget_mana: z.number().int().min(1).max(1_000_000).optional(),
});
const StatusArgs = z.object({ task_id: z.string().max(128).optional() });
const CollectArgs = z.object({
  task_ids: z.array(z.string().max(128)).max(16).optional(),
  wait_seconds: z.number().min(0).max(TOWN_WAIT_MAX_S).optional(),
});

function text(value: unknown, isError = false): McpToolResult {
  return { content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value, null, 2) }], ...(isError ? { isError: true } : {}) };
}

function errorText(err: unknown): string {
  if (isTownError(err)) return err.message;
  return err instanceof Error ? err.message : String(err);
}

function issues(err: z.ZodError): string {
  return err.issues
    .slice(0, 4)
    .map((i) => `${i.path.join(".") || "arguments"}: ${i.message}`)
    .join("; ");
}

/** A sub-task as the lead reads it: only what helps, no internal ids beyond the task's own. */
function report(s: SubtaskInfo): Record<string, unknown> {
  return {
    task_id: s.taskId,
    member: s.memberName,
    title: s.title,
    status: s.status,
    ...(s.reason ? { reason: s.reason } : {}),
    spent_mana: s.spentMana,
    budget_mana: s.budgetMana,
    ...(s.summary !== null ? { summary: s.summary } : {}),
    ...(s.diffStat ? { changes: s.diffStat } : {}),
    ...(s.files ? { files: s.files } : {}),
  };
}

const FINISHED = new Set(["done", "failed", "cancelled"]);

/** Runs one town tool for the lead of `party`. Never throws: problems come back as tool errors. */
export async function callTownTool(host: RunHost, party: RunParty, name: string, args: unknown): Promise<McpToolResult> {
  const input = args && typeof args === "object" ? args : {};
  try {
    switch (name) {
      case TOWN_TOOLS.delegate: {
        const p = DelegateArgs.safeParse(input);
        if (!p.success) return text(`Could not delegate: ${issues(p.error)}`, true);
        const handle = await host.delegate({
          to: p.data.member,
          title: p.data.title,
          prompt: p.data.prompt,
          size: p.data.size,
          ...(p.data.budget_mana !== undefined ? { budgetMana: p.data.budget_mana } : {}),
        });
        const sub = host.partyStatus().subtasks.find((s) => s.taskId === handle.taskId);
        return text({
          task_id: handle.taskId,
          member: sub?.memberName ?? p.data.member,
          title: p.data.title,
          size: p.data.size,
          budget_mana: sub?.budgetMana ?? p.data.budget_mana ?? null,
          status: sub?.status ?? "queued",
          note: "The member works on it now. Carry on with your own part; collect_results waits for their result.",
        });
      }
      case TOWN_TOOLS.status: {
        const p = StatusArgs.safeParse(input);
        if (!p.success) return text(`Could not check the party: ${issues(p.error)}`, true);
        const status = host.partyStatus();
        const subtasks = p.data.task_id ? status.subtasks.filter((s) => s.taskId === p.data.task_id) : status.subtasks;
        if (p.data.task_id && subtasks.length === 0) return text(`${p.data.task_id} is not one of this task's sub-tasks.`, true);
        return text({
          seal_left_mana: status.sealLeftMana,
          members: party.members.map((m) => m.name),
          subtasks: subtasks.map(report),
          ...(status.subtasks.length === 0 ? { note: "Nothing has been delegated yet." } : {}),
        });
      }
      case TOWN_TOOLS.collect: {
        const p = CollectArgs.safeParse(input);
        if (!p.success) return text(`Could not collect results: ${issues(p.error)}`, true);
        const waitS = Math.min(p.data.wait_seconds ?? TOWN_WAIT_MAX_S, TOWN_WAIT_MAX_S);
        const ids = p.data.task_ids && p.data.task_ids.length > 0 ? p.data.task_ids : null;
        const status: PartyStatus = await host.waitSubtasks(ids, waitS * 1000);
        const subtasks = ids ? status.subtasks.filter((s) => ids.includes(s.taskId)) : status.subtasks;
        const allFinished = subtasks.every((s) => FINISHED.has(s.status));
        return text({
          all_finished: allFinished,
          seal_left_mana: status.sealLeftMana,
          subtasks: subtasks.map(report),
          note:
            subtasks.length === 0
              ? "Nothing has been delegated yet."
              : allFinished
                ? "Every sub-task has finished. Their changes are merged with yours when the player accepts the party's task."
                : "Some sub-tasks are still under way: call collect_results again, or check_status.",
        });
      }
      default:
        return text(`There is no town tool named ${name}.`, true);
    }
  } catch (err) {
    return text(`The Town Hall refused: ${errorText(err)}`, true);
  }
}

interface TownRequest {
  op: "list" | "call";
  name: string;
  arguments: unknown;
}

function parseRequest(raw: unknown): TownRequest {
  const body = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  if (body.op === "list") return { op: "list", name: "", arguments: null };
  if (body.op === "call" && typeof body.name === "string" && body.name) return { op: "call", name: body.name, arguments: body.arguments ?? {} };
  throw new Error("bad request");
}

/**
 * The per-run listener town-mcp.mjs forwards a lead's tool calls to: POST /town with
 * {"op":"list"} or {"op":"call","name","arguments"} and the run's bearer secret.
 */
export class TownToolsBridge {
  private constructor(private readonly listener: LoopbackListener) {}

  get url(): string {
    return this.listener.url;
  }

  get token(): string {
    return this.listener.token;
  }

  static async open(host: RunHost, party: RunParty): Promise<TownToolsBridge> {
    const tools = townTools(party);
    const listener = await LoopbackListener.open<TownRequest>("/town", {
      parse: parseRequest,
      handle: async (r) => (r.op === "list" ? { tools } : callTownTool(host, party, r.name, r.arguments)),
      fallback: (err) => text(`The Town Hall could not run this tool: ${errorText(err)}`, true),
    });
    return new TownToolsBridge(listener);
  }

  close(): void {
    this.listener.close();
  }
}
