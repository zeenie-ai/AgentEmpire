export interface TimerHandle {
  readonly id: number;
}

/**
 * The longest delay Node's setTimeout honours (2^31 - 1 ms, about 24.8 days). A longer one fires
 * after 1 ms with a TimeoutOverflowWarning, so the clocks wait in steps no longer than this. The
 * end of a monthly Mana period is often further away than that.
 */
export const MAX_TIMER_MS = 2_147_483_647;

export interface Clock {
  /** Milliseconds since the Unix epoch. */
  now(): number;
  iso(): string;
  setTimeout(fn: () => void, ms: number): TimerHandle;
  clearTimeout(handle: TimerHandle | null | undefined): void;
  /** Resolves after `ms`, or rejects with an AbortError when `signal` aborts. */
  sleep(ms: number, signal?: AbortSignal): Promise<void>;
}

function abortError(): Error {
  const err = new Error("aborted");
  err.name = "AbortError";
  return err;
}

function sleepOn(clock: Clock, ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(abortError());
      return;
    }
    const onAbort = () => {
      clock.clearTimeout(handle);
      reject(abortError());
    };
    const handle = clock.setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

export class SystemClock implements Clock {
  private nextId = 1;
  private readonly timers = new Map<number, NodeJS.Timeout>();

  now(): number {
    return Date.now();
  }

  iso(): string {
    return new Date(this.now()).toISOString();
  }

  setTimeout(fn: () => void, ms: number): TimerHandle {
    const id = this.nextId++;
    this.arm(id, fn, Math.max(0, ms));
    return { id };
  }

  /** Waits `remaining` ms under timer `id`, at most MAX_TIMER_MS at a time, then calls `fn`. */
  private arm(id: number, fn: () => void, remaining: number): void {
    const step = Math.min(remaining, MAX_TIMER_MS);
    const t = setTimeout(() => {
      if (remaining > step) {
        this.arm(id, fn, remaining - step);
        return;
      }
      this.timers.delete(id);
      fn();
    }, step);
    t.unref();
    this.timers.set(id, t);
  }

  clearTimeout(handle: TimerHandle | null | undefined): void {
    if (!handle) return;
    const t = this.timers.get(handle.id);
    if (t) {
      clearTimeout(t);
      this.timers.delete(handle.id);
    }
  }

  sleep(ms: number, signal?: AbortSignal): Promise<void> {
    return sleepOn(this, ms, signal);
  }
}

interface PendingTimer {
  id: number;
  due: number;
  fn: () => void;
  real: NodeJS.Timeout;
}

/**
 * Real time plus an adjustable offset. Timers fire on their own in real time, and
 * `advance(ms)` jumps forward, firing every timer that has become due, in order.
 */
export class TestClock implements Clock {
  private offset = 0;
  private nextId = 1;
  private readonly pending = new Map<number, PendingTimer>();

  constructor(private readonly base: () => number = Date.now) {}

  now(): number {
    return this.base() + this.offset;
  }

  iso(): string {
    return new Date(this.now()).toISOString();
  }

  setTimeout(fn: () => void, ms: number): TimerHandle {
    const id = this.nextId++;
    const due = this.now() + Math.max(0, ms);
    this.pending.set(id, { id, due, fn, real: this.realTimer(id, Math.max(0, ms)) });
    return { id };
  }

  /** The real timer behind timer `id`: fires it after `ms`, waiting at most MAX_TIMER_MS at a time. */
  private realTimer(id: number, ms: number): NodeJS.Timeout {
    const step = Math.min(ms, MAX_TIMER_MS);
    const real = setTimeout(() => {
      const t = this.pending.get(id);
      if (t && ms > step) {
        t.real = this.realTimer(id, ms - step);
        return;
      }
      this.fire(id);
    }, step);
    real.unref();
    return real;
  }

  clearTimeout(handle: TimerHandle | null | undefined): void {
    if (!handle) return;
    const t = this.pending.get(handle.id);
    if (t) {
      clearTimeout(t.real);
      this.pending.delete(handle.id);
    }
  }

  sleep(ms: number, signal?: AbortSignal): Promise<void> {
    return sleepOn(this, ms, signal);
  }

  /** Moves time forward and synchronously fires every timer that is now due. */
  advance(ms: number): void {
    this.offset += ms;
    for (;;) {
      const now = this.now();
      let next: PendingTimer | null = null;
      for (const t of this.pending.values()) {
        if (t.due <= now && (!next || t.due < next.due || (t.due === next.due && t.id < next.id))) next = t;
      }
      if (!next) break;
      this.fire(next.id);
    }
  }

  pendingCount(): number {
    return this.pending.size;
  }

  private fire(id: number): void {
    const t = this.pending.get(id);
    if (!t) return;
    clearTimeout(t.real);
    this.pending.delete(id);
    t.fn();
  }
}
