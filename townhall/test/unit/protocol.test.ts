import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { packageRoot } from "../../src/paths.js";
import {
  Agent,
  AgentActivity,
  AgentLifecycle,
  Approval,
  ApprovalCategory,
  ApprovalMode,
  BlockedReason,
  CloseCode,
  COMMAND_TYPES,
  commands,
  EVENT_TYPES,
  ErrorCode,
  EventEnvelope,
  events,
  Incident,
  IncidentKind,
  Mana,
  ManaLevel,
  ManaPeriod,
  MilestoneKey,
  Party,
  PauseReason,
  Progress,
  replyError,
  replyOk,
  ReplyEnvelope,
  Role,
  Task,
  TaskState,
  ToolAddon,
  ToolStatus,
  ToolType,
} from "../../src/protocol/index.js";

const md = readFileSync(path.resolve(packageRoot(), "..", "protocol", "PROTOCOL.md"), "utf8");
// Commands implemented ahead of PROTOCOL.md. Empty once the document catches up.
const EXTENSIONS: string[] = [];

function section(title: string): string {
  const start = md.indexOf(`## ${title}`);
  const next = md.indexOf("\n## ", start + 3);
  return md.slice(start, next === -1 ? undefined : next);
}

function tableNames(title: string): string[] {
  return [...section(title).matchAll(/^\| `([a-z_]+)` \|/gm)].map((m) => m[1]!);
}

describe("protocol conformance with PROTOCOL.md", () => {
  it("implements exactly the documented commands (plus listed extensions)", () => {
    const documented = tableNames("Commands");
    expect(documented.length).toBeGreaterThan(30);
    expect([...COMMAND_TYPES].sort()).toEqual([...documented, ...EXTENSIONS].sort());
  });

  it("implements exactly the documented events", () => {
    expect([...EVENT_TYPES].sort()).toEqual(tableNames("Events").sort());
  });

  it("uses the documented error codes and close codes", () => {
    const line = md.split("\n").find((l) => l.startsWith("**Error codes:**"))!;
    const codes = [...line.matchAll(/`([A-Z_]+)`/g)].map((m) => m[1]);
    expect(ErrorCode.options).toEqual(codes);
    const close = [...md.matchAll(/^\s*\| (\d{4}) \|/gm)].map((m) => Number(m[1]));
    expect(close).toHaveLength(4);
    expect(Object.values(CloseCode).sort()).toEqual(close.sort());
  });

  it("uses the documented enum values", () => {
    const pipe = (values: readonly string[]) => values.join("|");
    const quoted = (values: readonly string[]) => values.map((v) => `"${v}"`).join("|");
    expect(md).toContain(pipe(TaskState.options));
    expect(md).toContain(pipe(AgentLifecycle.options));
    expect(md).toContain(pipe(AgentActivity.options));
    expect(md).toContain(quoted(BlockedReason.options));
    expect(md).toContain(quoted(PauseReason.options));
    expect(md).toContain(pipe(IncidentKind.options));
    expect(md).toContain(pipe(ApprovalCategory.options));
    expect(md).toContain(pipe(ToolType.options));
    expect(md).toContain(pipe(ToolStatus.options));
    expect(md).toContain(pipe(Role.options));
    expect(md).toContain(pipe(ApprovalMode.options));
    expect(md).toContain(pipe(ManaLevel.options));
    expect(md).toContain(pipe(ManaPeriod.options));
    expect(md).toContain(quoted(MilestoneKey.options));
  });

  it("has payload and result schemas for every command, and a payload schema for every event", () => {
    for (const type of COMMAND_TYPES) {
      expect(commands[type].payload).toBeDefined();
      expect(commands[type].result).toBeDefined();
    }
    for (const type of EVENT_TYPES) expect(events[type]).toBeDefined();
  });
});

const agent = {
  id: "agt_01",
  name: "Mira",
  provider: "claude",
  model: "claude-opus-5-5",
  role: "artificer",
  instructions: "...",
  approval_mode: "trusted_edits",
  workspace: { path: "D:/work/app", mode: "git_worktree", repo_root: "D:/work/app" },
  seals: { S: 40, M: 150, L: 450, XL: 1200 },
  billing: "subscription",
  lifecycle: "active",
  activity: "idle",
  blocked_reason: null,
  home: { tile: { x: 40, y: 52 }, built: false },
  tool_ids: ["tl_1"],
  starting_tools: ["lectern", "quillworks"],
  current_task_id: null,
  queue: ["tsk_1"],
  xp: 0,
  level: 1,
  rank: "F",
  stats: { accepted: 0, accepted_first_try: 0, sent_back: 0, failed: 0, rites_passed: 0, party_tasks: 0, mana_spent_micros: 0 },
  party_id: null,
  version: 3,
  created_at: "2026-09-28T10:00:00.000Z",
};

const task = {
  id: "tsk_1",
  agent_id: "agt_01",
  party_id: null,
  parent_task_id: null,
  title: "Add a greeting",
  prompt: "...",
  size: "M",
  acceptance: ["..."],
  rite: "npm test",
  state: "awaiting_review",
  state_reason: null,
  attempt: 1,
  seal_micros: 1500000,
  reserved_micros: 0,
  spent_micros: 600000,
  spent_is_estimate: true,
  courier: { mode: "human", human_id: "h12" },
  created_at: "2026-09-28T10:00:00.000Z",
  started_at: "2026-09-28T10:01:00.000Z",
  finished_at: "2026-09-28T10:05:00.000Z",
  result: { summary: "...", diff_stat: { files: 3, added: 40, removed: 5 }, rite: { passed: true, output_tail: "..." }, deliverable: true },
  rewards: {
    rp: 351,
    xp: 351,
    resources: { food: 52, wood: 53, stone: 123, gold: 123 },
    breakdown: { base: 180, q: 0.5, e: 0.15, p: 0.3, d: 1.0, ceiling: 1200 },
  },
  version: 5,
};

