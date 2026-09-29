import { readFileSync } from "node:fs";
import { z } from "zod";

const PriceEntry = z.looseObject({
  provider: z.string(),
  input: z.number().min(0),
  cache_write: z.number().min(0),
  cache_read: z.number().min(0),
  output: z.number().min(0),
  estimated: z.array(z.string()).optional(),
});
export type PriceEntry = z.infer<typeof PriceEntry>;

const PricingFile = z.looseObject({
  unit: z.string().optional(),
  models: z.record(z.string(), PriceEntry),
  aliases: z.record(z.string(), z.string()).default({}),
  fallback_by_provider: z.record(z.string(), z.string()).default({}),
});
type PricingData = z.infer<typeof PricingFile>;

/** Token counts for one request or a sum of requests. `input` excludes cached input. */
export interface TokenUsage {
  input: number;
  cacheRead: number;
  cacheWrite: number;
  output: number;
}

export function emptyUsage(): TokenUsage {
  return { input: 0, cacheRead: 0, cacheWrite: 0, output: 0 };
}

export interface PriceMatch {
  id: string;
  entry: PriceEntry;
  /** True when the model was unknown and the provider's fallback price was used. */
  fallback: boolean;
}

/** protocol/pricing.json: USD per million tokens, by model. */
export class Pricing {
  constructor(private readonly data: PricingData) {}

  static load(file: string): Pricing {
    const parsed = PricingFile.safeParse(JSON.parse(readFileSync(file, "utf8")) as unknown);
    if (!parsed.success) throw new Error(`pricing.json is invalid: ${parsed.error.issues[0]?.message ?? "bad shape"}`);
    return new Pricing(parsed.data);
  }

  static empty(): Pricing {
    return new Pricing({ models: {}, aliases: {}, fallback_by_provider: {} });
  }

  /** Normalises a harness model name: case, the "[1m]" context suffix, dates, aliases. */
  canonical(model: string): string | null {
    let id = model.trim().toLowerCase().replace(/\[[^\]]*\]$/, "");
    if (this.data.models[id]) return id;
    if (this.data.aliases[id]) return this.data.aliases[id]!;
    id = id.replace(/-\d{8}$/, "");
    if (this.data.models[id]) return id;
    if (this.data.aliases[id]) return this.data.aliases[id]!;
    return null;
  }

  match(provider: string, model: string): PriceMatch | null {
    const id = this.canonical(model);
    if (id && this.data.models[id]) return { id, entry: this.data.models[id]!, fallback: false };
    const fallbackId = this.data.fallback_by_provider[provider];
    if (fallbackId && this.data.models[fallbackId]) return { id: fallbackId, entry: this.data.models[fallbackId]!, fallback: true };
    return null;
  }

  /** Cost in USD of the given tokens, or null when no price is known for the provider. */
  costUsd(provider: string, model: string, usage: TokenUsage): number | null {
    const m = this.match(provider, model);
    if (!m) return null;
    const e = m.entry;
    const usd =
      (Math.max(0, usage.input) * e.input +
        Math.max(0, usage.cacheRead) * e.cache_read +
        Math.max(0, usage.cacheWrite) * e.cache_write +
        Math.max(0, usage.output) * e.output) /
      1_000_000;
    return usd;
  }

  /** A short price label for list_models, for example "$1.00 in / $5.00 out per 1M tokens". */
  costHint(provider: string, model: string): string | undefined {
    const m = this.match(provider, model);
    if (!m || m.fallback) return undefined;
    const f = (n: number) => `$${n.toFixed(2)}`;
    return `${f(m.entry.input)} in / ${f(m.entry.output)} out per 1M tokens`;
  }

  /** Model ids priced for a provider, cheapest input first. */
  models(provider: string): string[] {
    return Object.entries(this.data.models)
      .filter(([, e]) => e.provider === provider)
      .sort((a, b) => a[1].input + a[1].output - (b[1].input + b[1].output))
      .map(([id]) => id);
  }
}

export function usdToMicros(usd: number): number {
  return Math.max(0, Math.round(usd * 1_000_000));
}

/**
 * Turns a running USD total (Claude Code's `total_cost_usd`) into charges. Each update charges
 * the growth since the last one; a drop (a restarted counter) charges nothing and rebases.
 */
export class RunningTotal {
  private last: number;

  constructor(baselineUsd = 0) {
    this.last = baselineUsd;
  }

  get value(): number {
    return this.last;
  }

  /** Returns the new spend in micro-USD since the previous total. */
  update(totalUsd: number): number {
    if (!Number.isFinite(totalUsd) || totalUsd < 0) return 0;
    const delta = totalUsd - this.last;
    this.last = totalUsd;
    return delta > 0 ? usdToMicros(delta) : 0;
  }
}
