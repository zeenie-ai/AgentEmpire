import { z } from "zod";
import {
  ActivityEntry,
  Agent,
  Age,
  Approval,
  ApprovalDecision,
  ApprovalMode,
  ApprovalScope,
  Billing,
  Catchup,
  ClientPlatform,
  CostInput,
  Courier,
  DiffFile,
  Incident,
  Integrate,
  LanternHours,
  LedgerEntry,
  Mana,
  ManaPeriod,
  MergeBlockedReason,
  ModelInfo,
  Party,
  Progress,
  Provider,
  ProviderInfo,
  Research,
  ResourceName,
  Resources,
  RetireWhen,
  Rewards,
  Role,
  Settings,
  Task,
  TaskSize,
  Tile,
  ToolAddon,
  ToolType,
  TownRef,
  WaygateTransport,
} from "./objects.js";

const int = z.number().int();
const nonNegInt = int.min(0);
const id = z.string().min(1).max(128);
const opId = z.string().min(1).max(128);
const empty = z.object({});

const SealsPatch = z.object({
  S: int.min(1).optional(),
  M: int.min(1).optional(),
  L: int.min(1).optional(),
  XL: int.min(1).optional(),
});

const envName = z.string().regex(/^[A-Za-z_][A-Za-z0-9_]{0,127}$/, "must be an environment variable name");

export const WaygateConfig = z.object({
  server_name: z.string().regex(/^[A-Za-z0-9_.-]{1,64}$/),
  transport: WaygateTransport,
  command: z.string().max(512).optional(),
  args: z.array(z.string().max(1024)).max(64).optional(),
  env_refs: z.array(envName).max(64).optional(),
  url: z.string().max(2048).optional(),
  header_refs: z.record(z.string().regex(/^[A-Za-z0-9-]{1,128}$/), envName).optional(),
  allowed_tools: z.array(z.string().max(128)).max(256).optional(),
});
export type WaygateConfig = z.infer<typeof WaygateConfig>;

export const GetStateResult = z.object({
  seq: nonNegInt,
  age: Age,
  treasury: Resources,
  mana: Mana,
  agents: z.array(Agent),
  tools: z.array(ToolAddon),
  tasks: z.array(Task),
  approvals: z.array(Approval),
  parties: z.array(Party),
  incidents: z.array(Incident),
  town: TownRef.nullable(),
  settings: Settings,
  providers: z.array(ProviderInfo),
  /** Added in 1.3: the same object get_progress returns. */
  progress: Progress,
});

const setSettingPayload = z.discriminatedUnion("key", [
  z.object({ key: z.literal("work_while_away"), value: z.boolean() }),
  z.object({ key: z.literal("express_dispatch"), value: z.boolean() }),
  z.object({ key: z.literal("lantern_hours"), value: LanternHours }),
]);

interface CommandDef<P extends z.ZodType, R extends z.ZodType> {
  payload: P;
  result: R;
  /** Commands that change state use `request_id` as an idempotency key. */
  mutating: boolean;
}

function def<P extends z.ZodType, R extends z.ZodType>(payload: P, result: R, mutating: boolean): CommandDef<P, R> {
  return { payload, result, mutating };
}

