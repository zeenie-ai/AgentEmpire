import { z } from "zod";
import {
  ActivityEntry,
  Agent,
  Age,
  Approval,
  ApprovalDecision,
  ApprovalResolvedBy,
  ApprovalScope,
  Incident,
  Mana,
  Party,
  Progress,
  ProgressPhase,
  ProviderInfo,
  Resources,
  Task,
  ToolAddon,
} from "./objects.js";

const id = z.string().min(1).max(128);
const nonNegInt = z.number().int().min(0);

export const events = {
  agent_updated: z.object({ agent: Agent }),
  agent_retired: z.object({ agent_id: id }),
  tool_updated: z.object({ tool: ToolAddon }),
  task_updated: z.object({ task: Task }),
  task_progress: z.object({
    task_id: id,
    phase: ProgressPhase,
    current_tool: z.string().nullable().optional(),
    files_touched: nonNegInt,
    spent_micros: nonNegInt,
  }),
  task_activity: z.object({ task_id: id, entry: ActivityEntry }),
  approval_requested: z.object({ approval: Approval }),
  approval_resolved: z.object({
    approval_id: id,
    decision: ApprovalDecision,
    scope: ApprovalScope,
    by: ApprovalResolvedBy,
  }),
  mana_updated: z.object({ mana: Mana }),
  treasury_updated: z.object({ treasury: Resources, reason: z.string(), delta: Resources }),
  incident_opened: z.object({ incident: Incident }),
  incident_resolved: z.object({ incident_id: id }),
  party_updated: z.object({ party: Party }),
  party_disbanded: z.object({ party_id: id }),
  subtask_delegated: z.object({ parent_task_id: id, task_id: id, from_agent_id: id, to_agent_id: id }),
  age_updated: z.object({ age: Age }),
  providers_updated: z.object({ providers: z.array(ProviderInfo) }),
  town_saved: z.object({ rev: nonNegInt }),
  session_revoked: z.object({}),
  daemon_shutdown: z.object({}),
  /** 1.3: the get_progress object, whenever any part of it changes. */
  progress_updated: Progress,
};

export type Events = typeof events;
export type EventType = keyof Events;
export type EventPayload<T extends EventType> = z.input<Events[T]>;

export const EVENT_TYPES = Object.keys(events) as EventType[];
