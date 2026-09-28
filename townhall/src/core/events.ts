import { AsyncLocalStorage } from "node:async_hooks";
import type { Db } from "../db/db.js";
import { events, type EventPayload, type EventType } from "../protocol/events.js";
import { formatIssues } from "../protocol/envelope.js";
import type { Clock } from "./clock.js";
import type { Ids } from "./ids.js";

export interface EmittedEvent {
  v: 1;
  type: EventType;
  seq: number;
  id: string;
  time: string;
  subject: string | null;
  causation_id: string | null;
  payload: unknown;
}

interface EventRow {
  seq: number;
  id: string;
  type: string;
  time: string;
  subject: string | null;
  causation_id: string | null;
  payload: string;
}

type Flusher = () => boolean;

const causation = new AsyncLocalStorage<{ id: string | null }>();

/**
 * Append-only event log plus in-process publishing. Events emitted inside a transaction
 * are persisted with it and published only after COMMIT, so clients never see an event
 * whose state change was rolled back, and `seq` has no gaps on the wire.
 */
export class EventBus {
  private pending: EmittedEvent[] = [];
  private readonly listeners = new Set<(ev: EmittedEvent) => void>();
  private readonly flushers: Flusher[] = [];
  private readonly dirtySets: DirtySet[] = [];
  private lastSeq: number;

  constructor(
    private readonly db: Db,
    private readonly ids: Ids,
    private readonly clock: Clock,
  ) {
    this.lastSeq = db.get<{ seq: number | null }>("SELECT MAX(seq) AS seq FROM event_log")?.seq ?? 0;
    db.addBeforeCommit(() => this.runFlushers());
    db.addAfterCommit(() => this.publishPending());
    db.addAfterRollback(() => {
      this.pending = [];
      for (const d of this.dirtySets) d.clear();
      this.lastSeq = this.db.get<{ seq: number | null }>("SELECT MAX(seq) AS seq FROM event_log")?.seq ?? 0;
    });
  }

  /** A dirty set that is discarded when the transaction rolls back. */
  newDirtySet(): DirtySet {
    const d = new DirtySet();
    this.dirtySets.push(d);
    return d;
  }

  /** Runs `fn` with `id` as the causation id of every event it emits (across awaits). */
  withCausation<T>(id: string | null, fn: () => T): T {
    return causation.run({ id }, fn);
  }

  causationId(): string | null {
    return causation.getStore()?.id ?? null;
  }

  /**
   * Registers a before-commit flusher (for example "emit agent_updated for dirty agents").
   * A flusher returns true when it emitted something, so the loop runs until quiet.
   */
  addFlusher(fn: Flusher): void {
    this.flushers.push(fn);
  }

  subscribe(listener: (ev: EmittedEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  currentSeq(): number {
    return this.lastSeq;
  }

  emit<T extends EventType>(type: T, payload: EventPayload<T>, subject: string | null = null): void {
    if (!this.db.inTx()) {
      this.db.tx(() => this.emit(type, payload, subject));
      return;
    }
    const parsed = events[type].safeParse(payload);
    if (!parsed.success) {
      throw new Error(`event ${type} does not match the protocol: ${formatIssues(parsed.error)}`);
    }
    const ev: Omit<EmittedEvent, "seq"> = {
      v: 1,
      type,
      id: this.ids.next("evt"),
      time: this.clock.iso(),
      subject,
      causation_id: this.causationId(),
      payload: parsed.data,
    };
    const info = this.db.run(
      "INSERT INTO event_log (id, type, time, subject, causation_id, payload) VALUES (?, ?, ?, ?, ?, ?)",
      [ev.id, ev.type, ev.time, ev.subject, ev.causation_id, JSON.stringify(ev.payload)],
    );
    const seq = Number(info.lastInsertRowid);
    this.lastSeq = seq;
    this.pending.push({ ...ev, seq });
  }

  /** Events after `afterSeq`, oldest first. */
  since(afterSeq: number, limit: number): EmittedEvent[] {
    const rows = this.db.all<EventRow>("SELECT * FROM event_log WHERE seq > ? ORDER BY seq ASC LIMIT ?", [
      afterSeq,
      limit,
    ]);
    return rows.map((r) => ({
      v: 1,
      type: r.type as EventType,
      seq: r.seq,
      id: r.id,
      time: r.time,
      subject: r.subject,
      causation_id: r.causation_id,
      payload: JSON.parse(r.payload) as unknown,
    }));
  }

  private runFlushers(): void {
    for (let round = 0; round < 10; round++) {
      let emitted = false;
      for (const f of this.flushers) emitted = f() || emitted;
      if (!emitted) return;
    }
  }

  private publishPending(): void {
    const batch = this.pending;
    this.pending = [];
    for (const ev of batch) {
      for (const l of this.listeners) {
        try {
          l(ev);
        } catch {
          // A failing listener must not break publishing for the others.
        }
      }
    }
  }
}

/** Collects ids of entities changed during a transaction, flushed once before commit. */
export class DirtySet {
  private readonly ids = new Set<string>();

  add(id: string): void {
    this.ids.add(id);
  }

  take(): string[] {
    const list = [...this.ids];
    this.ids.clear();
    return list;
  }

  clear(): void {
    this.ids.clear();
  }
}
