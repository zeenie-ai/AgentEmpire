import type { Clock } from "../core/clock.js";
import type { WaygateConfig } from "../protocol/commands.js";
import type {
  ApprovalCategory,
  ApprovalDecision,
  ApprovalMode,
  ModelInfo,
  Provider,
  ProviderInfo,
  Risk,
  Role,
  TaskSize,
  ToolType,
} from "../protocol/objects.js";

/** Everything an adapter needs to start (or resume) one attempt of a task. */
export interface RunRequest {
  taskId: string;
  agentId: string;
  attempt: number;
  provider: Provider;
  model: string;
  role: Role;
  size: TaskSize;
  /** Where the agent works: inside the task's worktree (or the versioned plain-folder copy). */
  cwd: string;
  /** Root of the task's worktree; the agent must stay inside it. */
  workspaceRoot: string;
  title: string;
  prompt: string;
  acceptance: string[];
  /** The agent's Oath. */
  instructions: string;
  approvalMode: ApprovalMode;
  /** Active add-ons; adapters map them to provider tools through economy.json. */
  tools: ToolType[];
  waygates: WaygateConfig[];
  budget: { sealMicros: number; spentMicros: number };
  resume: RunResume | null;
  party: RunParty | null;
  /** 0 for tasks from the player, 1 for party sub-tasks (which may not delegate). */
  depth: number;
}

export interface RunResume {
  sessionId: string | null;
  /** Adapter state saved through `RunHost.checkpoint`. */
  state: unknown;
  /** Feedback from `send_back`; null when resuming after a pause or a restart. */
  feedback: string | null;
}

export interface RunParty {
  partyId: string;
  members: Array<{ agentId: string; name: string; provider: Provider; role: Role }>;
}

/** One usage window of the provider's own limits (a subscription's five-hour or weekly window). */
export interface RateWindow {
  /** "five_hour", "seven_day", ... (stable per provider: a new report replaces the old one). */
  window: string;
  /** 0 to 100. */
  usedPercent: number;
  /** ISO time, or null when the harness did not say. */
  resetsAt: string | null;
  windowMinutes: number | null;
}

export type RunEvent =
  | { kind: "activity"; activity: "message" | "system" | "error"; text: string }
  | { kind: "tool_start"; tool: string; input?: unknown; text?: string }
  | { kind: "tool_end"; tool: string; ok: boolean; text?: string }
  | { kind: "usage"; costMicros: number; inputTokens?: number; outputTokens?: number; estimate?: boolean }
  | { kind: "session"; sessionId: string }
  | { kind: "files_touched"; paths: string[] }
  /** The provider's usage windows as the harness last reported them (Mana.provider_windows). */
  | { kind: "rate_limits"; windows: RateWindow[] };

export interface ApprovalRequest {
  tool: string;
  category: ApprovalCategory;
  input: unknown;
  summary?: string;
  risk?: Risk;
  reason?: string;
}

export interface ApprovalAnswer {
  decision: ApprovalDecision;
  message?: string;
  updatedInput?: unknown;
  /** Set when the request was withdrawn because the run is stopping. */
  cancelled?: boolean;
}

export interface DelegateRequest {
  /** An agent id, "member:<index>", or "any" (the first idle member). */
  to: string;
  title: string;
  prompt: string;
  size: TaskSize;
  budgetMana: number;
}

export interface ChildResult {
  taskId: string;
  status: "done" | "failed" | "cancelled" | "timeout";
  summary: string;
  diffStat: { files: number; added: number; removed: number } | null;
}

export interface DelegateHandle {
  taskId: string;
  /** Resolves when the sub-task finishes, or with status "timeout". */
  wait(timeoutMs?: number): Promise<ChildResult>;
}

/** Services the Town Hall offers a running adapter. */
export interface RunHost {
  readonly taskId: string;
  readonly clock: Clock;
  emit(event: RunEvent): void;
  /** Resolves when the player (or a rule) answers. Never times out on its own. */
  requestApproval(req: ApprovalRequest): Promise<ApprovalAnswer>;
  /** Party leads only: creates a sub-task on a member's queue. */
  delegate(req: DelegateRequest): Promise<DelegateHandle>;
  /** Persists adapter state so a later attempt can resume from it. */
  checkpoint(state: unknown): void;
}

export type RunOutcome =
  | { kind: "completed"; summary: string }
  | { kind: "interrupted" }
  | { kind: "failed"; error: { code: string; message: string; transient: boolean } };

export interface RunHandle {
  /** Sends extra text to the running agent (nudge). */
  send(message: string): void;
  /** Asks the agent to stop at the next safe point. */
  interrupt(): void;
  /** Stops the agent immediately. */
  kill(): void;
  readonly done: Promise<RunOutcome>;
}

export interface ProviderAdapter {
  readonly id: Provider;
  probe(): Promise<ProviderInfo>;
  listModels(): Promise<ModelInfo[]>;
  start(req: RunRequest, host: RunHost): RunHandle;
}
