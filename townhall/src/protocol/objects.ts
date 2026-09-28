import { z } from "zod";

// ---------- enums ----------

export const Provider = z.enum(["claude", "codex"]);
export const Role = z.enum(["artificer", "scholar", "scribe", "warden", "herald"]);
export const ApprovalMode = z.enum(["ask_every_time", "trusted_edits", "plan_first", "free_hand"]);
export const WorkspaceMode = z.enum(["git_worktree", "plain_folder"]);
export const Billing = z.enum(["api_key", "subscription"]);
export const AgentLifecycle = z.enum(["training", "settling", "active", "retired"]);
export const AgentActivity = z.enum(["idle", "working", "awaiting_approval", "blocked"]);
export const BlockedReason = z.enum(["missing_tools", "no_mana", "provider_offline", "workspace_error"]);
export const ToolType = z.enum(["lectern", "quillworks", "forge", "rookery", "archive", "waygate"]);
export const ToolStatus = z.enum(["building", "active", "error", "removed"]);
export const TaskSize = z.enum(["S", "M", "L", "XL"]);
export const TaskState = z.enum([
  "in_transit",
  "queued",
  "preparing",
  "running",
  "awaiting_approval",
  "awaiting_review",
  "accepting",
  "accepted",
  "rejected",
  "paused",
  "failed",
  "cancelled",
]);
export const PauseReason = z.enum(["budget", "restart", "stalled", "mana_depleted", "provider_limit"]);
export const CourierMode = z.enum(["human", "wisp", "express"]);
export const ApprovalCategory = z.enum(["read", "write", "command", "network", "outside_workspace", "mcp"]);
export const Risk = z.enum(["low", "medium", "high"]);
export const ApprovalStatus = z.enum(["pending", "orphaned"]);
export const ApprovalScope = z.enum(["once", "task", "agent"]);
export const ApprovalDecision = z.enum(["allow", "deny"]);
export const ApprovalResolvedBy = z.enum(["player", "rule", "pre_approval", "restart", "cancelled"]);
export const IncidentKind = z.enum([
  "smoke",
  "alarm_bell",
  "hand_bell",
  "dim_lanterns",
  "font_dark",
  "rift",
  "merge_blocked",
]);
export const IncidentSeverity = z.enum(["info", "warn", "urgent"]);
export const ManaPeriod = z.enum(["day", "week", "month"]);
export const ManaLevel = z.enum(["normal", "dim", "warning", "depleted"]);
export const ActivityKind = z.enum(["message", "tool_start", "tool_end", "error", "system"]);
export const ProgressPhase = z.enum(["preparing", "working", "tool", "delegating", "finishing", "rite"]);
export const Integrate = z.enum(["merge", "keep_branch", "export"]);
export const ClientPlatform = z.enum(["desktop", "web"]);
export const Catchup = z.enum(["replay", "snapshot"]);
export const RetireWhen = z.enum(["now", "after_current"]);
export const WaygateTransport = z.enum(["stdio", "http"]);
export const BillingHint = z.enum(["api_key", "subscription", "unknown"]);
export const ResourceName = z.enum(["food", "wood", "stone", "gold"]);
export const DiffFileStatus = z.enum(["added", "modified", "deleted", "renamed", "copied", "type_changed", "unknown"]);
export const SettingKey = z.enum(["work_while_away", "express_dispatch", "lantern_hours"]);
export const MergeBlockedReason = z.enum([
  "checkout_dirty",
  "wrong_branch",
  "conflict",
  "merge_failed",
  "export_conflict",
  "not_a_repo",
  "workspace_missing",
]);

