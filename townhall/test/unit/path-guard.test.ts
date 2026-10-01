import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import {
  checkInputPath,
  checkResolvedPath,
  defaultSystemDirs,
  isInside,
  validateWorkFolder,
  type PathPolicy,
} from "../../src/security/path-guard.js";

const win: PathPolicy = {
  platform: "win32",
  allowedRoots: ["C:\\Users\\Player", "D:\\"],
  dataDir: "D:\\startup\\projects\\agent_game\\townhall\\data",
  homeDir: "C:\\Users\\Player",
  systemDirs: defaultSystemDirs("win32", { SystemDrive: "C:", SystemRoot: "C:\\Windows" }),
};

function checkWin(input: string) {
  const lexical = checkInputPath(input, "win32");
  if (!lexical.ok) return lexical;
  return checkResolvedPath(lexical.path, win);
}

describe("path guard (Windows rules)", () => {
  it("accepts folders inside the allowed roots, case-insensitively and with either slash", () => {
    expect(checkWin("D:\\work\\app").ok).toBe(true);
    expect(checkWin("d:\\WORK\\app").ok).toBe(true);
    expect(checkWin("D:/work/app").ok).toBe(true);
    expect(checkWin("c:\\users\\PLAYER\\projects\\site").ok).toBe(true);
  });

  it("refuses drive roots, including after .. traversal", () => {
    expect(checkWin("C:\\")).toMatchObject({ ok: false, reason: expect.stringMatching(/drive root/) });
    expect(checkWin("d:/")).toMatchObject({ ok: false });
    expect(checkWin("D:\\work\\..\\..\\")).toMatchObject({ ok: false, reason: expect.stringMatching(/drive root/) });
  });

  it("refuses the home folder itself but not folders inside it", () => {
    expect(checkWin("C:\\Users\\Player")).toMatchObject({ ok: false, reason: expect.stringMatching(/home/) });
    expect(checkWin("c:\\users\\player\\")).toMatchObject({ ok: false });
    expect(checkWin("C:\\Users\\Player\\code").ok).toBe(true);
  });

  it("refuses system folders and everything inside them", () => {
    expect(checkWin("C:\\Windows\\System32")).toMatchObject({ ok: false, reason: expect.stringMatching(/system/) });
    expect(checkWin("c:\\program files\\App")).toMatchObject({ ok: false });
    expect(checkWin("C:\\Program Files (x86)\\x")).toMatchObject({ ok: false });
    expect(checkWin("C:\\ProgramData")).toMatchObject({ ok: false });
  });

  it("refuses UNC and device paths", () => {
    expect(checkWin("\\\\server\\share\\repo")).toMatchObject({ ok: false, reason: expect.stringMatching(/UNC/) });
    expect(checkWin("//server/share/repo")).toMatchObject({ ok: false });
    expect(checkWin("\\\\?\\C:\\work")).toMatchObject({ ok: false });
    expect(checkResolvedPath("\\\\?\\UNC\\server\\share", win)).toMatchObject({ ok: false });
  });

  it("refuses the data folder, anything inside it, and any folder that contains it", () => {
    expect(checkWin("D:\\startup\\projects\\agent_game\\townhall\\data")).toMatchObject({ ok: false, reason: expect.stringMatching(/data folder/) });
    expect(checkWin("D:\\startup\\projects\\agent_game\\townhall\\data\\wt\\abc")).toMatchObject({ ok: false });
    expect(checkWin("D:\\startup\\projects\\agent_game")).toMatchObject({ ok: false });
    expect(checkWin("D:\\startup\\projects\\other").ok).toBe(true);
  });

  it("refuses folders outside the roots, including lookalike prefixes", () => {
    expect(checkWin("E:\\work")).toMatchObject({ ok: false, reason: expect.stringMatching(/outside/) });
    const narrow: PathPolicy = { ...win, allowedRoots: ["C:\\Users\\Player\\work"] };
    expect(checkResolvedPath("C:\\Users\\Player\\workshop", narrow).ok).toBe(false);
    expect(checkResolvedPath("C:\\Users\\Player\\work\\a", narrow).ok).toBe(true);
    expect(isInside("C:\\Users\\PlayerEvil", "C:\\Users\\Player", "win32")).toBe(false);
  });

  it("requires an absolute path with a drive letter and refuses NUL characters", () => {
    expect(checkWin("work\\app")).toMatchObject({ ok: false, reason: expect.stringMatching(/drive letter/) });
    expect(checkWin("\\work\\app")).toMatchObject({ ok: false });
    expect(checkWin("D:\\work\u0000")).toMatchObject({ ok: false });
    expect(checkWin("   ")).toMatchObject({ ok: false });
  });
});

describe("path guard (real filesystem)", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "aurelhaven-guard-"));
  const allowed = path.join(root, "work");
  const outside = path.join(root, "elsewhere");
  mkdirSync(path.join(allowed, "app"), { recursive: true });
  mkdirSync(outside, { recursive: true });
  writeFileSync(path.join(allowed, "file.txt"), "x");
  const platform = process.platform === "win32" ? "win32" : "posix";
  const policy: PathPolicy = {
    platform,
    allowedRoots: [path.resolve(allowed)],
    dataDir: path.join(root, "data"),
    homeDir: os.homedir(),
    systemDirs: defaultSystemDirs(platform),
  };

  afterAll(() => rmSync(root, { recursive: true, force: true }));

  it("resolves real paths before checking them", () => {
    expect(validateWorkFolder(path.join(allowed, "app"), policy).ok).toBe(true);
    expect(validateWorkFolder(path.join(allowed, "missing"), policy)).toMatchObject({ ok: false, reason: expect.stringMatching(/does not exist/) });
    expect(validateWorkFolder(path.join(allowed, "file.txt"), policy)).toMatchObject({ ok: false, reason: expect.stringMatching(/not a folder/) });
    expect(validateWorkFolder(outside, policy).ok).toBe(false);
  });

  it("follows a junction or symlink to its real target", () => {
    const link = path.join(allowed, "sneaky");
    symlinkSync(outside, link, process.platform === "win32" ? "junction" : "dir");
    expect(validateWorkFolder(link, policy)).toMatchObject({ ok: false, reason: expect.stringMatching(/outside/) });
  });
});
