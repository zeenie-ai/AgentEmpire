import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { defaultDataDir, defaultEconomyPath, defaultWebDir } from "./paths.js";

export type ProviderMode = "fake" | "real";

export interface Config {
  host: "127.0.0.1";
  port: number;
  dataDir: string;
  economyPath: string;
  webDir: string;
  /** Extra origins allowed to open the WebSocket (for example a Godot dev server). */
  devOrigins: string[];
  /** Send COOP/COEP headers with the web export (only needed for threaded Godot builds). */
  crossOriginIsolation: boolean;
  providerMode: ProviderMode;
  /** Folders under which agents may be given a work folder. */
  workRoots: string[];
  riteTimeoutMs: number;
  fakeDefaultScenario: string;
  logLevel: string;
  /** Upper bounds for copying a plain (non-git) work folder into the agent's versioned folder. */
  plainFolderMaxFiles: number;
  plainFolderMaxBytes: number;
}

type Env = Record<string, string | undefined>;

function intFromEnv(env: Env, key: string, fallback: number): number {
  const raw = env[key];
  if (raw === undefined || raw.trim() === "") return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 0) throw new Error(`${key} must be a non-negative integer`);
  return n;
}

function listFromEnv(env: Env, key: string, separator: string): string[] {
  const raw = env[key];
  if (!raw) return [];
  return raw
    .split(separator)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

/**
 * Default work roots: the user's home folder, plus on Windows every non-system fixed drive
 * (a D: drive for projects is common). The path guard still refuses drive roots themselves.
 */
export function defaultWorkRoots(): string[] {
  const roots = [os.homedir()];
  if (process.platform === "win32") {
    const systemDrive = (process.env.SystemDrive ?? "C:").toUpperCase();
    for (const letter of "DEFGHIJKLMNOPQRSTUVWXYZ") {
      const root = `${letter}:\\`;
      if (`${letter}:` === systemDrive) continue;
      if (existsSync(root)) roots.push(root);
    }
  }
  return roots;
}

export function loadConfig(env: Env = process.env, overrides: Partial<Config> = {}): Config {
  const providerRaw = (env.AURELHAVEN_PROVIDER ?? "fake").trim().toLowerCase();
  if (providerRaw !== "fake" && providerRaw !== "real") {
    throw new Error(`AURELHAVEN_PROVIDER must be "fake" or "real", got "${providerRaw}"`);
  }
  const workRoots = listFromEnv(env, "AURELHAVEN_WORK_ROOTS", path.delimiter);
  const base: Config = {
    host: "127.0.0.1",
    port: intFromEnv(env, "AURELHAVEN_PORT", 0),
    dataDir: path.resolve(env.AURELHAVEN_DATA_DIR ?? defaultDataDir()),
    economyPath: path.resolve(env.AURELHAVEN_ECONOMY_PATH ?? defaultEconomyPath()),
    webDir: path.resolve(env.AURELHAVEN_WEB_DIR ?? defaultWebDir()),
    devOrigins: listFromEnv(env, "AURELHAVEN_DEV_ORIGINS", ","),
    crossOriginIsolation: env.AURELHAVEN_CROSS_ORIGIN_ISOLATION === "1",
    providerMode: providerRaw,
    workRoots: workRoots.length > 0 ? workRoots.map((r) => path.resolve(r)) : defaultWorkRoots(),
    riteTimeoutMs: intFromEnv(env, "AURELHAVEN_RITE_TIMEOUT_S", 600) * 1000,
    fakeDefaultScenario: env.AURELHAVEN_FAKE_SCENARIO ?? "basic",
    logLevel: env.AURELHAVEN_LOG_LEVEL ?? "info",
    plainFolderMaxFiles: intFromEnv(env, "AURELHAVEN_PLAIN_MAX_FILES", 20_000),
    plainFolderMaxBytes: intFromEnv(env, "AURELHAVEN_PLAIN_MAX_MB", 200) * 1024 * 1024,
  };
  return { ...base, ...overrides };
}
