import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { currentPlatform, isInside } from "../../security/path-guard.js";
import type { RunHandle, RunHost, RunOutcome, RunRequest } from "../types.js";
import { DEFAULT_FOLLOWUP, type Scenario, type Step } from "./scenarios.js";

type Mode = "main" | "followup";
type PathSeg = number | "onAllow" | "onDeny";

/** Where a resumed session continues: which script and which step. */
interface Checkpoint {
  scenario: string;
  mode: Mode;
  path: PathSeg[];
}

class Aborted extends Error {
  constructor() {
    super("interrupted");
    this.name = "AbortError";
  }
}

function isCheckpoint(v: unknown): v is Checkpoint {
  const c = v as Checkpoint;
  return !!c && typeof c === "object" && (c.mode === "main" || c.mode === "followup") && Array.isArray(c.path);
}

/**
 * Plays a scenario script as if it were a real agent session. Steps make real edits in the
 * worktree, ask for approvals through the host, report usage, and can be interrupted, killed,
 * nudged and resumed from the last checkpoint.
 */
export class ScenarioPlayer implements RunHandle {
  readonly done: Promise<RunOutcome>;
  private readonly abort = new AbortController();
  private nudgeWaiters: Array<() => void> = [];

  constructor(
    private readonly scenario: Scenario,
    private readonly req: RunRequest,
    private readonly host: RunHost,
    private readonly microsPerMana: number,
  ) {
    this.done = this.play();
  }

  send(message: string): void {
    this.host.emit({ kind: "activity", activity: "message", text: `Heard from the player: ${message}` });
    const waiters = this.nudgeWaiters;
    this.nudgeWaiters = [];
    for (const w of waiters) w();
  }

  interrupt(): void {
    this.abort.abort();
  }

  kill(): void {
    this.abort.abort();
  }

  private checkAbort(): void {
    if (this.abort.signal.aborted) throw new Aborted();
  }

  private checkpoint(mode: Mode, p: PathSeg[]): void {
    this.host.checkpoint({ scenario: this.scenario.name, mode, path: p } satisfies Checkpoint);
  }

  private async play(): Promise<RunOutcome> {
    await Promise.resolve();
    const resume = this.req.resume;
    this.host.emit({ kind: "session", sessionId: resume?.sessionId ?? `fake-${this.req.taskId}` });
    let mode: Mode = "main";
    let start: PathSeg[] = [0];
    if (resume?.feedback) {
      mode = "followup";
      this.host.emit({ kind: "activity", activity: "message", text: `Resuming with feedback: ${resume.feedback}` });
    } else if (isCheckpoint(resume?.state)) {
      mode = resume.state.mode;
      start = resume.state.path;
      this.host.emit({ kind: "activity", activity: "system", text: "Resuming the session where it stopped." });
    }
    const steps = mode === "main" ? this.scenario.steps : (this.scenario.followup ?? DEFAULT_FOLLOWUP);
    try {
      const outcome = await this.runBlock(steps, [], start, mode);
      return outcome ?? { kind: "completed", summary: "The fake agent finished its script." };
    } catch (err) {
      if (err instanceof Aborted || this.abort.signal.aborted) return { kind: "interrupted" };
      return { kind: "failed", error: { code: "crash", message: err instanceof Error ? err.message : String(err), transient: false } };
    }
  }

  private async runBlock(steps: Step[], prefix: PathSeg[], resume: PathSeg[] | null, mode: Mode): Promise<RunOutcome | null> {
    const first = resume && typeof resume[0] === "number" ? resume[0] : 0;
    const nested = resume && resume.length > 1 ? resume.slice(1) : null;
    for (let i = first; i < steps.length; i++) {
      this.checkAbort();
      const out = await this.exec(steps[i]!, [...prefix, i], i === first ? nested : null, mode);
      if (out) return out;
      this.checkpoint(mode, [...prefix, i + 1]);
    }
    return null;
  }

