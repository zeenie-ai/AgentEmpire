import type { IncomingMessage } from "node:http";
import type { RawData, WebSocket } from "ws";
import type { TimerHandle } from "../core/clock.js";
import type { Ctx } from "../core/context.js";
import { commands } from "../protocol/commands.js";
import { formatIssues, replyError, replyOk, type ReplyEnvelope } from "../protocol/envelope.js";
import {
  CloseCode,
  DAEMON_VERSION,
  ENVELOPE_VERSION,
  HELLO_TIMEOUT_MS,
  PROTOCOL_MAJOR,
  PROTOCOL_MINOR,
} from "../protocol/version.js";
import { tokensEqual } from "../security/token.js";
import type { Broadcaster, EventSink } from "./broadcaster.js";
import type { Router } from "./router.js";

const HEARTBEAT_MS = 30_000;
/** "progress" and "shutdown" (1.3): get_progress / progress_updated, and the shutdown command. */
const COMMON_FEATURES = ["replay", "idempotency", "parties", "stop_and_review", "progress", "shutdown"];

/** Feature flags for hello_result; "fake_provider" only when the agents are scripted. */
export function features(providerMode: "fake" | "real"): string[] {
  return providerMode === "fake" ? ["fake_provider", ...COMMON_FEATURES] : ["real_providers", ...COMMON_FEATURES];
}

let nextConnectionId = 1;

class Connection implements EventSink {
  readonly id = `c${nextConnectionId++}`;
  authed = false;
  lagging = false;
  alive = true;
  helloTimer: TimerHandle | null = null;
  client: { name: string; version: string; platform: string } | null = null;

  constructor(readonly ws: WebSocket) {}

  sendRaw(frame: string): void {
    if (this.ws.readyState === this.ws.OPEN) this.ws.send(frame);
  }

  send(obj: unknown): void {
    this.sendRaw(JSON.stringify(obj));
  }

  bufferedAmount(): number {
    return this.ws.bufferedAmount;
  }

  close(code: number, reason: string): void {
    if (this.ws.readyState === this.ws.OPEN || this.ws.readyState === this.ws.CONNECTING) this.ws.close(code, reason);
  }
}

export class ConnectionManager {
  private readonly connections = new Set<Connection>();
  private active: Connection | null = null;
  private readonly heartbeat: NodeJS.Timeout;
  /** Set once the Town Hall is shutting down: new connections are refused. */
  private closing = false;
  private closedWaiters: Array<() => void> = [];

  constructor(
    private readonly ctx: Ctx,
    private readonly router: Router,
    private readonly broadcaster: Broadcaster,
    private readonly token: string,
  ) {
    this.heartbeat = setInterval(() => this.beat(), HEARTBEAT_MS);
    this.heartbeat.unref();
  }

  hasActiveClient(): boolean {
    return !!this.active && this.active.ws.readyState === this.active.ws.OPEN;
  }

  handle(ws: WebSocket, _req: IncomingMessage): void {
    if (this.closing) {
      ws.close(1001, "the Town Hall is shutting down");
      return;
    }
    const conn = new Connection(ws);
    this.connections.add(conn);
    this.armHelloTimer(conn);
    ws.on("pong", () => {
      conn.alive = true;
    });
    ws.on("message", (data: RawData, isBinary: boolean) => this.onMessage(conn, data, isBinary));
    ws.on("close", () => this.onClose(conn));
    ws.on("error", (err) => this.ctx.log.warn({ client: conn.id, err: String(err) }, "websocket error"));
  }

  private armHelloTimer(conn: Connection): void {
    this.ctx.clock.clearTimeout(conn.helloTimer);
    conn.helloTimer = this.ctx.clock.setTimeout(() => {
      conn.helloTimer = null;
      if (!conn.authed) conn.close(CloseCode.NO_HELLO, "no hello within 5 s");
    }, HELLO_TIMEOUT_MS);
  }

  private onMessage(conn: Connection, data: RawData, isBinary: boolean): void {
    if (isBinary) {
      conn.close(1003, "binary frames are not supported");
      return;
    }
    let msg: unknown;
    try {
      msg = JSON.parse(data.toString());
    } catch {
      if (!conn.authed) conn.close(CloseCode.NO_HELLO, "the first frame must be a hello");
      else conn.send(replyError("unknown", "", { code: "BAD_REQUEST", message: "frames must be JSON", retryable: false }));
      return;
    }
    if (!conn.authed) {
      this.onHello(conn, msg);
      return;
    }
    let reply: ReplyEnvelope | Promise<ReplyEnvelope>;
    try {
      reply = this.router.handle(msg, { connectionId: conn.id });
    } catch (err) {
      this.ctx.log.error({ err: String(err) }, "router failure");
      return;
    }
    if (reply instanceof Promise) {
      reply.then(
        (r) => conn.send(r),
        (err: unknown) => this.ctx.log.error({ err: String(err) }, "reply failed"),
      );
    } else {
      conn.send(reply);
    }
  }

