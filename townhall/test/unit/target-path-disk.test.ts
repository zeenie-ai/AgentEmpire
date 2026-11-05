import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterAll, describe, expect, it, vi } from "vitest";

// Every path the path judging looks up on disk.
const looked = vi.hoisted(() => [] as string[]);

vi.mock("node:fs", async (original) => {
  const fs = await original<typeof import("node:fs")>();
  const lstatSync = ((p: string, options?: object) => {
    looked.push(String(p));
    return fs.lstatSync(p, options as Parameters<typeof fs.lstatSync>[1]);
  }) as typeof fs.lstatSync;
  const realpathSync = Object.assign(
    (p: string) => {
      looked.push(String(p));
      return fs.realpathSync(p);
    },
    {
      native: (p: string) => {
        looked.push(String(p));
        return fs.realpathSync.native(p);
      },
    },
  ) as typeof fs.realpathSync;
  return { ...fs, lstatSync, realpathSync };
});

const { targetInside } = await import("../../src/security/target-path.js");

describe("path judging and the disk", () => {
  const base = mkdtempSync(path.join(os.tmpdir(), "aurelhaven-disk-"));
  const root = path.join(base, "data", "wt", "ab1k2cd3");
  const elsewhere = path.join(base, "elsewhere");
  mkdirSync(path.join(root, "src"), { recursive: true });
  mkdirSync(elsewhere);
  writeFileSync(path.join(elsewhere, "secret.txt"), "secret\n");
  symlinkSync(elsewhere, path.join(root, "linked"), process.platform === "win32" ? "junction" : "dir");
  const scope = { cwd: root, root };
  const under = (dir: string) => looked.filter((p) => p.toLowerCase().startsWith(dir.toLowerCase()));

  afterAll(() => rmSync(base, { recursive: true, force: true }));

  it("does not look up a place plainly outside the worktree, where a dead network drive would stall it", () => {
    looked.length = 0;
    expect(targetInside(path.join(elsewhere, "secret.txt"), scope)).toBe(false);
    expect(targetInside(path.join(elsewhere, "deeper", "x.txt"), scope)).toBe(false);
    expect(under(elsewhere)).toEqual([]);
  });

  it("does not follow a link past the worktree", () => {
    looked.length = 0;
    expect(targetInside("linked/secret.txt", scope)).toBe(false);
    expect(under(elsewhere)).toEqual([]);
  });

  it("still looks up places inside", () => {
    looked.length = 0;
    expect(targetInside("src/a.ts", scope)).toBe(true);
    expect(under(path.join(root, "src")).length).toBeGreaterThan(0);
  });
});
