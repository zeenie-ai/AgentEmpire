import type { EconomyData } from "../core/economy.js";
import type { Logger } from "../log.js";
import type { Provider } from "../protocol/objects.js";
import type { Redactor } from "../security/redact.js";
import { ClaudeCodeAdapter } from "./claude/adapter.js";
import { CodexCliAdapter } from "./codex/adapter.js";
import type { EconomyTools } from "./common/capabilities.js";
import type { Env } from "./common/exec.js";
import { Pricing } from "./common/pricing.js";
import type { FramingNames } from "./common/prompt.js";
import type { HarnessDeps } from "./common/support.js";
import { PiAdapter } from "./pi/adapter.js";
import type { ProviderAdapter } from "./types.js";

/** Role and size names from economy.json for the task framing. */
export function framingNames(data: EconomyData): FramingNames {
  const roles: FramingNames["roles"] = {};
  for (const [id, r] of Object.entries(data.roles)) roles[id] = { name: r.name, plain: typeof r.plain === "string" ? r.plain : undefined };
  const sizes: FramingNames["sizes"] = {};
  const rawSizes = (data as Record<string, unknown>).sizes;
  if (rawSizes && typeof rawSizes === "object") {
    for (const [id, s] of Object.entries(rawSizes as Record<string, { name?: unknown }>)) {
      if (typeof s?.name === "string") sizes[id] = { name: s.name };
    }
  }
  return { roles, sizes };
}

export interface RealAdapterOptions {
  econ: EconomyData;
  dataDir: string;
  pricingPath: string;
  env?: Env;
  log?: Logger;
  redactor?: Redactor;
}

export function harnessDeps(opts: RealAdapterOptions): HarnessDeps {
  let pricing: Pricing;
  try {
    pricing = Pricing.load(opts.pricingPath);
  } catch (err) {
    opts.log?.warn({ file: opts.pricingPath, err: String(err) }, "pricing.json could not be loaded; Codex usage will not be priced");
    pricing = Pricing.empty();
  }
  return {
    env: opts.env ?? process.env,
    dataDir: opts.dataDir,
    tools: opts.econ.tools as unknown as EconomyTools,
    names: framingNames(opts.econ),
    pricing,
    log: opts.log,
    redactor: opts.redactor,
  };
}

/** The real harness adapters: Claude Code, the Codex CLI and pi. */
export function realAdapters(deps: HarnessDeps): Record<Provider, ProviderAdapter> {
  return {
    claude: new ClaudeCodeAdapter(deps),
    codex: new CodexCliAdapter(deps),
    pi: new PiAdapter(deps),
  };
}