  private async exec(step: Step, here: PathSeg[], nested: PathSeg[] | null, mode: Mode): Promise<RunOutcome | null> {
    const host = this.host;
    switch (step.op) {
      case "emit":
        host.emit({ kind: "activity", activity: step.kind, text: step.text });
        return null;
      case "tool_start":
        host.emit({ kind: "tool_start", tool: step.tool, input: step.input, text: step.text ?? step.tool });
        return null;
      case "tool_end":
        host.emit({ kind: "tool_end", tool: step.tool, ok: step.ok, text: step.text });
        return null;
      case "usage": {
        const micros = step.cost_micros ?? Math.round((step.cost_mana ?? 0) * this.microsPerMana);
        host.emit({
          kind: "usage",
          costMicros: micros,
          ...(step.input_tokens !== undefined ? { inputTokens: step.input_tokens } : {}),
          ...(step.output_tokens !== undefined ? { outputTokens: step.output_tokens } : {}),
        });
        return null;
      }
      case "write_file":
        await this.writeFile(step);
        return null;
      case "approval": {
        let branch: "onAllow" | "onDeny";
        let rest: PathSeg[] | null = null;
        if (nested && (nested[0] === "onAllow" || nested[0] === "onDeny")) {
          branch = nested[0];
          rest = nested.slice(1);
        } else {
          const answer = await host.requestApproval({
            tool: step.expect.tool,
            category: step.expect.category,
            input: step.expect.input ?? {},
            ...(step.expect.summary ? { summary: step.expect.summary } : {}),
            ...(step.expect.risk ? { risk: step.expect.risk } : {}),
            ...(step.expect.reason ? { reason: step.expect.reason } : {}),
          });
          this.checkAbort();
          if (answer.cancelled) throw new Aborted();
          branch = answer.decision === "allow" ? "onAllow" : "onDeny";
          host.emit({
            kind: "activity",
            activity: "message",
            text: `${step.expect.tool} was ${answer.decision === "allow" ? "allowed" : "denied"}${answer.message ? `: ${answer.message}` : ""}`,
          });
          this.checkpoint(mode, [...here, branch, 0]);
        }
        return this.runBlock(step[branch], [...here, branch], rest, mode);
      }
      case "delegate": {
        const handle = await host.delegate({
          to: step.to,
          title: step.title,
          prompt: step.prompt,
          size: step.size,
          budgetMana: step.budget_mana,
        });
        host.emit({ kind: "activity", activity: "message", text: `Delegated "${step.title}" as ${handle.taskId}` });
        if (step.wait) {
          const result = await this.raceAbort(handle.wait());
          host.emit({
            kind: "activity",
            activity: "message",
            text: `Sub-task ${handle.taskId} ${result.status}${result.summary ? `: ${result.summary}` : ""}`,
          });
        }
        return null;
      }
      case "rate_limits":
        host.emit({
          kind: "rate_limits",
          windows: step.windows.map((w) => ({
            window: w.window,
            usedPercent: w.used_percent,
            resetsAt: w.resets_in_s === undefined ? null : new Date(host.clock.now() + w.resets_in_s * 1000).toISOString(),
            windowMinutes: w.window_minutes ?? null,
          })),
        });
        return null;
      case "sleep":
        await this.raceAbort(host.clock.sleep(step.ms, this.abort.signal));
        return null;
      case "hang":
        await new Promise<void>((resolve, reject) => {
          const onAbort = () => reject(new Aborted());
          if (this.abort.signal.aborted) onAbort();
          this.abort.signal.addEventListener("abort", onAbort, { once: true });
          if (step.until === "nudge") this.nudgeWaiters.push(resolve);
        });
        return null;
      case "fail":
        return { kind: "failed", error: { code: step.code, message: step.message, transient: step.transient } };
      case "end":
        return { kind: "completed", summary: step.summary };
    }
  }

  private async writeFile(step: Extract<Step, { op: "write_file" }>): Promise<void> {
    const content = step.content.replace("{feedback}", this.req.resume?.feedback ?? "");
    const answer = await this.host.requestApproval({
      tool: "Write",
      category: "write",
      input: { file_path: step.path, content: content.slice(0, 200) },
      summary: `Write ${step.path}`,
    });
    this.checkAbort();
    if (answer.cancelled) throw new Aborted();
    if (answer.decision !== "allow") {
      this.host.emit({ kind: "tool_end", tool: "Write", ok: false, text: `Write ${step.path} denied` });
      return;
    }
    const target = path.resolve(this.req.cwd, step.path);
    if (!isInside(target, this.req.workspaceRoot, currentPlatform())) {
      throw new Error(`the fake agent tried to write outside its worktree: ${step.path}`);
    }
    this.host.emit({ kind: "tool_start", tool: "Write", input: { file_path: step.path }, text: `Write ${step.path}` });
    mkdirSync(path.dirname(target), { recursive: true });
    if (step.append) appendFileSync(target, content);
    else writeFileSync(target, content);
    this.host.emit({ kind: "files_touched", paths: [step.path] });
    this.host.emit({ kind: "tool_end", tool: "Write", ok: true, text: `Wrote ${step.path}` });
  }

  private raceAbort<T>(p: Promise<T>): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const onAbort = () => reject(new Aborted());
      if (this.abort.signal.aborted) {
        onAbort();
        return;
      }
      this.abort.signal.addEventListener("abort", onAbort, { once: true });
      p.then(
        (v) => {
          this.abort.signal.removeEventListener("abort", onAbort);
          resolve(v);
        },
        (e: unknown) => {
          this.abort.signal.removeEventListener("abort", onAbort);
          reject(e instanceof Error ? e : new Error(String(e)));
        },
      );
    });
  }
}
