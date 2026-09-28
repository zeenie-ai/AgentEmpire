import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { assertSafeGitArgs } from "../../src/core/workspace.js";
import { packageRoot } from "../../src/paths.js";

function sourceFiles(dir: string): string[] {
  const out: string[] = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...sourceFiles(p));
    else if (/\.(ts|js|mjs|json)$/.test(e.name)) out.push(p);
  }
  return out;
}

/** Drops the runtime guard, which has to name the commands it refuses. */
function withoutGuard(text: string): string {
  return text.replace(/\/\/ banned-git-guard:start[\s\S]*?\/\/ banned-git-guard:end/g, "");
}

const BANNED: Array<[string, RegExp]> = [
  ["worktree remove --force", /worktree["'`,\s]+remove["'`,\s]+[^\n]*(--force|["'`]-f["'`])/],
  ["reset --hard", /reset["'`,\s]+[^\n]*--hard/],
  ["--hard anywhere", /["'`]--hard["'`]/],
  ["git clean", /["'`]clean["'`]|git\s+clean\b/],
  ["git stash", /["'`]stash["'`]|git\s+stash\b/],
  ["--force anywhere", /["'`]--force["'`]/],
];

describe("destructive git commands", () => {
  const files = [...sourceFiles(path.join(packageRoot(), "src")), ...sourceFiles(path.join(packageRoot(), "scripts"))];

  it("scans a real source tree", () => {
    expect(files.length).toBeGreaterThan(30);
    expect(files.some((f) => f.endsWith("workspace.ts"))).toBe(true);
  });

  it.each(BANNED)("never appear in the Town Hall source: %s", (_label, pattern) => {
    const offenders = files.filter((f) => pattern.test(withoutGuard(readFileSync(f, "utf8"))));
    expect(offenders).toEqual([]);
  });

  it("are refused at runtime too", () => {
    expect(() => assertSafeGitArgs(["stash"])).toThrow(/destructive/);
    expect(() => assertSafeGitArgs(["stash", "pop"])).toThrow();
    expect(() => assertSafeGitArgs(["-c", "core.longpaths=true", "stash"])).toThrow();
    expect(() => assertSafeGitArgs(["clean", "-fd"])).toThrow();
    expect(() => assertSafeGitArgs(["reset", "--hard", "HEAD"])).toThrow();
    expect(() => assertSafeGitArgs(["worktree", "remove", "--force", "x"])).toThrow();
    expect(() => assertSafeGitArgs(["worktree", "remove", "-f", "x"])).toThrow();
    expect(() => assertSafeGitArgs(["-C", "repo", "checkout", "-f", "main"])).toThrow();
    expect(() => assertSafeGitArgs(["worktree", "remove", "x"])).not.toThrow();
    expect(() => assertSafeGitArgs(["merge", "--abort"])).not.toThrow();
    expect(() => assertSafeGitArgs(["status", "--porcelain"])).not.toThrow();
    expect(() => assertSafeGitArgs(["commit", "-m", "stash the clean files"])).not.toThrow();
  });
});
