import { randomBytes } from "node:crypto";
import { mkdirSync, rmSync } from "node:fs";
import path from "node:path";
import type { Logger } from "../../log.js";
import { Redactor } from "../../security/redact.js";
import type { EconomyTools } from "./capabilities.js";
import type { Env } from "./exec.js";
import type { Pricing } from "./pricing.js";
import type { FramingNames } from "./prompt.js";

/** What every real adapter needs from the Town Hall. */
export interface HarnessDeps {
  /** The environment harnesses inherit (process.env in production). */
  env: Env;
  /** The Town Hall data folder: per-run scratch files and pi sessions live under it, never in a worktree. */
  dataDir: string;
  /** economy.json: add-on grants per provider, plus role and size names for the task framing. */
  tools: EconomyTools;
  names: FramingNames;
  pricing: Pricing;
  log?: Logger | undefined;
  redactor?: Redactor | undefined;
}

/** A private folder for one run's generated files (prompt text, MCP config), removed afterwards. */
export function makeScratch(dataDir: string, provider: string, taskId: string): string {
  const safeTask = taskId.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 40);
  const dir = path.join(dataDir, "harness", provider, `${safeTask}-${randomBytes(4).toString("hex")}`);
  mkdirSync(dir, { recursive: true });
  return dir;
}

export function removeScratch(dir: string | null): void {
  if (!dir) return;
  try {
    rmSync(dir, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
  } catch {
    // Windows may hold a handle briefly; the folder is tiny.
  }
}

export function isPlainObject(v: unknown): v is Record<string, unknown> {
  return !!v && typeof v === "object" && !Array.isArray(v);
}

export function asString(v: unknown): string | null {
  return typeof v === "string" ? v : null;
}

export function asNumber(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

export interface FailureClass {
  code: string;
  transient: boolean;
}

/**
 * Sorts a harness failure into the Town Hall's cases: a provider usage limit pauses the task,
 * an expired login or a crash is a rift (retried once), anything else is a plain failure.
 */
export function classifyFailure(text: string): FailureClass {
  const t = text.toLowerCase();
  if (/usage limit|rate[ _-]?limit|too many requests|\b429\b|quota|limit reached|usagelimitexceeded/.test(t)) {
    return { code: "provider_limit", transient: true };
  }
  if (/authenticat|unauthori[sz]ed|\b401\b|\b403\b|not logged in|log ?in again|credential|invalid api key|expired token|oauth|billing/.test(t)) {
    return { code: "auth", transient: true };
  }
  return { code: "crash", transient: true };
}

/** Redacts and trims harness text before it becomes activity or an error message. */
export function cleanText(text: string, redactor: Redactor | undefined, max = 2000): string {
  const redacted = (redactor ?? new Redactor()).redact(text).trim();
  return redacted.length > max ? `${redacted.slice(0, max - 3)}...` : redacted;
}
