import { LoopbackListener } from "../common/loopback.js";

/** What Claude Code sends its permission prompt tool. */
export interface PermissionPrompt {
  tool_name: string;
  input: Record<string, unknown>;
  tool_use_id?: string;
}

/** What the permission prompt tool answers (serialised as the tool's text result). */
export type PermissionResult =
  | { behavior: "allow"; updatedInput: Record<string, unknown> }
  | { behavior: "deny"; message: string; interrupt?: boolean };

function parsePrompt(raw: unknown): PermissionPrompt {
  const body = (raw && typeof raw === "object" ? raw : {}) as Partial<PermissionPrompt>;
  if (typeof body.tool_name !== "string" || !body.tool_name) throw new Error("no tool");
  const input = body.input && typeof body.input === "object" && !Array.isArray(body.input) ? body.input : {};
  return { tool_name: body.tool_name, input, ...(typeof body.tool_use_id === "string" ? { tool_use_id: body.tool_use_id } : {}) };
}

/**
 * The per-run listener that the approval MCP server (approval-mcp.mjs) forwards Claude Code's
 * permission prompts to: POST /approve with the run's bearer secret. A request waits, without a
 * timeout, until the Town Hall answers; a failure to decide is answered with a deny.
 */
export class ApprovalBridge {
  private constructor(private readonly listener: LoopbackListener) {}

  get url(): string {
    return this.listener.url;
  }

  get token(): string {
    return this.listener.token;
  }

  static async open(handler: (prompt: PermissionPrompt) => Promise<PermissionResult>): Promise<ApprovalBridge> {
    const listener = await LoopbackListener.open<PermissionPrompt>("/approve", {
      parse: parsePrompt,
      handle: handler,
      fallback: (): PermissionResult => ({ behavior: "deny", message: "The Town Hall could not decide on this request." }),
    });
    return new ApprovalBridge(listener);
  }

  close(): void {
    this.listener.close();
  }
}
