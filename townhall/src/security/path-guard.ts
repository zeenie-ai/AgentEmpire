import { realpathSync, statSync } from "node:fs";
import os from "node:os";
import path from "node:path";

export type Platform = "win32" | "posix";

export interface PathPolicy {
  platform: Platform;
  /** Roots a work folder must sit inside. Should already be real paths. */
  allowedRoots: string[];
  /** The Town Hall data folder (database, runtime.json with the token, worktrees). */
  dataDir: string;
  homeDir: string;
  /** Folders refused along with everything inside them. */
  systemDirs: string[];
}

export type PathCheck = { ok: true; path: string } | { ok: false; reason: string };

function lib(platform: Platform): path.PlatformPath {
  return platform === "win32" ? path.win32 : path.posix;
}

/** Normalised comparison key: resolved, no trailing separator, lower-cased on Windows. */
export function pathKey(p: string, platform: Platform): string {
  const l = lib(platform);
  let n = l.normalize(p);
  if (n.length > 1 && (n.endsWith("\\") || n.endsWith("/")) && !isDriveRoot(n, platform)) n = n.slice(0, -1);
  if (platform === "win32") n = n.replace(/\//g, "\\").toLowerCase();
  return n;
}

export function samePath(a: string, b: string, platform: Platform): boolean {
  return pathKey(a, platform) === pathKey(b, platform);
}

/** True when `child` equals `parent` or lies inside it. */
export function isInside(child: string, parent: string, platform: Platform): boolean {
  const c = pathKey(child, platform);
  const p = pathKey(parent, platform);
  if (c === p) return true;
  const sep = platform === "win32" ? "\\" : "/";
  const prefix = p.endsWith(sep) ? p : p + sep;
  return c.startsWith(prefix);
}

export function isDriveRoot(p: string, platform: Platform): boolean {
  if (platform === "win32") return /^[a-zA-Z]:[\\/]?$/.test(p.trim());
  return lib(platform).normalize(p) === "/";
}

export function isUncOrDevicePath(p: string): boolean {
  return p.startsWith("\\\\") || p.startsWith("//") || /^\\\?\\/.test(p);
}

export function defaultSystemDirs(platform: Platform, env: Record<string, string | undefined> = process.env): string[] {
  if (platform === "win32") {
    const drive = (env.SystemDrive ?? "C:").replace(/[\\/]$/, "");
    const dirs = [
      env.SystemRoot ?? `${drive}\\Windows`,
      env.ProgramFiles ?? `${drive}\\Program Files`,
      env["ProgramFiles(x86)"] ?? `${drive}\\Program Files (x86)`,
      env.ProgramData ?? `${drive}\\ProgramData`,
      `${drive}\\Windows`,
      `${drive}\\Program Files`,
      `${drive}\\Program Files (x86)`,
      `${drive}\\ProgramData`,
      `${drive}\\$Recycle.Bin`,
      `${drive}\\System Volume Information`,
      `${drive}\\Recovery`,
      `${drive}\\Boot`,
    ];
    return [...new Set(dirs)];
  }
  return [
    "/bin",
    "/boot",
    "/dev",
    "/etc",
    "/lib",
    "/lib64",
    "/proc",
    "/root",
    "/sbin",
    "/sys",
    "/usr",
    "/var",
    "/System",
    "/Library",
    "/Applications",
    "/private/etc",
  ];
}

/**
 * Policy checks on a path that has already been resolved to its real location.
 * Pure, so the Windows rules can be tested on any platform.
 */
export function checkResolvedPath(real: string, policy: PathPolicy): PathCheck {
  const { platform } = policy;
  if (isUncOrDevicePath(real)) return { ok: false, reason: "network (UNC) and device paths are not allowed" };
  if (isDriveRoot(real, platform)) return { ok: false, reason: "a drive root cannot be a work folder" };
  if (samePath(real, policy.homeDir, platform)) return { ok: false, reason: "the home folder itself cannot be a work folder" };
  for (const dir of policy.systemDirs) {
    if (isInside(real, dir, platform)) return { ok: false, reason: "system folders cannot be work folders" };
  }
  if (isInside(real, policy.dataDir, platform) || isInside(policy.dataDir, real, platform)) {
    return { ok: false, reason: "the Town Hall data folder cannot be inside or contain a work folder" };
  }
  if (!policy.allowedRoots.some((root) => isInside(real, root, platform))) {
    return { ok: false, reason: "the folder is outside the allowed work roots" };
  }
  return { ok: true, path: real };
}

/** Lexical checks before touching the filesystem. */
export function checkInputPath(input: string, platform: Platform): PathCheck {
  const trimmed = input.trim();
  if (trimmed === "") return { ok: false, reason: "empty path" };
  if (trimmed.includes("\0")) return { ok: false, reason: "invalid characters in path" };
  if (isUncOrDevicePath(trimmed)) return { ok: false, reason: "network (UNC) and device paths are not allowed" };
  if (platform === "win32") {
    if (!/^[a-zA-Z]:[\\/]/.test(trimmed) && !/^[a-zA-Z]:$/.test(trimmed)) {
      return { ok: false, reason: "an absolute path with a drive letter is required" };
    }
  } else if (!trimmed.startsWith("/")) {
    return { ok: false, reason: "an absolute path is required" };
  }
  return { ok: true, path: lib(platform).resolve(trimmed) };
}

/** Upper-cases the drive letter so paths display consistently. */
export function canonicalDrive(p: string, platform: Platform): string {
  if (platform === "win32" && /^[a-z]:/.test(p)) return p[0]!.toUpperCase() + p.slice(1);
  return p;
}

export function currentPlatform(): Platform {
  return process.platform === "win32" ? "win32" : "posix";
}

export function realpathOrNull(p: string): string | null {
  try {
    return realpathSync.native(p);
  } catch {
    return null;
  }
}

/** Full validation of a user-supplied work folder: lexical, realpath, then policy. */
export function validateWorkFolder(input: string, policy: PathPolicy): PathCheck {
  const lexical = checkInputPath(input, policy.platform);
  if (!lexical.ok) return lexical;
  const real = realpathOrNull(lexical.path);
  if (!real) return { ok: false, reason: "the folder does not exist" };
  try {
    if (!statSync(real).isDirectory()) return { ok: false, reason: "not a folder" };
  } catch {
    return { ok: false, reason: "the folder cannot be read" };
  }
  const result = checkResolvedPath(canonicalDrive(real, policy.platform), policy);
  return result;
}

export function buildPathPolicy(opts: { workRoots: string[]; dataDir: string }): PathPolicy {
  const platform = currentPlatform();
  const real = (p: string) => canonicalDrive(realpathOrNull(p) ?? path.resolve(p), platform);
  return {
    platform,
    allowedRoots: opts.workRoots.map(real),
    dataDir: real(opts.dataDir),
    homeDir: real(os.homedir()),
    systemDirs: defaultSystemDirs(platform),
  };
}

/** Forward-slash form used in protocol objects ("D:/work/app"). */
export function displayPath(p: string): string {
  return p.replace(/\\/g, "/");
}
