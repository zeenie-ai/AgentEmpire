import fc from "fast-check";
import { describe, expect, it } from "vitest";
import {
  assertTransition,
  canTransition,
  isTerminal,
  nextState,
  TASK_STATES,
  TERMINAL_STATES,
  TRANSITIONS,
  type TaskEvent,
  type TaskState,
} from "../../src/core/tasks/state-machine.js";
import { TownError } from "../../src/protocol/errors.js";

const EVENTS: TaskEvent[] = [
  "deliver",
  "dispatch",
  "prepared",
  "approval_requested",
  "approval_answered",
  "run_finished",
  "pause",
  "resume",
  "fail",
  "retry",
  "cancel",
  "stop_and_review",
  "accept_begin",
  "accept_done",
  "send_back",
  "abandon",
];

const anyState = fc.constantFrom(...TASK_STATES);
const anyEvent = fc.constantFrom(...EVENTS);

describe("task state machine", () => {
  it("only ever produces transitions listed in the table", () => {
    fc.assert(
      fc.property(anyState, anyEvent, (state, event) => {
        const next = nextState(state, event);
        return next === null || canTransition(state, next);
      }),
    );
  });

  it("keeps terminal states terminal under any sequence of events", () => {
    fc.assert(
      fc.property(fc.constantFrom(...TERMINAL_STATES), fc.array(anyEvent, { maxLength: 50 }), (start, events) => {
        let state: TaskState = start;
        for (const e of events) state = nextState(state, e) ?? state;
        return state === start;
      }),
    );
    for (const s of TERMINAL_STATES) expect(TRANSITIONS[s]).toEqual([]);
  });

  it("random walks from in_transit never make an illegal move and never leave a terminal state", () => {
    fc.assert(
      fc.property(fc.array(anyEvent, { maxLength: 80 }), (events) => {
        let state: TaskState = "in_transit";
        let terminalSeen: TaskState | null = null;
        for (const e of events) {
          const next = nextState(state, e);
          if (next === null) continue;
          expect(canTransition(state, next)).toBe(true);
          if (terminalSeen) return false;
          state = next;
          if (isTerminal(state)) terminalSeen = state;
        }
        return true;
      }),
      { numRuns: 500 },
    );
  });

  it("refuses every transition that is not in the table", () => {
    fc.assert(
      fc.property(anyState, anyState, (from, to) => {
        const allowed = TRANSITIONS[from].includes(to) && from !== to;
        if (allowed) {
          expect(() => assertTransition(from, to)).not.toThrow();
        } else {
          try {
            assertTransition(from, to);
            return false;
          } catch (err) {
            expect(err).toBeInstanceOf(TownError);
            expect((err as TownError).code).toBe("INVALID_STATE");
          }
        }
        return true;
      }),
    );
  });

  it("has an event for every transition in the table, and no others", () => {
    const produced = new Set<string>();
    for (const s of TASK_STATES) for (const e of EVENTS) {
      const n = nextState(s, e);
      if (n && n !== s) produced.add(`${s}>${n}`);
    }
    const table = new Set<string>();
    for (const s of TASK_STATES) for (const n of TRANSITIONS[s]) table.add(`${s}>${n}`);
    expect([...produced].sort()).toEqual([...table].sort());
  });

  it("lets every state reach a terminal state, and reaches every state from in_transit", () => {
    const reach = (from: TaskState) => {
      const seen = new Set<TaskState>([from]);
      const queue = [from];
      while (queue.length) for (const n of TRANSITIONS[queue.shift()!]) if (!seen.has(n)) (seen.add(n), queue.push(n));
      return seen;
    };
    for (const s of TASK_STATES) expect([...reach(s)].some(isTerminal)).toBe(true);
    expect(reach("in_transit").size).toBe(TASK_STATES.length);
  });
});
