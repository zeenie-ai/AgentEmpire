import { lstatSync, readlinkSync, realpathSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { canonicalDrive, currentPlatform, type Platform } from "./path-guard.js";

/** The task a tool path is judged for, and the machine it is read on. */
export interface TargetScope {
  /** Where relative paths start: the agent's working folder. */
  cwd: string;
  /** The worktree root the agent must stay inside. */
  root: string;
  /** The call changes files: an existing file with more than one hard link counts as outside. */
  write?: boolean;
  /** Path rules to apply. The filesystem is read only when they are the host's own. */
  platform?: Platform;
  /** What ~ means. Default: the Town Hall's home folder, which the harnesses inherit. */
  home?: string;
  /** What $NAME, ${NAME}, $env:NAME and %NAME% mean. Default: the Town Hall's environment. */
  env?: Record<string, string | undefined>;
}

export interface PathRules {
  platform: Platform;
  home: string;
  env: Record<string, string | undefined>;
}

const MAX_READINGS = 32;
const MAX_LINK_HOPS = 40;
const MAX_TARGETS = 64;
const MAX_ALTERNATIVES = 32;
const MAX_PATTERN_LENGTH = 4096;

/** Unicode spaces that pi turns into plain spaces. */
const PI_SPACES = /[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g;
/** Git Bash, MSYS, Cygwin and WSL drive paths, which pi and Claude Code read as X:\ on Windows. */
const SHELL_DRIVE = /^\/(?:mnt\/|cygdrive\/)?([a-z])(?:\/([\s\S]*))?$/i;
/** ~name (another user's home), ~+ and ~-: shell forms the Town Hall cannot resolve. */
const TILDE_USER = /^~[A-Za-z0-9._+-]+(?:[\\/]|$)/;
const VARIABLE = /\$\{([^}]*)\}|\$\(|\$(?:env:)?([A-Za-z_][A-Za-z0-9_]*)|%([^%]+)%/gi;
const VARIABLE_NAME = /^(?:env:)?([A-Za-z_][A-Za-z0-9_]*)$/i;
/** Names Win32 maps to devices, with or without an extension. */
const DEVICE_NAME = /^(?:con|prn|aux|nul|com[0-9\u00B9\u00B2\u00B3]|lpt[0-9\u00B9\u00B2\u00B3]|conin\$|conout\$)$/i;

function libFor(platform: Platform): path.PlatformPath {
  return platform === "win32" ? path.win32 : path.posix;
}

function sepOf(platform: Platform): string {
  return platform === "win32" ? "\\" : "/";
}

function isShellDrive(s: string, platform: Platform): boolean {
  return platform === "win32" && !s.startsWith("//") && !s.includes("\\") && SHELL_DRIVE.test(s);
}

function rulesOf(scope: TargetScope): PathRules {
  return {
    platform: scope.platform ?? currentPlatform(),
    home: scope.home ?? os.homedir(),
    env: scope.env ?? process.env,
  };
}

function lookup(name: string, rules: PathRules): string | undefined {
  let value = rules.env[name];
  if (value === undefined && rules.platform === "win32") {
    const lower = name.toLowerCase();
    value = Object.entries(rules.env).find(([k, v]) => v !== undefined && k.toLowerCase() === lower)?.[1];
  }
  // Shells set these themselves even when the environment does not (Git Bash on Windows).
  if (value === undefined && /^(home|userprofile)$/i.test(name)) value = rules.home;
  return value;
}

/**
 * $NAME, ${NAME}, $env:NAME and %NAME% replaced by their values. An unset variable stays as
 * written; `$(`, and `${...}` with anything but a name, cannot be resolved (null).
 */
function expandVariables(s: string, rules: PathRules): string | null {
  let unclear = false;
  const out = s.replace(VARIABLE, (match: string, braced?: string, plain?: string, percent?: string) => {
    if (percent !== undefined) return lookup(percent, rules) ?? match;
    const name = braced !== undefined ? VARIABLE_NAME.exec(braced)?.[1] : plain;
    if (name === undefined) {
      unclear = true;
      return match;
    }
    return lookup(name, rules) ?? match;
  });
  return unclear ? null : out;
}

type Rewrite = (s: string, rules: PathRules) => string | null;

/** One step of how a harness, a shell or the OS reads a path; null when it cannot be worked out. */
const REWRITES: Rewrite[] = [
  // Claude Code trims.
  (s) => s.trim(),
  // pi makes Unicode spaces plain and drops one leading @.
  (s) => s.replace(PI_SPACES, " "),
  (s) => (s.startsWith("@") ? s.slice(1) : s),
  // Both read /c/... as C:\... on Windows.
  (s, r) => {
    if (!isShellDrive(s, r.platform)) return s;
    const m = SHELL_DRIVE.exec(s)!;
    return `${m[1]!.toUpperCase()}:\\${(m[2] ?? "").replace(/\//g, "\\")}`;
  },
  // ~ is the home folder for the harnesses and shells alike.
  (s, r) => {
    if (s === "~") return r.home;
    if (s.startsWith("~/") || s.startsWith("~\\")) return `${r.home}${sepOf(r.platform)}${s.slice(2)}`;
    return TILDE_USER.test(s) ? null : s;
  },
  // pi reads file:// URLs.
  (s, r) => {
    if (!/^file:/i.test(s)) return s;
    try {
      return fileURLToPath(s, { windows: r.platform === "win32" });
    } catch {
      return null;
    }
  },
  // Shells expand variables.
  (s, r) => (/[$%]/.test(s) ? expandVariables(s, r) : s),
];

/** How a tool reads its paths, beyond the readings every path gets. */
export interface ToolReading {
  /** Reads /c/... only as C:\... on Windows (Claude Code's and pi's file tools), never as \c\... */
  drivesOnly?: boolean;
  /** Also reads lookalike spellings of a missing file (pi's read). */
  readFallback?: boolean;
}

/**
 * Every reading of a path as written, before it is resolved against the working folder: the
 * text itself and everything the rewrites above make of it, in any order. Null when a reading
 * cannot be worked out.
 */
export function pathReadings(raw: string, rules: PathRules, how: ToolReading = {}): string[] | null {
  if (raw.includes("\0")) return null;
  const seen = new Set<string>([raw]);
  const queue = [raw];
  for (let i = 0; i < queue.length; i++) {
    for (const rewrite of REWRITES) {
      const next = rewrite(queue[i]!, rules);
      if (next === null) return null;
      if (seen.has(next)) continue;
      if (seen.size >= MAX_READINGS) return null;
      seen.add(next);
      queue.push(next);
    }
  }
  // The drive reading of each such path is in the set already.
  return how.drivesOnly ? queue.filter((s) => !isShellDrive(s, rules.platform)) : queue;
}

/**
 * A Windows path in plain form: \\?\C:\, \\.\C:\ and \??\C:\ become C:\. `share` is the lowercase
 * \\server\share of a network path. Null for device paths (\\.\PhysicalDrive0, \\?\Volume{...}).
 */
function windowsForm(p: string): { path: string; share: string | null } | null {
  const s = p.replace(/\//g, "\\");
  const verbatim = /^(?:\\\\[?.]\\|\\\?\?\\)([a-z]:\\[\s\S]*)$/i.exec(s);
  if (verbatim) return { path: verbatim[1]!, share: null };
  const unc = /^(?:\\\\\?\\UNC\\|\\\\(?![?.]\\))([^\\]+)\\([^\\]+)([\s\S]*)$/i.exec(s);
  if (unc) return { path: `\\\\${unc[1]}\\${unc[2]}${unc[3]}`, share: `\\\\${unc[1]}\\${unc[2]}`.toLowerCase() };
  if (s.startsWith("\\\\") || s.startsWith("\\??\\")) return null;
  return { path: p, share: null };
}

function shareOf(p: string, platform: Platform): string | null {
  return platform === "win32" ? (windowsForm(p)?.share ?? null) : null;
}

/**
 * Drops alternate data streams (a stream belongs to its file). Null for a name Win32 maps to a
 * device, or one ending in a dot or space, which Node keeps and Win32 strips.
 */
function windowsNames(p: string): string | null {
  const root = path.win32.parse(p).root;
  const names: string[] = [];
  for (const segment of p.slice(root.length).split(/[\\/]+/)) {
    const name = segment.split(":")[0]!;
    if (!name) continue;
    if (/[. ]$/.test(name)) return null;
    if (DEVICE_NAME.test(name.split(".")[0]!.trimEnd())) return null;
    names.push(name);
  }
  return path.win32.join(root, ...names);
}

/**
 * The absolute places a reading names. On Windows the OS collapses `..` before following links;
 * on POSIX the kernel applies `..` after them, so a reading with `..` also gets its raw form.
 * Null when the reading is a network or device path the Town Hall must not touch.
 */
function placesOf(reading: string, cwd: string, rules: PathRules, shares: Set<string>): string[] | null {
  if (rules.platform === "win32") {
    const form = windowsForm(reading);
    if (!form || (form.share !== null && !shares.has(form.share))) return null;
    const resolved = windowsForm(path.win32.resolve(cwd, form.path));
    if (!resolved || (resolved.share !== null && !shares.has(resolved.share))) return null;
    const clean = windowsNames(resolved.path);
    return clean === null ? null : [clean];
  }
  const lexical = path.posix.resolve(cwd, reading);
  if (!reading.split("/").includes("..")) return [lexical];
  return [lexical, reading.startsWith("/") ? reading : `${cwd}/${reading}`];
}

/** Where a link's target lies, relative paths taken from the link's folder. */
function linkTarget(folder: string, target: string, platform: Platform): string {
  if (platform !== "win32") return target.startsWith("/") ? target : `${folder}/${target}`;
  if (/^[a-z]:[\\/]/i.test(target) || target.startsWith("\\\\")) return target;
  if (/^[\\/]/.test(target)) return path.win32.parse(folder).root.slice(0, -1) + target;
  if (/^[a-z]:/i.test(target)) return path.win32.resolve(folder, target);
  return `${folder}\\${target}`;
}

interface Located {
  /** The real path of the deepest existing folder, plus the rest as written. */
  real: string;
  /** The whole path exists. */
  exists: boolean;
  /** Hard links of the file it names (1 for anything else). */
  links: number;
}

/**
 * Follows a path the way the filesystem will: component by component with lstat, through every
 * link (a dangling one included, since a write through it creates its target), applying `..` to
 * the real folder reached so far. A link into a network or device path is not followed (null).
 * The existing part then goes through realpath for its on-disk case and long names.
 */
function locate(abs: string, platform: Platform, shares: Set<string>, hops = MAX_LINK_HOPS): Located | null {
  const lib = libFor(platform);
  const { root } = lib.parse(abs);
  const segments = abs.slice(root.length).split(platform === "win32" ? /[\\/]+/ : /\/+/).filter((s) => s !== "");
  const parts: string[] = [];
  let known = 0;
  let links = 1;
  let linksAt = -1;
  for (let i = 0; i < segments.length; i++) {
    const segment = segments[i]!;
    if (segment === ".") continue;
    if (segment === "..") {
      parts.pop();
      known = Math.min(known, parts.length);
      continue;
    }
    parts.push(segment);
    // Below a folder that does not exist there is nothing to look up.
    if (known < parts.length - 1) continue;
    const here = lib.join(root, ...parts);
    const stat = lstatSync(here, { throwIfNoEntry: false });
    if (!stat) continue;
    if (stat.isSymbolicLink()) {
      if (hops <= 0) return null;
      const raw = readlinkSync(here);
      const target = platform === "win32" ? windowsForm(raw) : { path: raw, share: null };
      if (!target || (target.share !== null && !shares.has(target.share))) return null;
      const next = linkTarget(lib.join(root, ...parts.slice(0, -1)), target.path, platform);
      const rest = segments.slice(i + 1);
      return locate(rest.length > 0 ? `${next}${sepOf(platform)}${rest.join(sepOf(platform))}` : next, platform, shares, hops - 1);
    }
    known = parts.length;
    links = stat.isFile() ? stat.nlink : 1;
    linksAt = known;
  }
  const real = realpathSync.native(lib.join(root, ...parts.slice(0, known)));
  const tail = parts.slice(known);
  const exists = tail.length === 0;
  return { real: exists ? real : lib.join(real, ...tail), exists, links: exists && linksAt === known ? links : 1 };
}

const realRoots = new Map<string, string>();

/** The worktree root's real path, cached once it exists. */
function realRootOf(root: string, platform: Platform): string | null {
  const known = realRoots.get(root);
  if (known !== undefined) return known;
  let real: string;
  try {
    real = realpathSync.native(root);
  } catch {
    // Not there (yet): the same reading as a target, so both sides compare alike.
    const resolved = libFor(platform).resolve(root);
    const share = shareOf(resolved, platform);
    return locate(resolved, platform, new Set(share ? [share] : []))?.real ?? null;
  }
  if (realRoots.size >= 256) realRoots.clear();
  realRoots.set(root, real);
  return real;
}

function within(real: string, root: string, platform: Platform): boolean {
  const sep = sepOf(platform);
  return real === root || real.startsWith(root.endsWith(sep) ? root : root + sep);
}

/** pi's read retries a missing file as these spellings of the whole path (macOS screenshot names). */
function readVariants(p: string): string[] {
  const nfd = p.normalize("NFD");
  const variants = [p.replace(/ (AM|PM)\./gi, "\u202F$1."), nfd, p.replace(/'/g, "\u2019"), nfd.replace(/'/g, "\u2019")];
  return [...new Set(variants)].filter((v) => v !== p);
}

/**
 * True when `raw` (as a tool call wrote it, relative to `scope.cwd`) stays inside the worktree:
 * every reading of it that a harness, a shell or the OS could make lands inside the real location
 * of the worktree, with symbolic links and junctions followed. Anything that cannot be worked out
 * with confidence counts as outside, so the player is asked.
 */
export function targetInside(raw: string, scope: TargetScope, how: ToolReading = {}): boolean {
  const rules = rulesOf(scope);
  const physical = rules.platform === currentPlatform();
  try {
    const readings = pathReadings(raw, rules, how);
    if (!readings) return false;
    const root = physical ? realRootOf(scope.root, rules.platform) : canonicalDrive(libFor(rules.platform).resolve(scope.root), rules.platform);
    if (root === null) return false;
    const shares = new Set<string>();
    for (const p of [scope.root, root]) {
      const share = shareOf(p, rules.platform);
      if (share) shares.add(share);
    }
    for (const reading of readings) {
      const places = placesOf(reading, scope.cwd, rules, shares);
      if (!places) return false;
      for (const place of places) {
        if (!physical) {
          // Another platform's rules: spelling only, compared exactly like real paths.
          const spelled = canonicalDrive(libFor(rules.platform).resolve(place), rules.platform);
          if (!within(spelled, root, rules.platform)) return false;
          continue;
        }
        const found = locate(place, rules.platform, shares);
        if (!found || !within(found.real, root, rules.platform)) return false;
        if (scope.write && found.exists && found.links > 1) return false;
        if (how.readFallback && !found.exists) {
          for (const variant of readVariants(place)) {
            const other = locate(variant, rules.platform, shares);
            if (!other || (other.exists && !within(other.real, root, rules.platform))) return false;
          }
        }
      }
    }
    return true;
  } catch {
    // Permissions, link loops, races: nothing the Town Hall can vouch for.
    return false;
  }
}

/** {a,b} alternatives, nested too; null past MAX_ALTERNATIVES. An unclosed brace stays as written. */
function expandBraces(pattern: string): string[] | null {
  const open = pattern.indexOf("{");
  if (open < 0) return [pattern];
  let depth = 0;
  let close = -1;
  const commas: number[] = [];
  for (let i = open; i < pattern.length && close < 0; i++) {
    const ch = pattern[i];
    if (ch === "{") depth++;
    else if (ch === "}" && --depth === 0) close = i;
    else if (ch === "," && depth === 1) commas.push(i);
  }
  if (close < 0) return [pattern];
  const head = pattern.slice(0, open);
  const tail = pattern.slice(close + 1);
  const out: string[] = [];
  let start = open + 1;
  for (const end of [...commas, close]) {
    const expanded = expandBraces(head + pattern.slice(start, end) + tail);
    if (!expanded) return null;
    out.push(...expanded);
    if (out.length > MAX_ALTERNATIVES) return null;
    start = end + 1;
  }
  return out;
}

/**
 * The folders a glob pattern can reach: for the pattern and each of its {a,b} alternatives, the
 * part before the segment holding the first wildcard (a pattern without one names a file, so its
 * folder). Null for a pattern that climbs with `..`, which glob libraries may follow.
 */
export function patternBases(pattern: string, platform: Platform): string[] | null {
  if (pattern.length > MAX_PATTERN_LENGTH) return null;
  const body = pattern.startsWith("!") ? pattern.slice(1) : pattern;
  const alternatives = expandBraces(body);
  if (!alternatives) return null;
  const bases = new Set<string>();
  for (const alternative of [body, ...alternatives]) {
    if (alternative.split(/[\\/]/).includes("..")) return null;
    const wild = alternative.search(/[*?[{]/);
    const fixed = wild < 0 ? alternative : alternative.slice(0, wild);
    const cut = Math.max(fixed.lastIndexOf("/"), platform === "win32" ? fixed.lastIndexOf("\\") : -1);
    if (cut >= 0) bases.add(fixed.slice(0, cut + 1));
  }
  return [...bases];
}

/** Fields that name a file or folder, in any tool (MCP tools included). */
const PATH_FIELDS = ["file_path", "path", "notebook_path", "paths", "cwd"];
/** Tool-specific lists of paths: a Codex patch's changed files. */
const LIST_FIELDS = new Map([["apply_patch", "changes"]]);
/** Glob patterns: Claude Code's Glob pattern (an absolute one overrides `path`) and the filters of the search tools. */
const PATTERN_FIELDS = new Map([
  ["Glob", "pattern"],
  ["Grep", "glob"],
  ["find", "pattern"],
  ["grep", "glob"],
]);
/** Search tools that search the working folder when `path` is left out. */
const SEARCH_TOOLS = new Set(["Glob", "Grep", "LS", "find", "grep", "ls"]);
/** Claude Code's and pi's file tools: both read /c/... as C:\ on Windows. */
const DRIVES_ONLY_TOOLS = new Set([
  ...["Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "NotebookRead", "Glob", "Grep", "LS"],
  ...["read", "write", "edit", "grep", "find", "ls"],
]);

/**
 * True when a tool call names any place outside the worktree: a path field, a search tool's
 * folder, or the fixed folder of a glob pattern. A field the Town Hall does not understand (not
 * a string or a list of strings) counts as outside.
 */
export function reachesOutside(tool: string, input: unknown, scope: TargetScope): boolean {
  const fields = input !== null && typeof input === "object" && !Array.isArray(input) ? (input as Record<string, unknown>) : {};
  const targets: string[] = [];
  const add = (value: unknown): boolean => {
    if (value === undefined || value === null) return true;
    const values = Array.isArray(value) ? value : [value];
    if (targets.length + values.length > MAX_TARGETS || !values.every((v) => typeof v === "string")) return false;
    targets.push(...(values as string[]));
    return true;
  };
  try {
    const list = LIST_FIELDS.get(tool);
    for (const field of list ? [...PATH_FIELDS, list] : PATH_FIELDS) {
      if (!add(fields[field])) return true;
    }
    const searchPath = typeof fields.path === "string" ? fields.path : null;
    if (SEARCH_TOOLS.has(tool) && searchPath === null) targets.push(".");
    const patternField = PATTERN_FIELDS.get(tool);
    const pattern = patternField ? fields[patternField] : undefined;
    if (pattern !== undefined && pattern !== null) {
      if (typeof pattern !== "string") return true;
      const bases = patternBases(pattern, scope.platform ?? currentPlatform());
      if (!bases) return true;
      for (const base of bases) {
        targets.push(base);
        if (searchPath) targets.push(`${searchPath.replace(/[\\/]+$/, "")}/${base}`);
      }
    }
    if (targets.length > MAX_TARGETS) return true;
    // pi's read also tries lookalike spellings of a missing file.
    const how: ToolReading = { drivesOnly: DRIVES_ONLY_TOOLS.has(tool), readFallback: tool === "read" };
    return targets.some((t) => !targetInside(t, scope, how));
  } catch {
    return true;
  }
}
