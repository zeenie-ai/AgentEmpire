import type { EmittedEvent, EventBus } from "../core/events.js";
import type { Ids } from "../core/ids.js";
import type { Clock } from "../core/clock.js";
import type { Logger } from "../log.js";
import type { EventPayload, EventType } from "../protocol/events.js";

/** Replays longer than this fall back to a snapshot (`get_state`). */
export const MAX_REPLAY_EVENTS = 5_000;
/** A client whose socket buffer passes this stops receiving live events... */
export const HIGH_WATER_BYTES = 8 * 1024 * 1024;
/** ...until it drains below this; the next event then shows it a seq gap, so it calls get_state. */
export const LOW_WATER_BYTES = 1 * 1024 * 1024;

export interface EventSink {
  readonly id: string;
  lagging: boolean;
  sendRaw(frame: string): void;
  bufferedAmount(): number;
}

export class Broadcaster {
  private readonly sinks = new Set<EventSink>();

  constructor(
    private readonly bus: EventBus,
    private readonly ids: Ids,
    private readonly clock: Clock,
    private readonly log: Logger,
  ) {
    bus.subscribe((ev) => this.publish(ev));
  }

  add(sink: EventSink): void {
    this.sinks.add(sink);
  }

  remove(sink: EventSink): void {
    this.sinks.delete(sink);
  }

  private publish(ev: EmittedEvent): void {
    if (this.sinks.size === 0) return;
    const frame = JSON.stringify(ev);
    for (const sink of this.sinks) {
      const buffered = sink.bufferedAmount();
      if (sink.lagging) {
        if (buffered > LOW_WATER_BYTES) continue;
        sink.lagging = false;
      } else if (buffered > HIGH_WATER_BYTES) {
        sink.lagging = true;
        this.log.warn({ client: sink.id, buffered }, "client is too slow; events paused until it catches up with a snapshot");
        continue;
      }
      try {
        sink.sendRaw(frame);
      } catch (err) {
        this.log.warn({ client: sink.id, err: String(err) }, "send failed");
      }
    }
  }

  /** "replay" when the missed events are all still available and few enough, otherwise "snapshot". */
  planCatchup(lastSeq: number | null | undefined): "replay" | "snapshot" {
    const current = this.bus.currentSeq();
    if (lastSeq === null || lastSeq === undefined) return "snapshot";
    if (lastSeq > current) return "snapshot";
    if (current - lastSeq > MAX_REPLAY_EVENTS) return "snapshot";
    return "replay";
  }

  /** Sends every event after `afterSeq`, oldest first. Synchronous, so nothing interleaves. */
  replay(sink: EventSink, afterSeq: number): number {
    let cursor = afterSeq;
    let sent = 0;
    for (;;) {
      const batch = this.bus.since(cursor, 500);
      if (batch.length === 0) break;
      for (const ev of batch) {
        sink.sendRaw(JSON.stringify(ev));
        cursor = ev.seq;
        sent++;
      }
    }
    return sent;
  }

  /**
   * Connection-level notices (`session_revoked`, `daemon_shutdown`) are not part of the town's
   * history: they are not logged and carry the current seq without advancing it.
   */
  transientFrame<T extends EventType>(type: T, payload: EventPayload<T>): string {
    return JSON.stringify({
      v: 1,
      type,
      seq: this.bus.currentSeq(),
      id: this.ids.next("evt"),
      time: this.clock.iso(),
      subject: null,
      causation_id: null,
      payload,
    });
  }

  sendTransientToAll<T extends EventType>(type: T, payload: EventPayload<T>): void {
    const frame = this.transientFrame(type, payload);
    for (const sink of this.sinks) {
      try {
        sink.sendRaw(frame);
      } catch {
        // closing anyway
      }
    }
  }
}
