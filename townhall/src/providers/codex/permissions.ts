import path from "node:path";
import type { ApprovalCategory } from "../../protocol/objects.js";
import { currentPlatform, isInside } from "../../security/path-guard.js";
import { displayTarget } from "../common/approvals.js";
import { asNumber, asString, isPlainObject } from "../common/support.js";
import type { ApprovalRequest } from "../types.js";

/**
 * True when `target` (relative to `cwd`) names a place inside the work folder. Text a shell or
 * Codex might expand ("~", "$HOME", "%USERPROFILE%") is never taken to be inside.
 */
export function insideWorkspace(target: string, cwd: string, workspaceRoot: string): boolean {
  if (!target.trim() || /^~|[$%]/.test(target)) return false;
  return isInside(path.resolve(cwd, target), workspaceRoot, currentPlatform());
}

export type FsAccess = "read" | "write" | "deny";

export interface FsGrant {
  access: FsAccess;
  /** What the grant names, for the approval card. */
  label: string;
  /** True only for a plain path inside the work folder; globs and special locations never are. */
  inside: boolean;
}

/** A Codex permission request the Town Hall understood in full. */
export interface PermissionRequest {
  network: boolean;
  files: FsGrant[];
  /** The GrantedPermissionProfile to answer with if the player allows it: exactly what was understood. */
  profile: Record<string, unknown>;
}

const LEGACY_FS_KEYS = new Set(["read", "write", "entries", "globScanMaxDepth"]);

/** Rebuilds a FileSystemSpecialPath with only the fields its kind has; null for an unknown kind. */
function specialPath(v: unknown): { value: Record<string, unknown>; label: string } | null {
  if (!isPlainObject(v)) return null;
  const subpath = v.subpath === undefined || v.subpath === null ? null : asString(v.subpath);
  if (v.subpath !== undefined && v.subpath !== null && subpath === null) return null;
  const under = subpath ? ` (${subpath})` : "";
  switch (v.kind) {
    case "root":
      return { value: { kind: "root" }, label: "the whole file system" };
    case "minimal":
      return { value: { kind: "minimal" }, label: "the system files programs need to run" };
    case "tmpdir":
      return { value: { kind: "tmpdir" }, label: "the temp folder" };
    case "slash_tmp":
      return { value: { kind: "slash_tmp" }, label: "/tmp" };
    case "project_roots":
      return { value: { kind: "project_roots", subpath }, label: `the project roots${under}` };
    case "unknown": {
      const p = asString(v.path);
      if (!p) return null;
      return { value: { kind: "unknown", path: p, subpath }, label: `${p}${under}` };
    }
    default:
      return null;
  }
}

function hasOnly(obj: Record<string, unknown>, keys: Set<string>): boolean {
  return Object.keys(obj).every((k) => keys.has(k) || obj[k] === null || obj[k] === undefined);
}

/**
 * Reads a RequestPermissionProfile (codex app-server 0.144): network access, the legacy read and
 * write path lists, and sandbox entries (a path, a glob pattern or a special location such as
 * the drive root, each with read, write or deny access). Returns null when any part is not
 * understood, so an unfamiliar request is declined rather than granted blind.
 */
