import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { z } from "zod";
import { formatIssues } from "../../protocol/envelope.js";
import { ApprovalCategory, Risk, TaskSize } from "../../protocol/objects.js";

/**
 * FakeProvider scenario scripts (JSON files in ./scenarios). A task picks its script with a
 * `[fake:<name>]` prefix on the prompt; without one the configured default is used.
 */
export type Step =
  | { op: "emit"; kind: "message" | "system" | "error"; text: string }
  | { op: "tool_start"; tool: string; input?: unknown; text?: string | undefined }
  | { op: "tool_end"; tool: string; ok: boolean; text?: string | undefined }
  | { op: "usage"; cost_mana?: number | undefined; cost_micros?: number | undefined; input_tokens?: number | undefined; output_tokens?: number | undefined }
  | { op: "write_file"; path: string; content: string; append: boolean }
  | {
      op: "approval";
      expect: {
        tool: string;
        category: z.infer<typeof ApprovalCategory>;
        input?: unknown;
        summary?: string | undefined;
        risk?: z.infer<typeof Risk> | undefined;
        reason?: string | undefined;
      };
      onAllow: Step[];
      onDeny: Step[];
    }
  | { op: "delegate"; to: string; title: string; prompt: string; size: z.infer<typeof TaskSize>; budget_mana: number; wait: boolean }
  | { op: "sleep"; ms: number }
  | { op: "hang"; until: "interrupt" | "nudge" }
  | { op: "fail"; code: string; message: string; transient: boolean }
  | { op: "end"; summary: string };

export const StepSchema: z.ZodType<Step> = z.lazy(() =>
  z.discriminatedUnion("op", [
    z.object({ op: z.literal("emit"), kind: z.enum(["message", "system", "error"]).default("message"), text: z.string() }),
    z.object({ op: z.literal("tool_start"), tool: z.string(), input: z.unknown().optional(), text: z.string().optional() }),
    z.object({ op: z.literal("tool_end"), tool: z.string(), ok: z.boolean().default(true), text: z.string().optional() }),
    z.object({
      op: z.literal("usage"),
      cost_mana: z.number().min(0).optional(),
      cost_micros: z.number().int().min(0).optional(),
      input_tokens: z.number().int().min(0).optional(),
      output_tokens: z.number().int().min(0).optional(),
    }),
    z.object({ op: z.literal("write_file"), path: z.string().min(1), content: z.string(), append: z.boolean().default(false) }),
    z.object({
      op: z.literal("approval"),
      expect: z.object({
        tool: z.string(),
        category: ApprovalCategory,
        input: z.unknown().optional(),
        summary: z.string().optional(),
        risk: Risk.optional(),
        reason: z.string().optional(),
      }),
      onAllow: z.array(StepSchema).default([]),
      onDeny: z.array(StepSchema).default([]),
    }),
    z.object({
      op: z.literal("delegate"),
      to: z.string().default("any"),
      title: z.string(),
      prompt: z.string(),
      size: TaskSize.default("S"),
      budget_mana: z.number().positive(),
      wait: z.boolean().default(true),
    }),
    z.object({ op: z.literal("sleep"), ms: z.number().int().min(0) }),
    z.object({ op: z.literal("hang"), until: z.enum(["interrupt", "nudge"]).default("interrupt") }),
    z.object({
      op: z.literal("fail"),
      code: z.string().default("crash"),
      message: z.string().default("the fake agent failed"),
      transient: z.boolean().default(false),
    }),
    z.object({ op: z.literal("end"), summary: z.string().default("The fake agent finished its script.") }),
  ]),
);

export const ScenarioSchema = z.object({
  name: z.string().regex(/^[A-Za-z0-9_-]+$/),
  description: z.string().default(""),
  steps: z.array(StepSchema),
  /** Steps run when the task is sent back with feedback (a resumed session). */
  followup: z.array(StepSchema).optional(),
});
export type Scenario = z.infer<typeof ScenarioSchema>;

export const DEFAULT_FOLLOWUP: Step[] = [
  { op: "emit", kind: "message", text: "Working on the feedback." },
  { op: "write_file", path: "aurelhaven-feedback.md", content: "Feedback applied:\n{feedback}\n", append: true },
  { op: "usage", cost_mana: 2 },
  { op: "end", summary: "Applied the feedback." },
];

const PREFIX = /^\s*\[fake:([A-Za-z0-9_-]+)\]/;

export function scenarioNameFromPrompt(prompt: string): string | null {
  return PREFIX.exec(prompt)?.[1] ?? null;
}

export class ScenarioLibrary {
  private readonly scenarios = new Map<string, Scenario>();

  constructor(dir: string) {
    for (const file of readdirSync(dir).filter((f) => f.endsWith(".json")).sort()) {
      const raw = JSON.parse(readFileSync(path.join(dir, file), "utf8")) as unknown;
      const parsed = ScenarioSchema.safeParse(raw);
      if (!parsed.success) throw new Error(`fake scenario ${file} is invalid: ${formatIssues(parsed.error)}`);
      this.scenarios.set(parsed.data.name, parsed.data);
    }
  }

  get(name: string): Scenario | null {
    return this.scenarios.get(name) ?? null;
  }

  names(): string[] {
    return [...this.scenarios.keys()];
  }

  add(scenario: Scenario): void {
    this.scenarios.set(scenario.name, ScenarioSchema.parse(scenario));
  }
}
