import { createHash } from "node:crypto";
import type { Ctx } from "../core/context.js";
import { canonicalJson } from "../core/approvals.js";
import {
  commands,
  isCommandType,
  type CommandPayload,
  type CommandResult,
  type CommandType,
} from "../protocol/commands.js";
import { CommandEnvelope, formatIssues, replyError, replyOk, type ReplyEnvelope } from "../protocol/envelope.js";
import { isTownError, type ErrorBody } from "../protocol/errors.js";
import { IDEMPOTENCY_TTL_MS } from "../protocol/version.js";

export interface RequestMeta {
  connectionId: string;
}

export type Handler<T extends CommandType> = (
  payload: CommandPayload<T>,
  meta: RequestMeta,
) => CommandResult<T> | Promise<CommandResult<T>>;

export type Handlers = { [K in Exclude<CommandType, "hello">]: Handler<K> };

interface CacheEntry {
  expires: number;
  fingerprint: string;
  reply: ReplyEnvelope | Promise<ReplyEnvelope>;
}

function isPromise<T>(v: unknown): v is Promise<T> {
  return !!v && typeof (v as { then?: unknown }).then === "function";
}

export class Router {
  private readonly cache = new Map<string, CacheEntry>();

  constructor(
    private readonly ctx: Ctx,
    private readonly handlers: Handlers,
  ) {}

  /**
   * Handles one command frame. Synchronous handlers reply synchronously, so a `get_state`
   * snapshot can never be overtaken by events published after it was taken.
   */
  handle(raw: unknown, meta: RequestMeta): ReplyEnvelope | Promise<ReplyEnvelope> {
    const env = CommandEnvelope.safeParse(raw);
    if (!env.success) {
      const r = (raw && typeof raw === "object" ? raw : {}) as { type?: unknown; request_id?: unknown };
      const type = typeof r.type === "string" ? r.type.slice(0, 64) : "unknown";
      const rid = typeof r.request_id === "string" ? r.request_id.slice(0, 128) : "";
      return replyError(type, rid, { code: "BAD_REQUEST", message: `bad envelope: ${formatIssues(env.error)}`, retryable: false });
    }
    const { type, request_id: requestId, payload } = env.data;
    if (!isCommandType(type)) {
      return replyError(type, requestId, { code: "BAD_REQUEST", message: `unknown command ${type}`, retryable: false });
    }
    if (type === "hello") {
      return replyError(type, requestId, { code: "INVALID_STATE", message: "already authenticated", retryable: false });
    }
    if (!commands[type].mutating) return this.execute(type, requestId, payload, meta);

    this.sweep();
    const key = `${type}:${requestId}`;
    const fingerprint = createHash("sha256").update(canonicalJson(payload ?? {})).digest("hex");
    const now = this.ctx.clock.now();
    const cached = this.cache.get(key);
    if (cached && cached.expires > now) {
      if (cached.fingerprint !== fingerprint) {
        return replyError(type, requestId, {
          code: "CONFLICT",
          message: "request_id was already used with a different payload",
          retryable: false,
        });
      }
      return cached.reply;
    }
    const reply = this.execute(type, requestId, payload, meta);
    const entry: CacheEntry = { expires: now + IDEMPOTENCY_TTL_MS, fingerprint, reply };
    this.cache.set(key, entry);
    const settle = (r: ReplyEnvelope) => {
      // Only successful replies are remembered; a failed command did no work and may be retried.
      if (r.ok) entry.reply = r;
      else if (this.cache.get(key) === entry) this.cache.delete(key);
      return r;
    };
    return isPromise<ReplyEnvelope>(reply) ? reply.then(settle) : settle(reply);
  }

  private execute(type: Exclude<CommandType, "hello">, requestId: string, payload: unknown, meta: RequestMeta): ReplyEnvelope | Promise<ReplyEnvelope> {
    const def = commands[type];
    const parsed = def.payload.safeParse(payload ?? {});
    if (!parsed.success) {
      return replyError(type, requestId, { code: "BAD_REQUEST", message: formatIssues(parsed.error), retryable: false });
    }
    const handler = this.handlers[type] as Handler<typeof type>;
    let result: unknown;
    try {
      result = this.ctx.bus.withCausation(requestId, () => handler(parsed.data as never, meta));
    } catch (err) {
      return replyError(type, requestId, this.errorBody(type, err));
    }
    if (isPromise<unknown>(result)) {
      return result.then(
        (value) => this.finish(type, requestId, value),
        (err: unknown) => replyError(type, requestId, this.errorBody(type, err)),
      );
    }
    return this.finish(type, requestId, result);
  }

  private finish(type: CommandType, requestId: string, value: unknown): ReplyEnvelope {
    const check = commands[type].result.safeParse(value);
    if (!check.success) {
      this.ctx.log.error({ type, issues: formatIssues(check.error) }, "handler result does not match the protocol");
      return replyError(type, requestId, { code: "INTERNAL", message: "the Town Hall produced an invalid reply", retryable: false });
    }
    return replyOk(type, requestId, check.data);
  }

  private errorBody(type: string, err: unknown): ErrorBody {
    if (isTownError(err)) return err.toBody();
    this.ctx.log.error({ type, err: err instanceof Error ? err.stack : String(err) }, "command failed");
    return { code: "INTERNAL", message: "internal error", retryable: true };
  }

  private sweep(): void {
    if (this.cache.size < 256) return;
    const now = this.ctx.clock.now();
    for (const [k, v] of this.cache) if (v.expires <= now) this.cache.delete(k);
  }
}
