import os from "node:os";
import { srcPath } from "../../paths.js";
import { fail } from "../../protocol/errors.js";
import type { ModelInfo, ProviderInfo } from "../../protocol/objects.js";
import { harnessEnv } from "../common/env.js";
import { resolvePi, type Launch } from "../common/exec.js";
import { HarnessProcess, runCapture } from "../common/process.js";
import { asNumber, asString, isPlainObject, type HarnessDeps } from "../common/support.js";
import type { ProviderAdapter, RunHandle, RunHost, RunRequest } from "../types.js";
import { PiRun } from "./run.js";

type BillingHint = ProviderInfo["billing_hint"];

const PROBE_TIMEOUT_MS = 30_000;

export interface PiAdapterOptions {
  /** Path to the gate extension (aurelhaven-gate.ts). */
  extensionPath?: string;
  /** Extra pi arguments for every launch (tests load a scripted provider with `-e`). */
  extraArgs?: string[];
}

interface PiModel {
  provider: string;
  id: string;
  name: string;
  cost: { input: number; output: number } | null;
}

/**
 * pi (the coding agent `@earendil-works/pi-coding-agent`) for every model provider other than
 * Claude Code and Codex, driven through `pi --mode rpc`.
 */
export class PiAdapter implements ProviderAdapter {
  readonly id = "pi" as const;
  private billing: BillingHint = "unknown";
  private readonly extensionPath: string;
  private readonly extraArgs: string[];

  constructor(
    private readonly deps: HarnessDeps,
    opts: PiAdapterOptions = {},
  ) {
    this.extensionPath = opts.extensionPath ?? srcPath("providers", "pi", "aurelhaven-gate.ts");
    this.extraArgs = opts.extraArgs ?? [];
  }

  async probe(): Promise<ProviderInfo> {
    const res = resolvePi(this.deps.env);
    if (!res.launch) return { id: this.id, installed: false, logged_in: false, billing_hint: "unknown", message: res.problem ?? "pi was not found" };
    try {
      const env = harnessEnv(this.deps.env, { PI_SKIP_VERSION_CHECK: "1" });
      const ver = await runCapture(res.launch, ["--version"], { env, timeoutMs: PROBE_TIMEOUT_MS });
      const version = /(\d+\.\d+\.\d+)/.exec(ver.stdout)?.[1] ?? null;
      if (!version) {
        const why = ver.timedOut ? "timed out" : ver.error ?? `exit code ${ver.code}`;
        return { id: this.id, installed: false, logged_in: false, billing_hint: "unknown", message: `pi did not report its version (${why})` };
      }
      const models = (await this.queryModels(res.launch)) ?? [];
      const providers = [...new Set(models.map((m) => m.provider))];
      if (providers.length === 0) {
        this.billing = "unknown";
        return {
          id: this.id,
          installed: true,
          version,
          logged_in: false,
          billing_hint: "unknown",
          message: `pi ${version} has no provider credentials: set a provider API key (for example OPENROUTER_API_KEY) or sign in with pi's /login`,
        };
      }
      this.billing = await this.billingFor(res.launch, env, providers);
      return {
        id: this.id,
        installed: true,
        version,
        logged_in: true,
        billing_hint: this.billing,
        message: `pi ${version}, credentials for ${providers.slice(0, 6).join(", ")}${providers.length > 6 ? ", ..." : ""}`,
      };
    } catch (err) {
      return { id: this.id, installed: false, logged_in: false, billing_hint: "unknown", message: `pi probe failed: ${String(err)}` };
    }
  }

  /**
   * `pi auth check --json --no-refresh` for the providers with models. It prints only a status
   * and the credential type (never the credential without --credentials): OAuth sign-ins are
   * subscriptions, keys are API billing.
   */
  private async billingFor(launch: Launch, env: Record<string, string | undefined>, providers: string[]): Promise<BillingHint> {
    const kinds = new Set<string>();
    for (const provider of providers.slice(0, 4)) {
      const r = await runCapture(launch, ["auth", "check", "--provider", provider, "--json", "--no-refresh"], { env, timeoutMs: PROBE_TIMEOUT_MS });
      try {
        const status = JSON.parse(r.stdout) as Record<string, unknown>;
        if (status.status === "ready" && typeof status.authType === "string") kinds.add(status.authType);
      } catch {
        // an older pi without auth check: leave the hint unknown
      }
    }
    if (kinds.size === 1 && kinds.has("oauth")) return "subscription";
    if (kinds.size > 0 && [...kinds].every((k) => k === "api_key")) return "api_key";
    return "unknown";
  }

  async listModels(): Promise<ModelInfo[]> {
    const res = resolvePi(this.deps.env);
    const models = res.launch ? await this.queryModels(res.launch) : null;
    return (models ?? []).map((m, i) => ({
      id: `${m.provider}/${m.id}`,
      label: `${m.name} (${m.provider})`,
      default: i === 0,
      ...(m.cost ? { cost_hint: `$${m.cost.input.toFixed(2)} in / $${m.cost.output.toFixed(2)} out per 1M tokens` } : {}),
    }));
  }

  /** `get_available_models` over RPC: the models whose provider has credentials. No model call. */
  private queryModels(launch: Launch): Promise<PiModel[] | null> {
    return new Promise((resolve) => {
      let settled = false;
      const finish = (models: PiModel[] | null) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        void proc.stop(3_000);
        resolve(models);
      };
      const proc = new HarnessProcess(
        launch,
        ["--mode", "rpc", "--no-session", "--no-approve", "--no-tools", "--no-context-files", "--no-skills", "--no-prompt-templates", ...this.extraArgs],
        {
          cwd: os.tmpdir(),
          env: harnessEnv(this.deps.env, { PI_SKIP_VERSION_CHECK: "1" }),
          onRecord: (r) => {
            if (!isPlainObject(r) || r.type !== "response" || r.id !== "models") return;
            const data = isPlainObject(r.data) ? r.data : {};
            const list = Array.isArray(data.models) ? data.models.filter(isPlainObject) : null;
            finish(
              list
                ? list.map((m) => {
                    const cost = isPlainObject(m.cost) ? m.cost : null;
                    return {
                      provider: String(m.provider),
                      id: String(m.id),
                      name: asString(m.name) ?? String(m.id),
                      cost: cost ? { input: asNumber(cost.input) ?? 0, output: asNumber(cost.output) ?? 0 } : null,
                    };
                  })
                : null,
            );
          },
        },
      );
      const timer = setTimeout(() => finish(null), PROBE_TIMEOUT_MS);
      void proc.exited.then(() => finish(null));
      proc.send({ id: "models", type: "get_available_models" });
    });
  }

  start(req: RunRequest, host: RunHost): RunHandle {
    const res = resolvePi(this.deps.env);
    if (!res.launch) throw fail.provider(res.problem ?? "pi was not found");
    return new PiRun(req, host, {
      launch: res.launch,
      deps: this.deps,
      extensionPath: this.extensionPath,
      extraArgs: this.extraArgs,
      estimate: this.billing === "subscription" ? true : undefined,
    });
  }
}
