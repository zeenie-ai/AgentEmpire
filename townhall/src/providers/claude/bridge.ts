import { randomBytes, timingSafeEqual } from "node:crypto";
import http from "node:http";
import type { AddressInfo } from "node:net";

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

const MAX_BODY_BYTES = 4 * 1024 * 1024;

function sameSecret(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

/**
 * A per-run HTTP listener on 127.0.0.1 that the approval MCP server (approval-mcp.mjs) forwards
 * Claude Code's permission prompts to. Requests carry a random bearer secret known only to that
 * run. A request waits, without a timeout, until the Town Hall answers.
 */
export class ApprovalBridge {
  private constructor(
    private readonly server: http.Server,
    readonly url: string,
    readonly token: string,
  ) {}

  static open(handler: (prompt: PermissionPrompt) => Promise<PermissionResult>): Promise<ApprovalBridge> {
    const token = randomBytes(32).toString("hex");
    const server = http.createServer((req, res) => {
      const auth = req.headers.authorization ?? "";
      if (req.method !== "POST" || req.url !== "/approve" || !sameSecret(auth, `Bearer ${token}`)) {
        res.writeHead(req.method === "POST" && req.url === "/approve" ? 401 : 404).end();
        req.resume();
        return;
      }
      const chunks: Buffer[] = [];
      let size = 0;
      let tooBig = false;
      req.on("data", (chunk: Buffer) => {
        size += chunk.length;
        if (size > MAX_BODY_BYTES) tooBig = true;
        else chunks.push(chunk);
      });
      req.on("end", () => {
        if (tooBig) {
          res.writeHead(413).end();
          return;
        }
        let prompt: PermissionPrompt;
        try {
          const body = JSON.parse(Buffer.concat(chunks).toString("utf8")) as Partial<PermissionPrompt>;
          if (typeof body.tool_name !== "string" || !body.tool_name) throw new Error("no tool");
          const input = body.input && typeof body.input === "object" && !Array.isArray(body.input) ? body.input : {};
          prompt = { tool_name: body.tool_name, input, ...(typeof body.tool_use_id === "string" ? { tool_use_id: body.tool_use_id } : {}) };
        } catch {
          res.writeHead(400).end();
          return;
        }
        handler(prompt).then(
          (result) => {
            if (res.writableEnded || res.destroyed) return;
            res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(result));
          },
          () => {
            if (res.writableEnded || res.destroyed) return;
            res
              .writeHead(200, { "content-type": "application/json" })
              .end(JSON.stringify({ behavior: "deny", message: "The Town Hall could not decide on this request." } satisfies PermissionResult));
          },
        );
      });
    });
    // Approvals can wait for hours: no request or socket timeouts on this listener.
    server.requestTimeout = 0;
    server.headersTimeout = 60_000;
    server.keepAliveTimeout = 5_000;
    server.timeout = 0;
    return new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", () => {
        server.off("error", reject);
        const port = (server.address() as AddressInfo).port;
        resolve(new ApprovalBridge(server, `http://127.0.0.1:${port}/approve`, token));
      });
    });
  }

  close(): void {
    this.server.close();
    this.server.closeAllConnections();
  }
}
