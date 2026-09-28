import { fail } from "../../protocol/errors.js";
import { TaskState } from "../../protocol/objects.js";

export type { TaskState } from "../../protocol/objects.js";
type State = TaskState;

export const TASK_STATES: readonly State[] = TaskState.options;

/** States a task never leaves. */
export const TERMINAL_STATES: readonly State[] = ["accepted", "rejected", "cancelled"];

/**
 * Every allowed transition. `running` covers finishing work (snapshot and Rite) too;
 * `accepting` is the merge step, and a blocked merge stays there until retried.
 */
export const TRANSITIONS: Readonly<Record<State, readonly State[]>> = {
  in_transit: ["queued", "cancelled"],
  queued: ["preparing", "cancelled"],
  preparing: ["running", "paused", "failed", "cancelled"],
  running: ["awaiting_approval", "awaiting_review", "paused", "failed", "cancelled"],
  awaiting_approval: ["running", "awaiting_review", "paused", "failed", "cancelled"],
  awaiting_review: ["accepting", "queued", "rejected"],
  accepting: ["accepted", "queued", "rejected"],
  accepted: [],
  rejected: [],
  paused: ["queued", "awaiting_review", "cancelled"],
  failed: ["queued", "cancelled"],
  cancelled: [],
};

export type TaskEvent =
  | "deliver"
  | "dispatch"
  | "prepared"
  | "approval_requested"
  | "approval_answered"
  | "run_finished"
  | "pause"
  | "resume"
  | "fail"
  | "retry"
  | "cancel"
  | "stop_and_review"
  | "accept_begin"
  | "accept_done"
  | "send_back"
  | "abandon";

/** The state an event leads to from `state`, or null when the event does not apply. */
export function nextState(state: State, event: TaskEvent): State | null {
  switch (event) {
    case "deliver":
      return state === "in_transit" ? "queued" : null;
    case "dispatch":
      return state === "queued" ? "preparing" : null;
    case "prepared":
      return state === "preparing" ? "running" : null;
    case "approval_requested":
      return state === "running" ? "awaiting_approval" : null;
    case "approval_answered":
      return state === "awaiting_approval" ? "running" : null;
    case "run_finished":
      return state === "running" || state === "awaiting_approval" ? "awaiting_review" : null;
    case "pause":
      return state === "preparing" || state === "running" || state === "awaiting_approval" ? "paused" : null;
    case "resume":
      return state === "paused" || state === "failed" ? "queued" : null;
    case "fail":
      return state === "preparing" || state === "running" || state === "awaiting_approval" ? "failed" : null;
    case "retry":
      return state === "failed" ? "queued" : null;
    case "cancel":
      return ["in_transit", "queued", "preparing", "running", "awaiting_approval", "paused", "failed"].includes(state)
        ? "cancelled"
        : null;
    case "stop_and_review":
      return state === "paused" || state === "running" || state === "awaiting_approval" ? "awaiting_review" : null;
    case "accept_begin":
      return state === "awaiting_review" ? "accepting" : null;
    case "accept_done":
      return state === "accepting" ? "accepted" : null;
    case "send_back":
      return state === "awaiting_review" || state === "accepting" ? "queued" : null;
    case "abandon":
      return state === "awaiting_review" || state === "accepting" ? "rejected" : null;
  }
}

export function canTransition(from: State, to: State): boolean {
  return from === to ? false : TRANSITIONS[from].includes(to);
}

export function isTerminal(state: State): boolean {
  return TERMINAL_STATES.includes(state);
}

export function assertTransition(from: State, to: State): void {
  if (!canTransition(from, to)) throw fail.invalidState(`a task cannot go from ${from} to ${to}`);
}

/** States in which a run (or its preparation) is live. */
export const ACTIVE_STATES: readonly State[] = ["preparing", "running", "awaiting_approval"];
/** States that still wait in an agent's home queue. */
export const WAITING_STATES: readonly State[] = ["in_transit", "queued"];