export function parsePermissionRequest(raw: unknown, cwd: string, workspaceRoot: string): PermissionRequest | null {
  if (!isPlainObject(raw) || !hasOnly(raw, new Set(["network", "fileSystem"]))) return null;
  const profile: Record<string, unknown> = {};
  let network = false;
  if (raw.network !== null && raw.network !== undefined) {
    const n = raw.network;
    if (!isPlainObject(n) || !hasOnly(n, new Set(["enabled"]))) return null;
    if (n.enabled === true) {
      network = true;
      profile.network = { enabled: true };
    } else if (n.enabled !== false && n.enabled !== null && n.enabled !== undefined) {
      return null;
    }
  }

  const files: FsGrant[] = [];
  const fs = raw.fileSystem;
  if (fs !== null && fs !== undefined) {
    if (!isPlainObject(fs) || !hasOnly(fs, LEGACY_FS_KEYS)) return null;
    const list = (v: unknown): string[] | null => {
      if (v === null || v === undefined) return [];
      return Array.isArray(v) && v.every((x) => typeof x === "string" && x.trim() !== "") ? (v as string[]) : null;
    };
    const reads = list(fs.read);
    const writes = list(fs.write);
    if (!reads || !writes) return null;
    for (const p of reads) files.push({ access: "read", label: displayTarget(p, cwd), inside: insideWorkspace(p, cwd, workspaceRoot) });
    for (const p of writes) files.push({ access: "write", label: displayTarget(p, cwd), inside: insideWorkspace(p, cwd, workspaceRoot) });

    const entries: Array<Record<string, unknown>> = [];
    if (fs.entries !== null && fs.entries !== undefined) {
      if (!Array.isArray(fs.entries)) return null;
      for (const e of fs.entries) {
        if (!isPlainObject(e) || !hasOnly(e, new Set(["path", "access"])) || !isPlainObject(e.path)) return null;
        const access = e.access;
        if (access !== "read" && access !== "write" && access !== "deny") return null;
        const p = e.path;
        if (p.type === "path") {
          const target = asString(p.path);
          if (!target || !target.trim()) return null;
          files.push({ access, label: displayTarget(target, cwd), inside: insideWorkspace(target, cwd, workspaceRoot) });
          entries.push({ path: { type: "path", path: target }, access });
        } else if (p.type === "glob_pattern") {
          const pattern = asString(p.pattern);
          if (!pattern || !pattern.trim()) return null;
          files.push({ access, label: `files matching ${pattern}`, inside: false });
          entries.push({ path: { type: "glob_pattern", pattern }, access });
        } else if (p.type === "special") {
          const special = specialPath(p.value);
          if (!special) return null;
          files.push({ access, label: special.label, inside: false });
          entries.push({ path: { type: "special", value: special.value }, access });
        } else {
          return null;
        }
      }
    }
    const depth = fs.globScanMaxDepth;
    if (depth !== null && depth !== undefined && asNumber(depth) === null) return null;
    if (reads.length > 0 || writes.length > 0 || entries.length > 0) {
      profile.fileSystem = {
        read: reads.length > 0 ? reads : null,
        write: writes.length > 0 ? writes : null,
        ...(entries.length > 0 ? { entries } : {}),
        ...(typeof depth === "number" ? { globScanMaxDepth: depth } : {}),
      };
    }
  }
  return { network, files, profile };
}

/**
 * The approval for a permission request. The category is the strictest part of it: anything
 * outside the work folder (globs and special locations included) always asks the player.
 * Each kind of request has its own tool name, so a task- or agent-wide answer to one kind never
 * covers another, and a request for network and files together can only be allowed once.
 */
export function permissionApproval(req: PermissionRequest, reason: string | null): ApprovalRequest {
  const granting = req.files.filter((f) => f.access !== "deny");
  const outside = granting.some((f) => !f.inside);
  const writes = granting.some((f) => f.access === "write");
  const category: ApprovalCategory = outside ? "outside_workspace" : req.network ? "network" : writes ? "write" : "read";
  const both = req.network && req.files.length > 0;
  const tool = both ? "permissions" : req.network ? "network_access" : "file_access";

  const labels = (access: FsAccess) => req.files.filter((f) => f.access === access).map((f) => f.label);
  const parts: string[] = [];
  if (req.network) parts.push("network access");
  if (labels("read").length > 0) parts.push(`read access to ${labels("read").join(", ")}`);
  if (labels("write").length > 0) parts.push(`write access to ${labels("write").join(", ")}`);
  const blocked = labels("deny");
  const summary = `Allow ${parts.join(" and ") || "a sandbox change"} for this turn${blocked.length > 0 ? ` (keeping ${blocked.join(", ")} blocked)` : ""}`;
  return {
    tool,
    category,
    input: { permissions: req.profile },
    summary,
    ...(both ? { risk: "high" as const } : {}),
    ...(reason ? { reason } : {}),
  };
}
