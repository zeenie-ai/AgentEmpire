import type { ModelInfo, Provider, ProviderInfo } from "../../protocol/objects.js";
import type { ProviderAdapter, RunHandle, RunHost, RunRequest } from "../types.js";
import { ScenarioPlayer } from "./player.js";
import { scenarioNameFromPrompt, type ScenarioLibrary } from "./scenarios.js";

export interface FakeProviderOptions {
  library: ScenarioLibrary;
  defaultScenario: string;
  microsPerMana: number;
  env?: Record<string, string | undefined>;
}

/**
 * Scripted stand-in for Claude and Codex (Phase 1). Each run plays a JSON scenario from
 * `src/providers/fake/scenarios/`, chosen by a `[fake:<name>]` prefix on the task prompt
 * (for example "[fake:full_loop] Add a greeting"), else the configured default scenario.
 */
export class FakeProvider implements ProviderAdapter {
  constructor(
    readonly id: Provider,
    private readonly opts: FakeProviderOptions,
  ) {}

  async probe(): Promise<ProviderInfo> {
    const env = this.opts.env ?? process.env;
    const hasKey = this.id === "claude" ? !!env.ANTHROPIC_API_KEY : !!(env.OPENAI_API_KEY || env.CODEX_API_KEY);
    return {
      id: this.id,
      installed: true,
      version: "fake-1.0",
      logged_in: true,
      billing_hint: hasKey ? "api_key" : "subscription",
      message: "FakeProvider: scripted runs (Phase 1)",
    };
  }

  async listModels(): Promise<ModelInfo[]> {
    return [
      { id: `fake-${this.id}`, label: `Fake ${this.id === "claude" ? "Claude" : "Codex"} (scripted)`, default: true, cost_hint: "free" },
    ];
  }

  start(req: RunRequest, host: RunHost): RunHandle {
    const name = scenarioNameFromPrompt(req.prompt) ?? this.opts.defaultScenario;
    const scenario = this.opts.library.get(name);
    if (!scenario) throw new Error(`unknown fake scenario "${name}"; known: ${this.opts.library.names().join(", ")}`);
    return new ScenarioPlayer(scenario, req, host, this.opts.microsPerMana);
  }
}
