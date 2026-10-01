import { existsSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { SystemClock } from "../../src/core/clock.js";
import type { Provider } from "../../src/protocol/objects.js";
import type {
  ApprovalAnswer,
  ApprovalRequest,
  DelegateHandle,
  PartyStatus,
  ProviderAdapter,
  RunEvent,
  RunHandle,
  RunHost,
  RunOutcome,
} from "../../src/providers/types.js";
import { makeRepo } from "../helpers/git.js";
import { tempRoot } from "../helpers/harness.js";
import { runRequest } from "../helpers/run-host.js";

/** Every smoke run stays under this, in micro-USD ($0.10). */
export const SMOKE_CAP_MICROS = 100_000;
const FILE = "smoke.txt";
const CONTENT = "aurelhaven smoke";

/**
 * A RunHost for smoke runs. Approvals are allowed, except that `hold` keeps them pending so the
 * test can interrupt while one waits; usage past the cap stops the run like a spent Mana Seal.
 */
class SmokeHost implements RunHost {
  readonly taskId = "tsk_smoke";
  readonly clock = new SystemClock();
  readonly events: RunEvent[] = [];
  readonly approvals: ApprovalRequest[] = [];
  readonly checkpoints: unknown[] = [];
  private pending: Array<(a: ApprovalAnswer) => void> = [];
  private approvalSeen: (() => void) | null = null;
  run: RunHandle | null = null;

  constructor(private readonly hold: boolean) {}

  readonly firstApproval = new Promise<void>((resolve) => {
    this.approvalSeen = resolve;
  });

  emit(event: RunEvent): void {
    this.events.push(event);
    if (event.kind === "usage" && this.usageMicros() >= SMOKE_CAP_MICROS) this.run?.interrupt();
  }

  requestApproval(req: ApprovalRequest): Promise<ApprovalAnswer> {
    this.approvals.push(req);
    this.approvalSeen?.();
    if (!this.hold) return Promise.resolve({ decision: "allow" });
    return new Promise((resolve) => this.pending.push(resolve));
  }

  /** What the Town Hall does when a run stops: withdraw its open approvals. */
  withdraw(): void {
    for (const resolve of this.pending.splice(0)) resolve({ decision: "deny", cancelled: true });
  }

  async delegate(): Promise<DelegateHandle> {
    throw new Error("no parties in these smoke runs");
  }

  partyStatus(): PartyStatus {
    return { sealLeftMana: 0, subtasks: [] };
  }

  async waitSubtasks(): Promise<PartyStatus> {
    return this.partyStatus();
  }

  checkpoint(state: unknown): void {
    this.checkpoints.push(JSON.parse(JSON.stringify(state)) as unknown);
  }

  usageMicros(): number {
    return this.events.reduce((s, e) => s + (e.kind === "usage" ? e.costMicros : 0), 0);
  }

  sessionId(): string | null {
    const e = [...this.events].reverse().find((x) => x.kind === "session");
    return e && e.kind === "session" ? e.sessionId : null;
  }
}

export interface SmokeReport {
  provider: Provider;
  model: string;
  version: string | undefined;
  firstOutcome: RunOutcome;
  secondOutcome: RunOutcome;
  approvals: Array<{ run: number; tool: string; category: string; summary: string | undefined }>;
  costMicros: { first: number; second: number; total: number };
  estimate: boolean | undefined;
  sessionIds: [string | null, string | null];
  checkpoints: [unknown, unknown];
  fileContent: string | null;
  seconds: number;
}

function withTimeout<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
  return Promise.race([p, new Promise<T>((_, reject) => setTimeout(() => reject(new Error(`${what} took longer than ${ms / 1000} s`)), ms))]);
}

/**
 * One smoke round on a real model: the agent is asked to create a file, the run is interrupted
 * while its first approval waits, then the session is resumed and the file is created through
 * an approval. Returns what was recorded.
 */
export async function smokeRun(adapter: ProviderAdapter, provider: Provider, model: string, version: string | undefined): Promise<SmokeReport> {
  const started = Date.now();
  const root = tempRoot(`smoke-${provider}`);
  const repo = makeRepo(root, "app");
  const base = runRequest(repo, {
    taskId: "tsk_smoke",
    provider,
    model,
    title: "Smoke test",
    prompt: `Create a file named ${FILE} in the current folder containing exactly the text "${CONTENT}" (no newline). Do nothing else, then reply with one short sentence.`,
    acceptance: [`${FILE} contains "${CONTENT}"`],
    instructions: "Be brief. Use as few steps as possible.",
    approvalMode: "ask_every_time",
    tools: ["lectern", "quillworks"],
    // Stays under the cap even with Claude Code's own backstop margin.
    budget: { sealMicros: 80_000, spentMicros: 0 },
  });

  // Run 1: hold the first approval, then interrupt the way the Town Hall does (stop first,
  // then withdraw the open approval). A run that ends before asking is reported as it ended.
  const first = new SmokeHost(true);
  const run1 = adapter.start(base, first);
  first.run = run1;
  const reached = await withTimeout(
    Promise.race([first.firstApproval.then(() => "approval" as const), run1.done.then(() => "ended" as const)]),
    240_000,
    "the first approval",
  );
  if (reached === "approval") {
    run1.interrupt();
    first.withdraw();
  }
  const firstOutcome = await withTimeout(run1.done, 120_000, "the interrupt");

  // Run 2: resume the session; approvals are allowed.
  const second = new SmokeHost(false);
  const state = first.checkpoints[first.checkpoints.length - 1] ?? null;
  let secondOutcome: RunOutcome = { kind: "failed", error: { code: "skipped", message: "the first run never asked for an approval", transient: false } };
  if (reached === "approval") {
    const run2 = adapter.start(
      { ...base, budget: { sealMicros: 80_000, spentMicros: first.usageMicros() }, resume: { sessionId: first.sessionId(), state, feedback: null } },
      second,
    );
    second.run = run2;
    secondOutcome = await withTimeout(run2.done, 300_000, "the resumed run");
  }

  const file = path.join(repo, FILE);
  const estimates = [...first.events, ...second.events].flatMap((e) => (e.kind === "usage" ? [e.estimate] : []));
  return {
    provider,
    model,
    version,
    firstOutcome,
    secondOutcome,
    approvals: [
      ...first.approvals.map((a) => ({ run: 1, tool: a.tool, category: a.category, summary: a.summary })),
      ...second.approvals.map((a) => ({ run: 2, tool: a.tool, category: a.category, summary: a.summary })),
    ],
    costMicros: { first: first.usageMicros(), second: second.usageMicros(), total: first.usageMicros() + second.usageMicros() },
    estimate: estimates[0],
    sessionIds: [first.sessionId(), second.sessionId()],
    checkpoints: [state, second.checkpoints[second.checkpoints.length - 1] ?? null],
    fileContent: existsSync(file) ? readFileSync(file, "utf8") : null,
    seconds: Math.round((Date.now() - started) / 1000),
  };
}

export const SMOKE_CONTENT = CONTENT;

/** Prints a report and keeps a copy in the temp folder (aurelhaven-smoke-<provider>.json). */
export function publish(provider: string, report: unknown): void {
  const file = path.join(os.tmpdir(), `aurelhaven-smoke-${provider}.json`);
  writeFileSync(file, JSON.stringify(report, null, 2));
  process.stdout.write(`SMOKE REPORT ${provider} (saved to ${file})\n${JSON.stringify(report, null, 2)}\n`);
}
