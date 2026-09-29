import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { srcPath } from "../../paths.js";
import { fail } from "../../protocol/errors.js";
import type { ModelInfo, ProviderInfo } from "../../protocol/objects.js";

type BillingHint = ProviderInfo["billing_hint"];
import { harnessEnv } from "../common/env.js";
import { envValue, resolveClaude, type Launch } from "../common/exec.js";
import { HarnessProcess, runCapture } from "../common/process.js";
import { asString, isPlainObject, type HarnessDeps } from "../common/support.js";
import type { ProviderAdapter, RunHandle, RunHost, RunRequest } from "../types.js";
import { ClaudeRun } from "./run.js";

const PROBE_TIMEOUT_MS = 20_000;
/** Claude Code restores a resumed session's cost total from this version on. */
const COST_RESTORE_VERSION = [2, 1, 277];

export function compareVersions(a: string, b: number[]): number {
  const parts = a.split(".").map((n) => Number.parseInt(n, 10) || 0);
  for (let i = 0; i < b.length; i++) {
    const d = (parts[i] ?? 0) - b[i]!;
    if (d !== 0) return d;
  }
  return 0;
}

interface ClaudeModel {
  value: string;
  resolvedModel?: string;
  displayName?: string;
  description?: string;
}

/**
 * Claude Code, driven headless: `claude -p` with stream-json input and output. Permission
 * prompts go to the Town Hall through `--permission-prompt-tool` (see run.ts).
 */
export class ClaudeCodeAdapter implements ProviderAdapter {
  readonly id = "claude" as const;
  private version: string | null = null;
  private billing: BillingHint = "unknown";

  constructor(
    private readonly deps: HarnessDeps,
    private readonly approvalScript = srcPath("providers", "claude", "approval-mcp.mjs"),
  ) {}

  private resolve(): Launch | null {
    return resolveClaude(this.deps.env).launch;
  }

  async probe(): Promise<ProviderInfo> {
    const res = resolveClaude(this.deps.env);
    if (!res.launch) {
      return { id: this.id, installed: false, logged_in: false, billing_hint: "unknown", message: res.problem ?? "Claude Code was not found" };
    }
    try {
      const env = harnessEnv(this.deps.env);
      const ver = await runCapture(res.launch, ["--version"], { env, timeoutMs: PROBE_TIMEOUT_MS });
      const version = /(\d+\.\d+\.\d+)/.exec(ver.stdout)?.[1] ?? null;
      if (!version) {
        const why = ver.timedOut ? "timed out" : ver.error ?? `exit code ${ver.code}`;
        return { id: this.id, installed: false, logged_in: false, billing_hint: "unknown", message: `Claude Code did not report its version (${why})` };
      }
      this.version = version;
      const auth = await this.authStatus(res.launch, env);
      this.billing = auth.billing;
      return {
        id: this.id,
        installed: true,
        version,
        logged_in: auth.loggedIn,
        billing_hint: auth.billing,
        message: auth.loggedIn ? `Claude Code ${version}, ${auth.describe}` : `Claude Code ${version} is not signed in: run "claude auth login"`,
      };
    } catch (err) {
      return { id: this.id, installed: false, logged_in: false, billing_hint: "unknown", message: `Claude Code probe failed: ${String(err)}` };
    }
  }