export type Provider = z.infer<typeof Provider>;
export type Role = z.infer<typeof Role>;
export type ApprovalMode = z.infer<typeof ApprovalMode>;
export type WorkspaceMode = z.infer<typeof WorkspaceMode>;
export type Billing = z.infer<typeof Billing>;
export type AgentLifecycle = z.infer<typeof AgentLifecycle>;
export type AgentActivity = z.infer<typeof AgentActivity>;
export type BlockedReason = z.infer<typeof BlockedReason>;
export type ToolType = z.infer<typeof ToolType>;
export type ToolStatus = z.infer<typeof ToolStatus>;
export type TaskSize = z.infer<typeof TaskSize>;
export type TaskState = z.infer<typeof TaskState>;
export type PauseReason = z.infer<typeof PauseReason>;
export type CourierMode = z.infer<typeof CourierMode>;
export type ApprovalCategory = z.infer<typeof ApprovalCategory>;
export type Risk = z.infer<typeof Risk>;
export type ApprovalScope = z.infer<typeof ApprovalScope>;
export type ApprovalDecision = z.infer<typeof ApprovalDecision>;
export type ApprovalResolvedBy = z.infer<typeof ApprovalResolvedBy>;
export type IncidentKind = z.infer<typeof IncidentKind>;
export type IncidentSeverity = z.infer<typeof IncidentSeverity>;
export type ManaPeriod = z.infer<typeof ManaPeriod>;
export type ManaLevel = z.infer<typeof ManaLevel>;
export type ActivityKind = z.infer<typeof ActivityKind>;
export type ProgressPhase = z.infer<typeof ProgressPhase>;
export type Integrate = z.infer<typeof Integrate>;
export type MergeBlockedReason = z.infer<typeof MergeBlockedReason>;
export type DiffFileStatus = z.infer<typeof DiffFileStatus>;

// ---------- shared objects ----------

const int = z.number().int();
const nonNegInt = int.min(0);
const isoTime = z.string();
const id = z.string().min(1).max(128);

export const Resources = z.object({ food: int, wood: int, stone: int, gold: int });
export type Resources = z.infer<typeof Resources>;

export const CostInput = z.object({
  food: nonNegInt.optional(),
  wood: nonNegInt.optional(),
  stone: nonNegInt.optional(),
  gold: nonNegInt.optional(),
});

export const Tile = z.object({ x: int, y: int });
export type Tile = z.infer<typeof Tile>;

export const Seals = z.object({ S: nonNegInt, M: nonNegInt, L: nonNegInt, XL: nonNegInt });
export type Seals = z.infer<typeof Seals>;

export const AgentStats = z.object({
  accepted: nonNegInt,
  accepted_first_try: nonNegInt,
  sent_back: nonNegInt,
  failed: nonNegInt,
  rites_passed: nonNegInt,
  party_tasks: nonNegInt,
  mana_spent_micros: nonNegInt,
});
export type AgentStats = z.infer<typeof AgentStats>;

export const Agent = z.object({
  id,
  name: z.string(),
  provider: Provider,
  model: z.string(),
  role: Role,
  instructions: z.string(),
  approval_mode: ApprovalMode,
  workspace: z.object({ path: z.string(), mode: WorkspaceMode, repo_root: z.string().nullable() }),
  seals: Seals,
  billing: Billing,
  lifecycle: AgentLifecycle,
  activity: AgentActivity,
  blocked_reason: BlockedReason.nullable(),
  home: z.object({ tile: Tile, built: z.boolean() }).nullable(),
  tool_ids: z.array(id),
  current_task_id: id.nullable(),
  queue: z.array(id),
  xp: nonNegInt,
  level: int.min(1),
  rank: z.string(),
  stats: AgentStats,
  party_id: id.nullable(),
  version: int.min(1),
  created_at: isoTime,
});
export type Agent = z.infer<typeof Agent>;

export const WaygateConfigSummary = z.object({
  server_name: z.string(),
  transport: WaygateTransport,
  allowed_tools: z.array(z.string()),
});

export const ToolAddon = z.object({
  id,
  agent_id: id,
  type: ToolType,
  status: ToolStatus,
  tile: Tile,
  config_summary: WaygateConfigSummary.nullable(),
  health: z.object({ ok: z.boolean(), tools: z.array(z.string()), checked_at: isoTime }).nullable(),
});
export type ToolAddon = z.infer<typeof ToolAddon>;

export const DiffStat = z.object({ files: nonNegInt, added: nonNegInt, removed: nonNegInt });
export type DiffStat = z.infer<typeof DiffStat>;

export const RiteResult = z.object({ passed: z.boolean(), output_tail: z.string() });
export type RiteResult = z.infer<typeof RiteResult>;

export const TaskResult = z.object({
  summary: z.string(),
  diff_stat: DiffStat,
  rite: RiteResult.nullable(),
  deliverable: z.boolean(),
});
export type TaskResult = z.infer<typeof TaskResult>;

export const RewardBreakdown = z.object({
  base: z.number(),
  q: z.number(),
  e: z.number(),
  p: z.number(),
  d: z.number(),
  ceiling: z.number(),
  /** Set when the reward is zero by rule: duplicate, no_deliverable, too_short, party_subtask. */
  zero_reason: z.string().optional(),
});

