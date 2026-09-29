import { existsSync, readFileSync, statSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export type Env = Record<string, string | undefined>;

/** How a harness executable was found. */
export type LaunchSource = "env" | "path" | "known_location" | "bundled";

/**
 * A harness to spawn directly, never through a shell: `file` is an executable, and `prefix`
 * holds the arguments that come first (the entry script when the harness is a Node program).
 */
export interface Launch {
  file: string;
  prefix: string[];
  source: LaunchSource;
  /** The path the player would recognise (shim, script or binary), for messages. */
  display: string;
}

export interface Resolution {
  launch: Launch | null;
  /** Why nothing was found, or which override failed. */
  problem?: string;
}

const NODE_SCRIPT = /\.(c|m)?js$/i;
const CMD_SHIM = /\.(cmd|bat)$/i;

function isFile(p: string): boolean {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

/** Case-insensitive environment lookup (Windows spells PATH as "Path"). */
export function envValue(env: Env, name: string): string | undefined {
  if (env[name] !== undefined) return env[name];
  const key = Object.keys(env).find((k) => k.toLowerCase() === name.toLowerCase());
  return key ? env[key] : undefined;
}

/**
 * Looks `name` up on PATH. On Windows it tries the executable extensions a shell would try,
 * preferring a real .exe over a .cmd shim in the same folder; extensionless files (the
 * sh scripts npm writes for Git Bash) are skipped because CreateProcess cannot run them.
 */
export function findOnPath(name: string, env: Env, platform: NodeJS.Platform = process.platform): string | null {
  const dirs = (envValue(env, "PATH") ?? "").split(platform === "win32" ? ";" : ":").filter((d) => d.trim() !== "");
  const exts =
    platform === "win32"
      ? [".exe", ".cmd", ".bat", ".com"].concat(
          (envValue(env, "PATHEXT") ?? "")
            .split(";")
            .map((e) => e.trim().toLowerCase())
            .filter((e) => e && ![".exe", ".cmd", ".bat", ".com"].includes(e)),
        )
      : [""];
  for (const raw of dirs) {
    const dir = raw.replace(/^"(.*)"$/, "$1");
    for (const ext of exts) {
      const candidate = path.join(dir, name + ext);
      if (isFile(candidate)) return candidate;
    }
  }
  return null;
}

/**
 * The program an npm (or pnpm/yarn) Windows .cmd shim runs: the last quoted path relative to
 * the shim's folder ("%dp0%\..." or "%~dp0\..."). Returns null when the shim has no such path.
 */
export function readCmdShimTarget(shimPath: string): string | null {
  let text: string;
  try {
    text = readFileSync(shimPath, "utf8");
  } catch {
    return null;
  }
  const dir = path.dirname(shimPath);
  const matches = [...text.matchAll(/"%~?dp0%?\\?([^"%]+?)"/gi)].map((m) => m[1]!);
  const targets = matches.filter((m) => !/(^|\\)node(\.exe)?$/i.test(m));
  for (let i = targets.length - 1; i >= 0; i--) {
    const target = path.resolve(dir, targets[i]!.replace(/\\/g, path.sep));
    if (isFile(target)) return target;
  }
  return null;
}

/** Turns a file into something spawnable without a shell. */
export function launchFor(file: string, source: LaunchSource, nodePath = process.execPath): Launch | null {
  const resolved = path.resolve(file);
  if (!isFile(resolved)) return null;
  if (NODE_SCRIPT.test(resolved)) return { file: nodePath, prefix: [resolved], source, display: resolved };
  if (CMD_SHIM.test(resolved)) {
    const target = readCmdShimTarget(resolved);
    if (!target || CMD_SHIM.test(target)) return null;
    const inner = launchFor(target, source, nodePath);
    return inner ? { ...inner, display: resolved } : null;
  }
  return { file: resolved, prefix: [], source, display: resolved };
}

/** Resolves an override variable such as AURELHAVEN_CLAUDE_BIN. */
function fromOverride(env: Env, variable: string): Resolution | null {
  const raw = env[variable]?.trim();
  if (!raw) return null;
  const launch = launchFor(raw, "env");
  if (launch) return { launch };
  return { launch: null, problem: `${variable} points to ${raw}, which is not a runnable file` };
}

function npmGlobalDir(env: Env): string | null {
  if (process.platform === "win32") {
    const appData = envValue(env, "APPDATA");
    return appData ? path.join(appData, "npm") : null;
  }
  const prefix = envValue(env, "npm_config_prefix") ?? envValue(env, "NPM_CONFIG_PREFIX");
  return prefix ? path.join(prefix, "lib") : null;
}

function homeDir(env: Env): string {
  return envValue(env, "USERPROFILE") ?? envValue(env, "HOME") ?? os.homedir();
}

// ---------- Claude Code ----------

/**
 * Claude Code: AURELHAVEN_CLAUDE_BIN, then `claude` on PATH (a .cmd shim is followed to the
 * package's native claude.exe), then the native installer and npm global locations.
 */
export function resolveClaude(env: Env = process.env): Resolution {
  const override = fromOverride(env, "AURELHAVEN_CLAUDE_BIN");
  if (override) return override;
  const onPath = findOnPath("claude", env);
  const fromPath = onPath ? launchFor(onPath, "path") : null;
  if (fromPath) return { launch: fromPath };
  const exe = process.platform === "win32" ? "claude.exe" : "claude";
  const home = homeDir(env);
  const npm = npmGlobalDir(env);
  const candidates = [
    path.join(home, ".local", "bin", exe),
    path.join(home, ".claude", "local", exe),
    ...(npm ? [path.join(npm, "node_modules", "@anthropic-ai", "claude-code", "bin", exe)] : []),
  ];
  for (const c of candidates) {
    const launch = launchFor(c, "known_location");
    if (launch) return { launch };
  }
  return { launch: null, problem: "Claude Code was not found: install it, or set AURELHAVEN_CLAUDE_BIN" };
}

// ---------- Codex ----------

const CODEX_TRIPLES: Record<string, string> = {
  "win32-x64": "x86_64-pc-windows-msvc",
  "win32-arm64": "aarch64-pc-windows-msvc",
  "darwin-x64": "x86_64-apple-darwin",
  "darwin-arm64": "aarch64-apple-darwin",
  "linux-x64": "x86_64-unknown-linux-musl",
  "linux-arm64": "aarch64-unknown-linux-musl",
};

/** The native codex binary inside an @openai/codex package folder (nested, hoisted or vendored). */
export function codexNativeFromPackage(packageRoot: string, platform = process.platform, arch = process.arch): string | null {
  const key = `${platform}-${arch}`;
  const triple = CODEX_TRIPLES[key];
  if (!triple) return null;
  const bin = platform === "win32" ? "codex.exe" : "codex";
  const platformPackage = `codex-${key}`;
  const candidates = [
    path.join(packageRoot, "node_modules", "@openai", platformPackage, "vendor", triple, "bin", bin),
    path.join(path.dirname(packageRoot), platformPackage, "vendor", triple, "bin", bin),
    path.join(packageRoot, "vendor", triple, "bin", bin),
  ];
  return candidates.find(isFile) ?? null;
}

/** Walks up from a file inside a package to the folder whose package.json has the given name. */
function packageRootOf(file: string, name: string): string | null {
  let dir = path.dirname(file);
  for (;;) {
    const manifest = path.join(dir, "package.json");
    if (isFile(manifest)) {
      try {
        if ((JSON.parse(readFileSync(manifest, "utf8")) as { name?: string }).name === name) return dir;
      } catch {
        // keep walking
      }
    }
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

/** Replaces the codex.js launcher with the native binary it would spawn (see docs/spikes.md S2). */
function codexNative(launch: Launch): Launch {
  const script = launch.prefix[0];
  if (!script || !NODE_SCRIPT.test(script)) return launch;
  const root = packageRootOf(script, "@openai/codex");
  const native = root ? codexNativeFromPackage(root) : null;
  return native ? { file: native, prefix: [], source: launch.source, display: launch.display } : launch;
}

/** Codex: AURELHAVEN_CODEX_BIN, then `codex` on PATH, then the npm global package, as the native binary. */
export function resolveCodex(env: Env = process.env): Resolution {
  const override = fromOverride(env, "AURELHAVEN_CODEX_BIN");
  if (override) return override.launch ? { launch: codexNative(override.launch) } : override;
  const onPath = findOnPath("codex", env);
  const fromPath = onPath ? launchFor(onPath, "path") : null;
  if (fromPath) return { launch: codexNative(fromPath) };
  const npm = npmGlobalDir(env);
  if (npm) {
    const root = path.join(npm, "node_modules", "@openai", "codex");
    const native = codexNativeFromPackage(root);
    if (native) return { launch: { file: native, prefix: [], source: "known_location", display: native } };
  }
  return { launch: null, problem: "Codex CLI was not found: install it, or set AURELHAVEN_CODEX_BIN" };
}

// ---------- pi ----------

const PI_PACKAGE = "@earendil-works/pi-coding-agent";

/**
 * Finds an installed package folder the way Node does: node_modules/<name> in this module's
 * folder or any parent. (The pi package exports only an "import" entry, so require.resolve
 * cannot locate it.)
 */
export function findPackageDir(name: string, fromDir = path.dirname(fileURLToPath(import.meta.url))): string | null {
  let dir = fromDir;
  for (;;) {
    const candidate = path.join(dir, "node_modules", ...name.split("/"));
    if (isFile(path.join(candidate, "package.json"))) return candidate;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

/** The pi CLI bundled as a dependency of the Town Hall package. */
export function bundledPiCli(): string | null {
  const root = findPackageDir(PI_PACKAGE);
  if (!root) return null;
  try {
    const manifest = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8")) as { bin?: string | Record<string, string> };
    const bin = typeof manifest.bin === "string" ? manifest.bin : manifest.bin?.pi;
    if (!bin) return null;
    const cli = path.join(root, bin);
    return existsSync(cli) ? cli : null;
  } catch {
    return null;
  }
}

/** pi: AURELHAVEN_PI_BIN, then `pi` on PATH, then the copy bundled with the Town Hall. */
export function resolvePi(env: Env = process.env): Resolution {
  const override = fromOverride(env, "AURELHAVEN_PI_BIN");
  if (override) return override;
  const onPath = findOnPath("pi", env);
  const fromPath = onPath ? launchFor(onPath, "path") : null;
  if (fromPath) return { launch: fromPath };
  const cli = bundledPiCli();
  const bundled = cli ? launchFor(cli, "bundled") : null;
  if (bundled) return { launch: bundled };
  return { launch: null, problem: `pi was not found: reinstall the Town Hall's dependencies (${PI_PACKAGE}), or set AURELHAVEN_PI_BIN` };
}