describe("protocol round trips", () => {
  const samples: Array<[string, { parse: (v: unknown) => unknown }, unknown]> = [
    ["Agent", Agent, agent],
    ["Task", Task, task],
    [
      "ToolAddon",
      ToolAddon,
      {
        id: "tl_1",
        agent_id: "agt_01",
        type: "waygate",
        status: "building",
        tile: { x: 42, y: 50 },
        config_summary: { server_name: "github", transport: "stdio", allowed_tools: ["search"] },
        health: null,
      },
    ],
    [
      "Approval",
      Approval,
      {
        id: "apv_1",
        task_id: "tsk_1",
        agent_id: "agt_01",
        tool: "Bash",
        category: "command",
        risk: "medium",
        summary: "Run: npm install",
        input_preview: "{}",
        reason: null,
        status: "pending",
        scopes: ["once", "task", "agent"],
        seal_exhausted: false,
        created_at: "2026-09-28T10:00:00.000Z",
      },
    ],
    [
      "Incident",
      Incident,
      {
        id: "inc_1",
        kind: "hand_bell",
        severity: "warn",
        subject: { agent_id: "agt_01", task_id: "tsk_1" },
        message: "...",
        opened_at: "2026-09-28T10:00:00.000Z",
      },
    ],
    [
      "Mana",
      Mana,
      {
        period: "day",
        period_start: "2026-09-28T00:00:00.000Z",
        period_end: "2026-09-29T00:00:00.000Z",
        cap_micros: 5000000,
        spent_micros: 0,
        reserved_micros: 0,
        remaining_micros: 5000000,
        level: "normal",
        by_provider: { claude: 0, codex: 0, pi: 0 },
        estimates: true,
        provider_windows: [
          { provider: "claude", window: "five_hour", window_minutes: 300, used_percent: 41.5, resets_at: "2026-09-28T12:00:00.000Z" },
          { provider: "codex", window: "seven_day", window_minutes: 10080, used_percent: 12.5, resets_at: null },
        ],
      },
    ],
    ["Party", Party, { id: "pty_1", lead_agent_id: "agt_01", member_ids: ["agt_02"], created_at: "2026-09-28T10:00:00.000Z" }],
    [
      "Progress",
      Progress,
      {
        age: { current: 1, research: null },
        facts: { accepted: 2, accepted_first_try: 1, tools_built: 3, rites_passed: 0, party_tasks: 0, under_baseline: 1 },
        next: {
          n: 2,
          id: "market",
          name: "Market",
          wall: "Merchant Ring",
          cost: { food: 400, wood: 300, stone: 150, gold: 100 },
          research_s: 90,
          ready: false,
          milestones: [
            { key: "accepted", label: "tasks accepted", have: 2, want: 3, met: false },
            { key: "tools_built", label: "add-ons built", have: 3, want: 2, met: true },
          ],
        },
        quartermaster: { basic_rate: 0.95, precious_rate: 1 },
      },
    ],
  ];

  it.each(samples)("%s survives JSON and parsing unchanged", (_name, schema, value) => {
    expect(schema.parse(JSON.parse(JSON.stringify(value)))).toEqual(value);
  });

  it("rejects wrong shapes", () => {
    expect(Task.safeParse({ ...task, state: "done" }).success).toBe(false);
    expect(Task.safeParse({ ...task, spent_micros: 1.5 }).success).toBe(false);
    expect(Agent.safeParse({ ...agent, id: 7 }).success).toBe(false);
  });

  it("builds reply and event envelopes that parse", () => {
    const ok = replyOk("assign_task", "c-7f3a-42", { task_id: "tsk_1" });
    expect(ReplyEnvelope.parse(JSON.parse(JSON.stringify(ok)))).toEqual({
      v: 1,
      type: "assign_task_result",
      request_id: "c-7f3a-42",
      ok: true,
      payload: { task_id: "tsk_1" },
    });
    const err = replyError("assign_task", "c-7f3a-42", { code: "INSUFFICIENT_MANA", message: "...", retryable: false });
    expect(ReplyEnvelope.parse(err)).toEqual(err);
    const ev = {
      v: 1,
      type: "task_updated",
      seq: 1842,
      id: "evt_01",
      time: "2026-09-28T10:00:00.000Z",
      subject: "task/tsk_1",
      causation_id: "c-7f3a-42",
      payload: { task },
    };
    expect(EventEnvelope.parse(ev)).toEqual(ev);
    expect(events.task_updated.parse(ev.payload)).toEqual(ev.payload);
  });

  it("validates command payloads", () => {
    expect(commands.assign_task.payload.safeParse({ agent_id: "a", title: "t", prompt: "p", size: "M", courier: { mode: "human" } }).success).toBe(true);
    expect(commands.assign_task.payload.safeParse({ agent_id: "a", title: "t", prompt: "p", size: "XXL", courier: { mode: "human" } }).success).toBe(false);
    expect(commands.discard_workspace.payload.safeParse({ task_id: "t", confirm: false }).success).toBe(false);
    expect(
      commands.attach_tool.payload.safeParse({
        agent_id: "a",
        type: "waygate",
        tile: { x: 1, y: 2 },
        config: { server_name: "gh", transport: "http", url: "https://x", env_refs: ["GITHUB TOKEN=abc"] },
      }).success,
    ).toBe(false);
  });
});
