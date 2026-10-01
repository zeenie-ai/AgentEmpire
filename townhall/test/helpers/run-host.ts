import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { SystemClock } from "../../src/core/clock.js";
import { Economy } from "../../src/core/economy.js";
import { defaultEconomyPath, defaultPricingPath } from "../../src/paths.js";
import type { EconomyTools } from "../../src/providers/common/capabilities.js";
import { Pricing } from "../../src/providers/common/pricing.js";
import type { HarnessDeps } from "../../src/providers/common/support.js";
import { framingNames } from "../../src/providers/real.js";
import type {
  ApprovalAnswer,
  ApprovalRequest,
  DelegateHandle,
  DelegateRequest,
  PartyStatus,
  RunEvent,
  RunHost,
  RunOutcome,
  RunRequest,
} from "../../src/providers/types.js";

export const FIXTURES = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "fixtures");

/** A RunHost that records everything and answers approvals with `decide`. */
export class MockHost implements RunHost {
  readonly taskId: string;
  readonly clock = new SystemClock();
  readonly events: RunEvent[] = [];
  readonly approvals: ApprovalRequest[] = [];
  readonly checkpoints: unknown[] = [];
  decide: (req: ApprovalRequest) => ApprovalAnswer | Promise<ApprovalAnswer> = () => ({ decision: "allow" });
  private readonly waiters: Array<{ pred: (e: RunEvent) => boolean; resolve: () => void }> = [];
  private readonly approvalWaiters: Array<() => void> = [];

  constructor(taskId = "tsk_test") {
    this.taskId = taskId;
  }

  emit(event: RunEvent): void {
    this.events.push(event);
    for (const w of [...this.waiters]) {
      if (w.pred(event)) {
        this.waiters.splice(this.waiters.indexOf(w), 1);
        w.resolve();
      }
    }
  }

  async requestApproval(req: ApprovalRequest): Promise<ApprovalAnswer> {
    this.approvals.push(req);
    for (const w of this.approvalWaiters.splice(0)) w();
    return this.decide(req);
  }

  /** Party leads: what was delegated, the party as partyStatus reports it, and how waits end. */
  readonly delegations: DelegateRequest[] = [];
  party: PartyStatus = { sealLeftMana: 0, subtasks: [] };
  onDelegate: (req: DelegateRequest) => DelegateHandle | Promise<DelegateHandle> = () => {
    throw new Error("parties are not part of these tests");
  };
  onWait: (taskIds: string[] | null, timeoutMs: number) => PartyStatus | Promise<PartyStatus> = () => this.party;

  async delegate(req: DelegateRequest): Promise<DelegateHandle> {
    this.delegations.push(req);
    return this.onDelegate(req);
  }

  partyStatus(): PartyStatus {
    return this.party;
  }

  async waitSubtasks(taskIds: string[] | null, timeoutMs: number): Promise<PartyStatus> {
    return this.onWait(taskIds, timeoutMs);
  }

  checkpoint(state: unknown): void {
    this.checkpoints.push(JSON.parse(JSON.stringify(state)) as unknown);
  }

  lastCheckpoint<T>(): T {
    return this.checkpoints[this.checkpoints.length - 1] as T;
  }

  /** Resolves once an event matching `pred` has been emitted (including earlier ones). */
  waitFor(pred: (e: RunEvent) => boolean, timeoutMs = 20_000): Promise<void> {
    if (this.events.some(pred)) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("timed out waiting for a run event")), timeoutMs);
      this.waiters.push({
        pred,
        resolve: () => {
          clearTimeout(timer);
          resolve();
        },
      });
    });
  }

  /** Resolves once `count` approvals have been requested. */
  async waitApprovals(count: number, timeoutMs = 20_000): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (this.approvals.length < count) {
      if (Date.now() > deadline) throw new Error(`timed out waiting for ${count} approvals`);
      await new Promise<void>((resolve) => {
        this.approvalWaiters.push(resolve);
        setTimeout(resolve, 200);
      });
    }
  }

  usageMicros(): number {
    return this.events.reduce((sum, e) => sum + (e.kind === "usage" ? e.costMicros : 0), 0);
  }

  texts(kind: RunEvent["kind"]): string[] {
    return this.events.flatMap((e) => (e.kind === kind && "text" in e && typeof e.text === "string" ? [e.text] : []));
  }
}

export function testDeps(dataDir: string, env: Record<string, string | undefined>): HarnessDeps {
  const econ = Economy.load(defaultEconomyPath());
  return {
    env,
    dataDir,
    tools: econ.data.tools as unknown as EconomyTools,
    names: framingNames(econ.data),
    pricing: Pricing.load(defaultPricingPath()),
  };
}

export function runRequest(cwd: string, overrides: Partial<RunRequest> = {}): RunRequest {
  return {
    taskId: "tsk_test",
    agentId: "agt_test",
    attempt: 1,
    provider: "claude",
    model: "haiku",
    role: "artificer",
    size: "S",
    cwd,
    workspaceRoot: cwd,
    title: "Greet the town",
    prompt: "Write hello.txt",
    acceptance: ["hello.txt exists"],
    instructions: "Be careful.",
    approvalMode: "trusted_edits",
    tools: ["lectern", "quillworks"],
    waygates: [],
    budget: { sealMicros: 400_000, spentMicros: 0 },
    resume: null,
    party: null,
    depth: 0,
    ...overrides,
  };
}

/** Writes a JSON fixture file and returns its path. */
export function writeJson(dir: string, name: string, value: unknown): string {
  mkdirSync(dir, { recursive: true });
  const file = path.join(dir, name);
  writeFileSync(file, JSON.stringify(value, null, 2));
  return file;
}

/** Reads a JSON-lines log written by a fake CLI. */
export function readLog(file: string): Array<Record<string, any>> {
  try {
    return readFileSync(file, "utf8")
      .split("\n")
      .filter((l) => l.trim())
      .map((l) => JSON.parse(l) as Record<string, any>);
  } catch {
    return [];
  }
}

/** Races a run's outcome against a timeout. */
export function within<T extends RunOutcome>(p: Promise<T>, ms = 30_000): Promise<T> {
  return Promise.race([p, new Promise<T>((_, reject) => setTimeout(() => reject(new Error("the run did not finish in time")), ms))]);
}