export const Rewards = z.object({
  rp: nonNegInt,
  xp: nonNegInt,
  resources: Resources,
  breakdown: RewardBreakdown,
});
export type Rewards = z.infer<typeof Rewards>;

export const Courier = z.object({ mode: CourierMode, human_id: z.string().max(128).nullable().optional() });

export const Task = z.object({
  id,
  agent_id: id,
  party_id: id.nullable(),
  parent_task_id: id.nullable(),
  title: z.string(),
  prompt: z.string(),
  size: TaskSize,
  acceptance: z.array(z.string()),
  rite: z.string().nullable(),
  state: TaskState,
  state_reason: z.string().nullable(),
  attempt: int.min(1),
  seal_micros: nonNegInt,
  reserved_micros: nonNegInt,
  spent_micros: nonNegInt,
  spent_is_estimate: z.boolean(),
  courier: Courier,
  created_at: isoTime,
  started_at: isoTime.nullable(),
  finished_at: isoTime.nullable(),
  result: TaskResult.nullable(),
  rewards: Rewards.nullable(),
  version: int.min(1),
});
export type Task = z.infer<typeof Task>;

export const Approval = z.object({
  id,
  task_id: id,
  agent_id: id,
  tool: z.string(),
  category: ApprovalCategory,
  risk: Risk,
  summary: z.string(),
  input_preview: z.string(),
  reason: z.string().nullable(),
  status: ApprovalStatus,
  scopes: z.array(ApprovalScope),
  seal_exhausted: z.boolean(),
  created_at: isoTime,
});
export type Approval = z.infer<typeof Approval>;

export const Incident = z.object({
  id,
  kind: IncidentKind,
  severity: IncidentSeverity,
  subject: z.object({ agent_id: id.nullable(), task_id: id.nullable() }),
  message: z.string(),
  opened_at: isoTime,
});
export type Incident = z.infer<typeof Incident>;

export const ProviderWindow = z.object({
  provider: Provider,
  used_percent: z.number(),
  resets_at: isoTime.nullable(),
});

export const Mana = z.object({
  period: ManaPeriod,
  period_start: isoTime,
  period_end: isoTime,
  cap_micros: nonNegInt,
  spent_micros: nonNegInt,
  reserved_micros: nonNegInt,
  remaining_micros: nonNegInt,
  level: ManaLevel,
  by_provider: z.object({ claude: nonNegInt, codex: nonNegInt }),
  estimates: z.boolean(),
  provider_windows: z.array(ProviderWindow),
});
export type Mana = z.infer<typeof Mana>;

export const Party = z.object({
  id,
  lead_agent_id: id,
  member_ids: z.array(id),
  created_at: isoTime,
});
export type Party = z.infer<typeof Party>;

export const Research = z.object({ target: int, started_at: isoTime, duration_ms: nonNegInt });
export const Age = z.object({ current: int.min(1).max(4), research: Research.nullable() });
export type Age = z.infer<typeof Age>;

export const ActivityEntry = z.object({ time: isoTime, kind: ActivityKind, text: z.string() });
export type ActivityEntry = z.infer<typeof ActivityEntry>;

export const LanternHours = z.object({ start: int.min(0).max(23), end: int.min(0).max(23) });

export const Settings = z.object({
  work_while_away: z.boolean(),
  express_dispatch: z.boolean(),
  lantern_hours: LanternHours,
});
export type Settings = z.infer<typeof Settings>;

export const ProviderInfo = z.object({
  id: Provider,
  installed: z.boolean(),
  version: z.string().optional(),
  logged_in: z.boolean(),
  billing_hint: BillingHint,
  message: z.string().optional(),
});
export type ProviderInfo = z.infer<typeof ProviderInfo>;

export const ModelInfo = z.object({
  id: z.string(),
  label: z.string(),
  default: z.boolean(),
  cost_hint: z.string().optional(),
});
export type ModelInfo = z.infer<typeof ModelInfo>;

export const TownRef = z.object({ rev: nonNegInt, schema_version: nonNegInt });

export const LedgerEntry = z.object({
  id: z.string(),
  time: isoTime,
  op_id: z.string().nullable(),
  kind: z.string(),
  reason: z.string(),
  ref: z.string().nullable(),
  delta: Resources,
});
export type LedgerEntry = z.infer<typeof LedgerEntry>;

export const DiffFile = z.object({
  path: z.string(),
  status: DiffFileStatus,
  added: nonNegInt,
  removed: nonNegInt,
});
export type DiffFile = z.infer<typeof DiffFile>;
