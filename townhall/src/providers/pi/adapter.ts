import { fail } from "../../protocol/errors.js";
import type { ModelInfo, ProviderInfo } from "../../protocol/objects.js";
import type { HarnessDeps } from "../common/support.js";
import type { ProviderAdapter, RunHandle } from "../types.js";

const PENDING = "The pi adapter is being built in Phase 4";

/** Placeholder while the RPC adapter is written. */
export class PiAdapter implements ProviderAdapter {
  readonly id = "pi" as const;

  constructor(readonly deps: HarnessDeps) {}

  async probe(): Promise<ProviderInfo> {
    return { id: this.id, installed: false, logged_in: false, billing_hint: "unknown", message: PENDING };
  }

  async listModels(): Promise<ModelInfo[]> {
    return [];
  }

  start(): RunHandle {
    throw fail.provider(PENDING);
  }
}
