import { fail } from "../../protocol/errors.js";
import type { ModelInfo, ProviderInfo } from "../../protocol/objects.js";
import type { ProviderAdapter, RunHandle } from "../types.js";

const PHASE_4 = "The pi adapter is being built in Phase 4";

/** Placeholder until the pi RPC adapter lands. */
export class PiAdapter implements ProviderAdapter {
  readonly id = "pi" as const;

  async probe(): Promise<ProviderInfo> {
    return { id: this.id, installed: false, logged_in: false, billing_hint: "unknown", message: PHASE_4 };
  }

  async listModels(): Promise<ModelInfo[]> {
    return [];
  }

  start(): RunHandle {
    throw fail.provider(PHASE_4);
  }
}
