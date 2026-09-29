import { isPlainObject } from "../common/support.js";

export type RpcId = number | string;

export class RpcError extends Error {
  constructor(
    readonly code: number,
    message: string,
    readonly data?: unknown,
  ) {
    super(message);
    this.name = "RpcError";
  }
}

export interface RpcHandlers {
  /** A notification from the server (no id). */
  onNotification(method: string, params: unknown): void;
  /** A request from the server; the returned value (or thrown RpcError) is sent back. */
  onRequest(method: string, params: unknown, id: RpcId): Promise<unknown>;
}

/**
 * The app server's JSON-RPC dialect: one JSON object per line on stdio, without the
 * "jsonrpc" member (docs/spikes.md S2). Both sides send requests, so ids are matched here.
 */
export class RpcClient {
  private nextId = 1;
  private readonly waiting = new Map<RpcId, { resolve: (v: unknown) => void; reject: (e: Error) => void; method: string }>();
  private closed = false;

  constructor(
    private readonly write: (message: unknown) => boolean,
    private readonly handlers: RpcHandlers,
  ) {}

  request<T = unknown>(method: string, params: unknown, timeoutMs = 0): Promise<T> {
    if (this.closed) return Promise.reject(new RpcError(-32000, `the app server is gone (${method})`));
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      let timer: NodeJS.Timeout | null = null;
      this.waiting.set(id, {
        resolve: (v) => {
          if (timer) clearTimeout(timer);
          resolve(v as T);
        },
        reject: (e) => {
          if (timer) clearTimeout(timer);
          reject(e);
        },
        method,
      });
      if (timeoutMs > 0) {
        timer = setTimeout(() => {
          this.waiting.delete(id);
          reject(new RpcError(-32001, `${method} timed out after ${Math.round(timeoutMs / 1000)} s`));
        }, timeoutMs);
      }
      if (!this.write({ id, method, params })) {
        this.waiting.delete(id);
        if (timer) clearTimeout(timer);
        reject(new RpcError(-32000, `could not send ${method}: the app server's input is closed`));
      }
    });
  }

  notify(method: string, params?: unknown): void {
    this.write(params === undefined ? { method } : { method, params });
  }

  /** Feeds one decoded message from the server. */
  handle(message: unknown): void {
    if (!isPlainObject(message)) return;
    const { id, method } = message;
    const hasId = typeof id === "number" || typeof id === "string";
    if (typeof method === "string") {
      if (!hasId) {
        this.handlers.onNotification(method, message.params);
        return;
      }
      this.handlers.onRequest(method, message.params, id).then(
        (result) => this.write({ id, result: result ?? {} }),
        (err: unknown) => {
          const e = err instanceof RpcError ? err : new RpcError(-32603, err instanceof Error ? err.message : String(err));
          this.write({ id, error: { code: e.code, message: e.message } });
        },
      );
      return;
    }
    if (!hasId) return;
    const entry = this.waiting.get(id);
    if (!entry) return;
    this.waiting.delete(id);
    if (isPlainObject(message.error)) {
      const err = message.error;
      entry.reject(new RpcError(typeof err.code === "number" ? err.code : -32603, typeof err.message === "string" ? err.message : `${entry.method} failed`, err.data));
    } else {
      entry.resolve(message.result);
    }
  }

  /** Fails every outstanding request (the process exited). */
  close(reason: string): void {
    this.closed = true;
    for (const [id, entry] of this.waiting) {
      this.waiting.delete(id);
      entry.reject(new RpcError(-32000, `${entry.method}: ${reason}`));
    }
  }
}
