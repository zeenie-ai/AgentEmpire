import { randomBytes, timingSafeEqual } from "node:crypto";
import http from "node:http";
import type { AddressInfo } from "node:net";

const MAX_BODY_BYTES = 4 * 1024 * 1024;

function sameSecret(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

/** One POST route of a LoopbackListener. */
export interface LoopbackRoute<T> {
  /** Checks and converts the JSON body; throwing answers 400. */
  parse(body: unknown): T;
  /** The answer, sent as JSON. It may take as long as it needs (an approval can wait for hours). */
  handle(input: T): Promise<unknown>;
  /** The answer when handle() fails. */
  fallback(err: unknown): unknown;
}

/**
 * A per-run HTTP listener on 127.0.0.1 for a helper a harness starts (the approval and town MCP
 * servers). Requests carry a random bearer secret that only the run's own MCP config holds, never
 * a command line or the harness's environment, so the agent's shell cannot see it. A request
 * waits, without a time limit, until the Town Hall answers.
 */
export class LoopbackListener {
  private constructor(
    private readonly server: http.Server,
    readonly url: string,
    readonly token: string,
  ) {}

  static open<T>(routePath: string, route: LoopbackRoute<T>): Promise<LoopbackListener> {
    const token = randomBytes(32).toString("hex");
    const server = http.createServer((req, res) => {
      const auth = req.headers.authorization ?? "";
      if (req.method !== "POST" || req.url !== routePath || !sameSecret(auth, `Bearer ${token}`)) {
        res.writeHead(req.method === "POST" && req.url === routePath ? 401 : 404).end();
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
        let input: T;
        try {
          input = route.parse(JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown);
        } catch {
          res.writeHead(400).end();
          return;
        }
        const send = (answer: unknown) => {
          if (res.writableEnded || res.destroyed) return;
          res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(answer));
        };
        route.handle(input).then(send, (err: unknown) => send(route.fallback(err)));
      });
    });
    // Answers can wait for hours: no request or socket timeouts on this listener.
    server.requestTimeout = 0;
    server.headersTimeout = 60_000;
    server.keepAliveTimeout = 5_000;
    server.timeout = 0;
    return new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", () => {
        server.off("error", reject);
        const port = (server.address() as AddressInfo).port;
        resolve(new LoopbackListener(server, `http://127.0.0.1:${port}${routePath}`, token));
      });
    });
  }

  close(): void {
    this.server.close();
    this.server.closeAllConnections();
  }
}
