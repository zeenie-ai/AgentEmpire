import type { EventBus } from "../core/events.js";
import { fail } from "../protocol/errors.js";
import type { ModelInfo, Provider, ProviderInfo } from "../protocol/objects.js";
import type { ProviderAdapter } from "./types.js";

/** Holds one adapter per provider id and the latest probe results. */
export class ProviderRegistry {
  private readonly infos = new Map<Provider, ProviderInfo>();

  constructor(
    private readonly adapters: Record<Provider, ProviderAdapter>,
    private readonly bus: EventBus,
  ) {}

  get(id: Provider): ProviderAdapter {
    const a = this.adapters[id];
    if (!a) throw fail.provider(`unknown provider ${id}`);
    return a;
  }

  async refresh(): Promise<ProviderInfo[]> {
    const before = JSON.stringify(this.cached());
    for (const id of Object.keys(this.adapters) as Provider[]) {
      try {
        this.infos.set(id, await this.adapters[id].probe());
      } catch (err) {
        this.infos.set(id, {
          id,
          installed: false,
          logged_in: false,
          billing_hint: "unknown",
          message: err instanceof Error ? err.message : String(err),
        });
      }
    }
    const after = this.cached();
    if (JSON.stringify(after) !== before) this.bus.emit("providers_updated", { providers: after }, "providers");
    return after;
  }

  cached(): ProviderInfo[] {
    return (Object.keys(this.adapters) as Provider[]).map(
      (id) => this.infos.get(id) ?? { id, installed: false, logged_in: false, billing_hint: "unknown", message: "not probed yet" },
    );
  }

  isOnline(id: Provider): boolean {
    const info = this.infos.get(id);
    return !!info && info.installed && info.logged_in;
  }

  async listModels(id: Provider): Promise<ModelInfo[]> {
    return this.get(id).listModels();
  }
}
