import os from "node:os";
import { fail } from "../../protocol/errors.js";
import type { ModelInfo, ProviderInfo } from "../../protocol/objects.js";
import { DAEMON_VERSION } from "../../protocol/version.js";
import { harnessEnv } from "../common/env.js";
import { resolveCodex, type Launch } from "../common/exec.js";
import { HarnessProcess, runCapture } from "../common/process.js";
import { asString, isPlainObject, type HarnessDeps } from "../common/support.js";
import type { ProviderAdapter, RunHandle, RunHost, RunRequest } from "../types.js";
import { RpcClient, RpcError } from "./rpc.js";
import { CodexRun } from "./run.js";

type BillingHint = ProviderInfo["billing_hint"];

const PROBE_TIMEOUT_MS = 20_000;

interface CodexModel {
  id: string;
  displayName?: string;
  description?: string;
  hidden?: boolean;
  isDefault?: boolean;
}

/**
 * The Codex CLI through `codex app-server` (JSON-RPC over stdio), spawned as the native binary
 * from its platform package (docs/spikes.md S2).
 */
export class CodexCliAdapter implements ProviderAdapter {
  readonly id = "codex" as const;
  private billing: BillingHint = "unknown";

  constructor(private readonly deps: HarnessDeps) {}

  async probe(): Promise<ProviderInfo> {
    const res = resolveCodex(this.deps.env);
    if (!res.launch) {
      return { id: this.id, installed: false, logged_in: false, billing_hint: "unknown", message: res.problem ?? "Codex was not found" };
    }
    try {
      const env = harnessEnv(this.deps.env);
      const ver = await runCapture(res.launch, ["--version"], { env, timeoutMs: PROBE_TIMEOUT_MS });
      const version = /(\d+\.\d+\.\d+(?:-[\w.]+)?)/.exec(ver.stdout)?.[1] ?? null;
      if (!version) {
        const why = ver.timedOut ? "timed out" : ver.error ?? `exit code ${ver.code}`;
        return { id: this.id, installed: false, logged_in: false, billing_hint: "unknown", message: `Codex did not report its version (${why})` };
      }
      // `codex login status` exits 0 when signed in. Only its wording is read, never printed.
      const login = await runCapture(res.launch, ["login", "status"], { env, timeoutMs: PROBE_TIMEOUT_MS });
      const text = `${login.stdout}\n${login.stderr}`;
      const loggedIn = login.code === 0 && /logged in/i.test(text);
      this.billing = !loggedIn ? "unknown" : /chatgpt/i.test(text) ? "subscription" : /api key/i.test(text) ? "api_key" : "unknown";
      const how = this.billing === "subscription" ? "signed in with ChatGPT" : this.billing === "api_key" ? "signed in with an API key" : "signed in";
      return {
        id: this.id,
        installed: true,
        version,
        logged_in: loggedIn,
        billing_hint: this.billing,
        message: loggedIn ? `Codex ${version}, ${how}` : `Codex ${version} is not signed in: run "codex login"`,
      };
    } catch (err) {
      return { id: this.id, installed: false, logged_in: false, billing_hint: "unknown", message: `Codex probe failed: ${String(err)}` };
    }
  }

  async listModels(): Promise<ModelInfo[]> {
    const res = resolveCodex(this.deps.env);
    const models = res.launch ? await this.queryModels(res.launch).catch(() => null) : null;
    if (!models || models.length === 0) {
      return this.deps.pricing.models("codex").map((id, i) => {
        const hint = this.deps.pricing.costHint("codex", id);
        return { id, label: id, default: i === 0, ...(hint ? { cost_hint: hint } : {}) };
      });
    }
    const visible = models.filter((m) => !m.hidden);
    const anyDefault = visible.some((m) => m.isDefault);
    return visible.map((m, i) => {
      const hint = this.deps.pricing.costHint("codex", m.id);
      return {
        id: m.id,
        label: m.description ? `${m.displayName ?? m.id}: ${m.description}` : (m.displayName ?? m.id),
        default: anyDefault ? m.isDefault === true : i === 0,
        ...(hint ? { cost_hint: hint } : {}),
      };
    });
  }

  /** `model/list` from a short-lived app server; no model call. */
  private queryModels(launch: Launch): Promise<CodexModel[] | null> {
    return new Promise((resolve) => {
      let settled = false;
      let rpc: RpcClient | null = null;
      const proc = new HarnessProcess(launch, ["app-server"], {
        cwd: os.tmpdir(),
        env: harnessEnv(this.deps.env),
        onRecord: (r) => rpc?.handle(r),
      });
      const finish = (models: CodexModel[] | null) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        void proc.stop(3_000);
        resolve(models);
      };
      rpc = new RpcClient((m) => proc.send(m), {
        onNotification: () => undefined,
        onRequest: async (method) => {
          throw new RpcError(-32601, `not handled: ${method}`);
        },
      });
      const timer = setTimeout(() => finish(null), PROBE_TIMEOUT_MS);
      void proc.exited.then(() => finish(null));
      void (async () => {
        try {
          await rpc.request("initialize", { clientInfo: { name: "aurelhaven_townhall", title: "Aurelhaven Town Hall", version: DAEMON_VERSION }, capabilities: null });
          rpc.notify("initialized");
          const out: CodexModel[] = [];
          let cursor: string | null = null;
          for (let page = 0; page < 10; page++) {
            const r: unknown = await rpc.request("model/list", { limit: 100, ...(cursor ? { cursor } : {}) });
            const body = isPlainObject(r) ? r : {};
            for (const m of Array.isArray(body.data) ? body.data.filter(isPlainObject) : []) {
              const id = asString(m.id) ?? asString(m.model);
              if (!id) continue;
              out.push({
                id,
                ...(typeof m.displayName === "string" ? { displayName: m.displayName } : {}),
                ...(typeof m.description === "string" ? { description: m.description } : {}),
                hidden: m.hidden === true,
                isDefault: m.isDefault === true,
              });
            }
            cursor = asString(body.nextCursor);
            if (!cursor) break;
          }
          finish(out);
        } catch {
          finish(null);
        }
      })();
    });
  }

  start(req: RunRequest, host: RunHost): RunHandle {
    const res = resolveCodex(this.deps.env);
    if (!res.launch) throw fail.provider(res.problem ?? "Codex was not found");
    return new CodexRun(req, host, {
      launch: res.launch,
      deps: this.deps,
      estimate: this.billing === "subscription" ? true : undefined,
    });
  }
}