  /** `claude auth status --json` (documented); falls back to credential presence. Never prints secrets. */
  private async authStatus(launch: Launch, env: Record<string, string | undefined>): Promise<{ loggedIn: boolean; billing: BillingHint; describe: string }> {
    const r = await runCapture(launch, ["auth", "status", "--json"], { env, timeoutMs: PROBE_TIMEOUT_MS });
    try {
      const status = JSON.parse(r.stdout) as Record<string, unknown>;
      const loggedIn = status.loggedIn === true;
      const subscription = asString(status.subscriptionType);
      const method = asString(status.authMethod) ?? "";
      if (subscription) return { loggedIn, billing: "subscription", describe: `signed in with a Claude ${subscription} subscription` };
      if (/api|console|key/i.test(method) || envValue(this.deps.env, "ANTHROPIC_API_KEY")) {
        return { loggedIn, billing: "api_key", describe: "signed in with an API key" };
      }
      return { loggedIn, billing: "unknown", describe: method ? `signed in (${method})` : "signed in" };
    } catch {
      // Older CLIs: look for credentials without reading them.
      if (envValue(this.deps.env, "ANTHROPIC_API_KEY")) return { loggedIn: true, billing: "api_key", describe: "using ANTHROPIC_API_KEY" };
      if (envValue(this.deps.env, "CLAUDE_CODE_OAUTH_TOKEN")) return { loggedIn: true, billing: "subscription", describe: "using CLAUDE_CODE_OAUTH_TOKEN" };
      const configDir = envValue(this.deps.env, "CLAUDE_CONFIG_DIR") ?? path.join(os.homedir(), ".claude");
      if (existsSync(path.join(configDir, ".credentials.json"))) return { loggedIn: true, billing: "subscription", describe: "signed in" };
      return { loggedIn: false, billing: "unknown", describe: "not signed in" };
    }
  }

  async listModels(): Promise<ModelInfo[]> {
    const launch = this.resolve();
    const models = launch ? await this.queryModels(launch).catch(() => null) : null;
    if (!models || models.length === 0) return this.staticModels();
    return models.map((m) => {
      const hint = this.deps.pricing.costHint("claude", m.resolvedModel ?? m.value);
      return {
        id: m.value,
        label: m.description ? `${m.displayName ?? m.value}: ${m.description}` : (m.displayName ?? m.value),
        default: m.value === "default",
        ...(hint ? { cost_hint: hint } : {}),
      };
    });
  }

  private staticModels(): ModelInfo[] {
    return ["opus", "sonnet", "haiku"].map((id, i) => {
      const hint = this.deps.pricing.costHint("claude", id);
      return { id, label: id[0]!.toUpperCase() + id.slice(1), default: i === 0, ...(hint ? { cost_hint: hint } : {}) };
    });
  }

  /** Asks Claude Code for its model list with the documented `initialize` control request; no model call. */
  private queryModels(launch: Launch): Promise<ClaudeModel[] | null> {
    return new Promise((resolve) => {
      let settled = false;
      const finish = (models: ClaudeModel[] | null) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        void proc.stop(3_000);
        resolve(models);
      };
      const proc = new HarnessProcess(
        launch,
        ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--setting-sources", "", "--strict-mcp-config", "--tools", ""],
        {
          cwd: os.tmpdir(),
          env: harnessEnv(this.deps.env),
          onRecord: (r) => {
            if (!isPlainObject(r) || r.type !== "control_response" || !isPlainObject(r.response)) return;
            const body = isPlainObject(r.response.response) ? r.response.response : null;
            const list = Array.isArray(body?.models) ? (body.models as unknown[]) : null;
            finish(
              list
                ? list.filter(isPlainObject).map((m) => ({
                    value: String(m.value),
                    ...(typeof m.resolvedModel === "string" ? { resolvedModel: m.resolvedModel } : {}),
                    ...(typeof m.displayName === "string" ? { displayName: m.displayName } : {}),
                    ...(typeof m.description === "string" ? { description: m.description } : {}),
                  }))
                : null,
            );
          },
        },
      );
      const timer = setTimeout(() => finish(null), PROBE_TIMEOUT_MS);
      void proc.exited.then(() => finish(null));
      proc.send({ type: "control_request", request_id: "aurelhaven-models", request: { subtype: "initialize" } });
    });
  }

  start(req: RunRequest, host: RunHost): RunHandle {
    const res = resolveClaude(this.deps.env);
    if (!res.launch) throw fail.provider(res.problem ?? "Claude Code was not found");
    return new ClaudeRun(req, host, {
      launch: res.launch,
      deps: this.deps,
      approvalScript: this.approvalScript,
      restoresCostOnResume: this.version === null || compareVersions(this.version, COST_RESTORE_VERSION) >= 0,
      estimate: this.billing === "subscription" ? true : undefined,
    });
  }
}