  private onHello(conn: Connection, msg: unknown): void {
    const env = msg as { v?: unknown; type?: unknown; request_id?: unknown; payload?: unknown };
    const requestId = typeof env?.request_id === "string" ? env.request_id.slice(0, 128) : "";
    if (!env || env.type !== "hello" || env.v !== ENVELOPE_VERSION) {
      conn.close(CloseCode.NO_HELLO, "the first frame must be a hello");
      return;
    }
    const parsed = commands.hello.payload.safeParse(env.payload ?? {});
    if (!parsed.success) {
      const token = (env.payload as { token?: unknown } | undefined)?.token;
      if (typeof token !== "string") {
        conn.send(replyError("hello", requestId, { code: "AUTH_FAILED", message: "missing token", retryable: false }));
        conn.close(CloseCode.BAD_TOKEN, "missing token");
        return;
      }
      conn.send(replyError("hello", requestId, { code: "BAD_REQUEST", message: formatIssues(parsed.error), retryable: false }));
      conn.close(CloseCode.NO_HELLO, "invalid hello");
      return;
    }
    const hello = parsed.data;
    if (!tokensEqual(this.token, hello.token)) {
      conn.send(replyError("hello", requestId, { code: "AUTH_FAILED", message: "bad token", retryable: false }));
      conn.close(CloseCode.BAD_TOKEN, "bad token");
      return;
    }
    if (hello.protocol.major !== PROTOCOL_MAJOR) {
      conn.send(
        replyError("hello", requestId, {
          code: "BAD_REQUEST",
          message: `protocol ${hello.protocol.major}.x is not supported; the Town Hall speaks ${PROTOCOL_MAJOR}.${PROTOCOL_MINOR}`,
          retryable: false,
        }),
      );
      conn.close(CloseCode.PROTOCOL_MISMATCH, "protocol major version mismatch");
      return;
    }
    const current = this.active;
    if (current && current !== conn && current.ws.readyState === current.ws.OPEN) {
      if (!hello.take_over) {
        conn.send(replyError("hello", requestId, { code: "SESSION_BUSY", message: "another client is connected", retryable: true }));
        this.armHelloTimer(conn);
        return;
      }
      current.sendRaw(this.broadcaster.transientFrame("session_revoked", {}));
      this.broadcaster.remove(current);
      current.authed = false;
      current.close(CloseCode.REPLACED, "replaced by another client");
    }

    this.ctx.clock.clearTimeout(conn.helloTimer);
    conn.helloTimer = null;
    conn.authed = true;
    conn.client = hello.client;
    this.active = conn;
    const catchup = this.broadcaster.planCatchup(hello.last_seq);
    // Reply, replay and subscribe in one synchronous block so no live event can slip between them.
    conn.send(
      replyOk("hello", requestId, {
        protocol: { major: PROTOCOL_MAJOR, minor: PROTOCOL_MINOR },
        daemon_version: DAEMON_VERSION,
        // The installed harness versions (claude, codex, pi) from the latest provider probe.
        sdk_versions: Object.fromEntries(
          this.ctx.providers
            .cached()
            .filter((p) => p.installed && p.version)
            .map((p) => [p.id, p.version!]),
        ),
        features: features(this.ctx.config.providerMode),
        seq: this.ctx.bus.currentSeq(),
        catchup,
      }),
    );
    if (catchup === "replay") this.broadcaster.replay(conn, hello.last_seq ?? 0);
    this.broadcaster.add(conn);
    this.ctx.log.info({ client: conn.id, name: hello.client.name, platform: hello.client.platform, catchup }, "client connected");
    this.ctx.scheduler.kick();
  }

  private onClose(conn: Connection): void {
    this.ctx.clock.clearTimeout(conn.helloTimer);
    this.connections.delete(conn);
    this.broadcaster.remove(conn);
    if (this.active === conn) {
      this.active = null;
      this.ctx.scheduler.kick();
    }
    if (this.connections.size === 0) for (const w of this.closedWaiters.splice(0)) w();
  }

  private beat(): void {
    for (const conn of this.connections) {
      if (!conn.alive) {
        conn.ws.terminate();
        continue;
      }
      conn.alive = false;
      try {
        conn.ws.ping();
      } catch {
        // closed meanwhile
      }
    }
  }

  /** Sends `daemon_shutdown`, closes every connection and refuses new ones from now on. */
  closeAll(): void {
    this.closing = true;
    clearInterval(this.heartbeat);
    this.broadcaster.sendTransientToAll("daemon_shutdown", {});
    for (const conn of this.connections) conn.close(1001, "the Town Hall is shutting down");
  }

  /** Resolves once every connection has closed, or after `ms`. */
  waitClosed(ms: number): Promise<void> {
    if (this.connections.size === 0) return Promise.resolve();
    return new Promise((resolve) => {
      const timer = setTimeout(resolve, ms);
      this.closedWaiters.push(() => {
        clearTimeout(timer);
        resolve();
      });
    });
  }
}