export const commands = {
  hello: def(
    z.object({
      token: z.string().max(256),
      protocol: z.object({ major: int, minor: int }),
      client: z.object({ name: z.string().max(64), version: z.string().max(64), platform: ClientPlatform }),
      last_seq: nonNegInt.nullable().optional(),
      take_over: z.boolean().optional(),
    }),
    z.object({
      protocol: z.object({ major: int, minor: int }),
      daemon_version: z.string(),
      sdk_versions: z.record(z.string(), z.string()),
      features: z.array(z.string()),
      seq: nonNegInt,
      catchup: Catchup,
    }),
    false,
  ),
  ping: def(empty, empty, false),
  get_state: def(empty, GetStateResult, false),
  check_providers: def(empty, z.object({ providers: z.array(ProviderInfo) }), false),
  list_models: def(z.object({ provider: Provider }), z.object({ models: z.array(ModelInfo) }), false),
  browse_folder: def(
    z.object({ path: z.string().max(4096).nullable().optional() }),
    z.object({
      path: z.string().nullable(),
      parent: z.string().nullable(),
      entries: z.array(z.object({ name: z.string(), path: z.string(), is_git_repo: z.boolean() })),
      roots: z.array(z.string()),
    }),
    false,
  ),
  create_agent: def(
    z.object({
      spec: z.object({
        name: z.string().trim().min(1).max(40),
        provider: Provider,
        model: z.string().min(1).max(100),
        role: Role,
        instructions: z.string().max(8000).default(""),
        approval_mode: ApprovalMode.optional(),
        workspace: z.object({ path: z.string().min(1).max(4096) }),
        seals: SealsPatch.optional(),
        billing: Billing.optional(),
        starting_tools: z.array(ToolType).max(8).default([]),
      }),
    }),
    z.object({ agent_id: id, cost: Resources, free: z.boolean(), training: z.object({ duration_ms: nonNegInt }) }),
    true,
  ),
  agent_trained: def(z.object({ agent_id: id }), empty, true),
  place_home: def(z.object({ agent_id: id, tile: Tile }), z.object({ cost: Resources }), true),
  home_built: def(z.object({ agent_id: id }), empty, true),
  update_agent: def(
    z.object({
      agent_id: id,
      patch: z.object({
        name: z.string().trim().min(1).max(40).optional(),
        model: z.string().min(1).max(100).optional(),
        instructions: z.string().max(8000).optional(),
        approval_mode: ApprovalMode.optional(),
        seals: SealsPatch.optional(),
      }),
      expected_version: int.min(1),
    }),
    z.object({ agent: Agent }),
    true,
  ),
  retire_agent: def(z.object({ agent_id: id, when: RetireWhen }), empty, true),
  attach_tool: def(
    z.object({ agent_id: id, type: ToolType, tile: Tile, config: WaygateConfig.optional() }),
    z.object({ tool_id: id, cost: Resources }),
    true,
  ),
  tool_built: def(z.object({ tool_id: id }), empty, true),
  detach_tool: def(z.object({ tool_id: id }), z.object({ refund: Resources }), true),
  assign_task: def(
    z.object({
      agent_id: id.optional(),
      party_id: id.optional(),
      title: z.string().trim().min(1).max(200),
      prompt: z.string().min(1).max(32_000),
      size: TaskSize,
      acceptance: z.array(z.string().max(500)).max(20).optional(),
      rite: z.string().max(1000).nullable().optional(),
      seal_mana: int.min(1).max(1_000_000).optional(),
      courier: Courier,
    }),
    z.object({ task_id: id }),
    true,
  ),
  task_delivered: def(z.object({ task_id: id }), empty, true),
  cancel_task: def(z.object({ task_id: id }), empty, true),
  resume_task: def(z.object({ task_id: id, extend_seal_mana: int.min(1).max(1_000_000).optional() }), empty, true),
  /** Extension to PROTOCOL.md 1.0: the "Stop and review" choice for a paused task. */
  stop_and_review: def(z.object({ task_id: id }), empty, true),
  nudge_task: def(z.object({ task_id: id, message: z.string().min(1).max(4000) }), empty, true),
  respond_approval: def(
    z.object({
      approval_id: id,
      decision: ApprovalDecision,
      scope: ApprovalScope,
      message: z.string().max(4000).optional(),
      updated_input: z.unknown().optional(),
    }),
    empty,
    true,
  ),
  get_task_detail: def(
    z.object({ task_id: id, include: z.array(z.enum(["activity", "diff"])).default(["activity"]) }),
    z.object({
      task: Task,
      activity: z.array(ActivityEntry),
      diff: z.object({ files: z.array(DiffFile), patch: z.string().optional() }).optional(),
    }),
    false,
  ),
  accept_result: def(
    z.object({ task_id: id, integrate: Integrate }),
    z.object({
      rewards: Rewards.nullable(),
      merge: z.object({ commit: z.string().optional(), blocked_reason: MergeBlockedReason.optional() }).optional(),
    }),
    true,
  ),
  send_back: def(z.object({ task_id: id, feedback: z.string().min(1).max(16_000) }), empty, true),
  abandon_task: def(z.object({ task_id: id }), empty, true),
  discard_workspace: def(z.object({ task_id: id, confirm: z.literal(true) }), empty, true),
  form_party: def(
    z.object({ lead_agent_id: id, member_ids: z.array(id).min(1).max(16) }),
    z.object({ party_id: id }),
    true,
  ),
  disband_party: def(z.object({ party_id: id }), empty, true),
  set_budget: def(
    z.object({
      period: ManaPeriod,
      refill_hour_local: int.min(0).max(23).optional(),
      pool_usd: z.number().min(0).max(100_000),
      /** `pi` was added in 1.2; when a 1.1 client leaves it out, the current pi billing is kept. */
      billing: z.object({ claude: Billing, codex: Billing, pi: Billing.optional() }),
      confirm_raise: z.boolean().optional(),
    }),
    z.object({ mana: Mana }),
    true,
  ),
  spend_resources: def(
    z.object({ op_id: opId, reason: z.string().min(1).max(64), cost: CostInput, ref: z.string().max(128).optional() }),
    z.object({ treasury: Resources }),
    true,
  ),
  refund_resources: def(
    z.object({ op_id: opId, spend_op_id: opId, fraction: z.number().gt(0).max(1) }),
    z.object({ treasury: Resources }),
    true,
  ),
  report_gather: def(
    z.object({
      op_id: opId,
      deposits: z.object({ food: nonNegInt.optional(), wood: nonNegInt.optional() }),
      storehouses: int.min(0).max(1000),
    }),
    z.object({ treasury: Resources }),
    true,
  ),
  trade: def(
    z.object({ op_id: opId, give: z.object({ resource: ResourceName, amount: int.min(1).max(100_000) }), get: ResourceName }),
    z.object({ treasury: Resources, rate: z.number() }),
    true,
  ),
  advance_age: def(empty, z.object({ research: Research }), true),
  save_town: def(
    z.object({ base_rev: nonNegInt, schema_version: nonNegInt, snapshot: z.unknown() }),
    z.object({ rev: nonNegInt }),
    true,
  ),
  load_town: def(
    empty,
    z.object({ rev: nonNegInt, schema_version: nonNegInt, snapshot: z.unknown() }).nullable(),
    false,
  ),
  set_setting: def(setSettingPayload, z.object({ settings: Settings }), true),
  get_ledger: def(
    z.object({ limit: int.min(1).max(1000).optional() }),
    z.object({ entries: z.array(LedgerEntry), treasury: Resources }),
    false,
  ),
  /** 1.3: the town's progression (age, facts, next age milestones, Quartermaster rates). */
  get_progress: def(empty, Progress, false),
  /**
   * 1.3: the Town Hall replies, sends daemon_shutdown, pauses running tasks (they resume on the
   * next start), closes, removes its runtime files and exits.
   */
  shutdown: def(empty, empty, false),
};

export type Commands = typeof commands;
export type CommandType = keyof Commands;
export type CommandPayload<T extends CommandType> = z.output<Commands[T]["payload"]>;
export type CommandResult<T extends CommandType> = z.input<Commands[T]["result"]>;

export const COMMAND_TYPES = Object.keys(commands) as CommandType[];

export function isCommandType(type: string): type is CommandType {
  return Object.prototype.hasOwnProperty.call(commands, type);
}
