import { linkSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { afterAll, describe, expect, it } from "vitest";
import { insideWorkspace } from "../../src/providers/codex/permissions.js";
import { currentPlatform, type Platform } from "../../src/security/path-guard.js";
import { pathReadings, patternBases, reachesOutside, targetInside, type PathRules, type TargetScope } from "../../src/security/target-path.js";

const host = currentPlatform();
const win = host === "win32";

describe("path readings (pure)", () => {
  const winRules: PathRules = {
    platform: "win32",
    home: "C:\\Users\\Player",
    env: { USERPROFILE: "C:\\Users\\Player", APPDATA: "C:\\Users\\Player\\AppData\\Roaming", Vault: "D:\\vault" },
  };
  const posixRules: PathRules = { platform: "posix", home: "/home/player", env: { HOME: "/home/player", XDG_CONFIG_HOME: "/home/player/.config" } };

  it.each([
    ["~/.bashrc", "C:\\Users\\Player\\.bashrc"],
    ["~\\.bashrc", "C:\\Users\\Player\\.bashrc"],
    ["~", "C:\\Users\\Player"],
    ["@C:\\Users\\Player\\.gitconfig", "C:\\Users\\Player\\.gitconfig"],
    ["@~/.gitconfig", "C:\\Users\\Player\\.gitconfig"],
    ["file:///C:/Users/Player/.bashrc", "C:\\Users\\Player\\.bashrc"],
    ["file://attacker.example/share/x.txt", "\\\\attacker.example\\share\\x.txt"],
    ["/c/Users/Player/.ssh", "C:\\Users\\Player\\.ssh"],
    ["/mnt/d/vault", "D:\\vault"],
    ["%APPDATA%\\AgentEmpire\\runtime.json", "C:\\Users\\Player\\AppData\\Roaming\\AgentEmpire\\runtime.json"],
    ["%appdata%\\x", "C:\\Users\\Player\\AppData\\Roaming\\x"],
    ["$env:VAULT\\keys", "D:\\vault\\keys"],
    ["${Vault}\\keys", "D:\\vault\\keys"],
    ["$HOME/.ssh", "C:\\Users\\Player/.ssh"],
    [" C:\\Users\\Player\\.ssh", "C:\\Users\\Player\\.ssh"],
    ["\u00A0C:\\Users\\Player\\.ssh", "C:\\Users\\Player\\.ssh"],
  ])("Windows: %s can mean %s", (raw, meant) => {
    expect(pathReadings(raw, winRules)).toContain(meant);
  });

  it.each([
    ["~/.bashrc", "/home/player/.bashrc"],
    ["@/etc/passwd", "/etc/passwd"],
    ["file:///etc/passwd", "/etc/passwd"],
    ["file://localhost/etc/passwd", "/etc/passwd"],
    ["$XDG_CONFIG_HOME/AgentEmpire/runtime.json", "/home/player/.config/AgentEmpire/runtime.json"],
    ["${HOME}/.ssh", "/home/player/.ssh"],
    ["\u3000/etc/passwd", "/etc/passwd"],
  ])("POSIX: %s can mean %s", (raw, meant) => {
    expect(pathReadings(raw, posixRules)).toContain(meant);
  });

  it.each(["~bob/.ssh", "~+/x", "$(whoami)/x", "${HOME:-/tmp}/x", "file://server/share/x", "a\u0000b"])("%s cannot be resolved with confidence", (raw) => {
    expect(pathReadings(raw, posixRules)).toBeNull();
  });

  it("leaves ordinary names alone", () => {
    expect(pathReadings("routes/posts.$slug.tsx", posixRules)).toEqual(["routes/posts.$slug.tsx"]);
    expect(pathReadings("src/~backup/a.ts", posixRules)).toEqual(["src/~backup/a.ts"]);
    expect(pathReadings("node_modules/@types/node", posixRules)).toEqual(["node_modules/@types/node"]);
    expect(pathReadings("/c/x", posixRules)).toEqual(["/c/x"]);
    expect(pathReadings("file:relative", winRules)).toBeNull();
  });

  it("reads a Git Bash drive path only as the drive for the harnesses that convert it", () => {
    expect(pathReadings("/d/work/a.ts", winRules)).toEqual(["/d/work/a.ts", "D:\\work\\a.ts"]);
    expect(pathReadings("/d/work/a.ts", winRules, { drives: "letter" })).toEqual(["D:\\work\\a.ts"]);
    expect(pathReadings("/d/work/a.ts", winRules, { drives: "pi" })).toEqual(["D:\\work\\a.ts"]);
  });

  it("keeps the plain reading of a drive path the harness does not convert", () => {
    // Claude Code converts only /c/...; /mnt/c/... and /cygdrive/c/... stay paths on the current drive.
    expect(pathReadings("/mnt/d/work/a.ts", winRules, { drives: "letter" })).toEqual(["/mnt/d/work/a.ts", "D:\\work\\a.ts"]);
    expect(pathReadings("/cygdrive/d/a.ts", winRules, { drives: "letter" })).toContain("/cygdrive/d/a.ts");
    expect(pathReadings("/mnt/d/work/a.ts", winRules, { drives: "pi" })).toEqual(["D:\\work\\a.ts"]);
    // pi's expression stops at a line break, so it leaves such a path as it is.
    expect(pathReadings("/d/work/a\u2028b", winRules, { drives: "pi" })).toContain("/d/work/a\u2028b");
  });
});

describe("glob pattern folders (pure)", () => {
  it.each([
    ["**/*.ts", "posix", []],
    ["src/**/*.{ts,tsx}", "posix", ["src/"]],
    ["src/a.ts", "posix", ["src/"]],
    ["/etc/*", "posix", ["/etc/"]],
    ["{/etc,src}/*", "posix", ["/etc/", "src/"]],
    ["!node_modules/**", "posix", ["node_modules/"]],
    ["~/.ssh/*", "posix", ["~/.ssh/"]],
    ["C:/Users/*/AppData/*", "win32", ["C:/Users/"]],
    ["C:\\Users\\*", "win32", ["C:\\Users\\"]],
  ])("%s (%s) reaches %j", (pattern, platform, bases) => {
    expect(patternBases(pattern, platform as Platform)).toEqual(bases);
  });

  it.each(["../*", "src/../../*", "{src,..}/*", "{a,b}{c,d}{e,f}{g,h}{i,j}{k,l}", ".git/*", "sub/.GIT/hooks/*", "{src,.git}/config"])("%s cannot be judged", (pattern) => {
    expect(patternBases(pattern, "posix")).toBeNull();
  });
});

// Synthetic folders that do not exist: on the matching host they go through the filesystem
// (nothing found, so the spelling decides), on the other host through the spelling rules alone.
const SPELLINGS: Record<Platform, { scope: TargetScope; inside: string[]; outside: string[] }> = {
  win32: {
    scope: {
      platform: "win32",
      root: "C:\\aurelhaven-nowhere\\wt\\ab1k2cd3",
      cwd: "C:\\aurelhaven-nowhere\\wt\\ab1k2cd3\\app",
      home: "C:\\Users\\Player",
      env: { USERPROFILE: "C:\\Users\\Player", APPDATA: "C:\\Users\\Player\\AppData\\Roaming" },
    },
    inside: [
      "src/a.ts",
      ".\\src\\a.ts",
      "src\\..\\a.ts",
      "..",
      "",
      "@a.ts",
      "routes/posts.$slug.tsx",
      "C:\\aurelhaven-nowhere\\wt\\ab1k2cd3\\app\\a.ts",
      "C:/aurelhaven-nowhere/wt/ab1k2cd3/b.ts",
      "c:\\aurelhaven-nowhere\\wt\\ab1k2cd3\\c.ts",
      "\\\\?\\C:\\aurelhaven-nowhere\\wt\\ab1k2cd3\\d.ts",
      "a.ts:hidden",
      "C:\\aurelhaven-nowhere\\wt\\ab1k2cd3:stream",
    ],
    outside: [
      "..\\..\\x",
      "C:\\aurelhaven-nowhere\\wt\\ab1k2cd3-evil\\x",
      "C:\\aurelhaven-nowhere\\wt\\ab1k2cd3.\\x",
      "C:\\aurelhaven-nowhere\\wt\\ab1k2cd3 \\x",
      "C:\\aurelhaven-nowhere\\wt\\ab1\u212A2cd3\\x",
      "~\\.ssh\\id_ed25519",
      "~/.bashrc",
      "@~/.gitconfig",
      "@C:\\Users\\Player\\.gitconfig",
      "file:///C:/Users/Player/.bashrc",
      "file://attacker.example/share/x.txt",
      "%USERPROFILE%\\.ssh\\id_ed25519",
      "%APPDATA%\\AgentEmpire\\runtime.json",
      "$env:USERPROFILE\\.gitconfig",
      "/c/Users/Player/.ssh",
      "D:x.txt",
      "\\\\attacker.example\\share\\x",
      "//attacker.example/share/x",
      "\\\\?\\UNC\\attacker.example\\share\\x",
      "\\\\.\\PhysicalDrive0",
      "\\??\\C:\\Windows\\win.ini",
      "nul",
      "CON.txt",
      "src\\com1",
      // The repository's .git, which every worktree shares, by any spelling Windows accepts.
      ".git",
      ".git\\config",
      "sub\\.git\\hooks\\post-commit",
      ".GIT\\config",
      ".git.\\config",
      ".git \\config",
      ".git. .\\hooks",
      "GIT~1\\config",
      ".git::$INDEX_ALLOCATION\\config",
      "C:\\aurelhaven-nowhere\\wt\\ab1k2cd3\\.git",
    ],
  },
  posix: {
    scope: {
      platform: "posix",
      root: "/aurelhaven-nowhere/wt/ab1k2cd3",
      cwd: "/aurelhaven-nowhere/wt/ab1k2cd3/app",
      home: "/home/player",
      env: { HOME: "/home/player", SECRET_DIR: "/srv/secret" },
    },
    inside: [
      "src/a.ts",
      "./src/a.ts",
      "src/../a.ts",
      "..",
      "",
      "@a.ts",
      "routes/posts.$slug.tsx",
      "/aurelhaven-nowhere/wt/ab1k2cd3/app/a.ts",
      ".gitignore",
      ".github/workflows/ci.yml",
      "src/git~1/a.ts",
    ],
    outside: [
      ".git",
      ".git/config",
      "sub/.git/HEAD",
      ".GIT/hooks/pre-commit",
      "src/../.git/config",
      "/aurelhaven-nowhere/wt/ab1k2cd3/.git",
      "../../x",
      "/aurelhaven-nowhere/wt/ab1k2cd3-evil/x",
      "/aurelhaven-nowhere/wt/AB1K2CD3/x",
      "~/.bashrc",
      "~",
      "~root/.ssh/id_ed25519",
      "@/etc/passwd",
      "@~/.ssh",
      "file:///etc/passwd",
      "file://server/share/x",
      "$HOME/.ssh/id_ed25519",
      "${HOME}/x",
      "$SECRET_DIR/x",
      " /etc/passwd",
      "\u00A0/etc/passwd",
      "$(id)/x",
    ],
  },
};

for (const platform of ["win32", "posix"] as const) {
  describe(`verdicts by the ${platform} spelling rules`, () => {
    const { scope, inside, outside } = SPELLINGS[platform];
    it.each(inside)("keeps %j inside", (raw) => {
      expect(targetInside(raw, scope)).toBe(true);
    });
    it.each(outside)("catches %j", (raw) => {
      expect(targetInside(raw, scope)).toBe(false);
    });
  });
}

describe("verdicts on this machine's filesystem", () => {
  const base = mkdtempSync(path.join(os.tmpdir(), "aurelhaven-target-"));
  const data = path.join(base, "data");
  const root = path.join(data, "wt", "ab1k2cd3");
  const cwd = path.join(root, "app");
  const home = path.join(base, "home");
  const outside = path.join(base, "outside");
  const dirLink = win ? "junction" : "dir";
  mkdirSync(path.join(cwd, "src"), { recursive: true });
  mkdirSync(home);
  mkdirSync(outside);
  writeFileSync(path.join(cwd, "notes.md"), "notes\n");
  writeFileSync(path.join(outside, "secret.txt"), "secret\n");
  // A junction (Windows) or directory symlink inside the worktree that leads out of it.
  symlinkSync(outside, path.join(cwd, "linked"), dirLink);
  // A link whose target is gone: writing through it creates the target.
  mkdirSync(path.join(base, "gone"));
  symlinkSync(path.join(base, "gone"), path.join(cwd, "dangling"), dirLink);
  rmSync(path.join(base, "gone"), { recursive: true });
  // A link back to the working folder itself, for link loops.
  symlinkSync(cwd, path.join(cwd, "loop"), dirLink);
  // A .git folder in the worktree, and a link to it under another name.
  mkdirSync(path.join(root, ".git"));
  writeFileSync(path.join(root, ".git", "config"), "[core]\n");
  symlinkSync(path.join(root, ".git"), path.join(cwd, "gitlink"), dirLink);
  // A hard link to a file outside.
  linkSync(path.join(outside, "secret.txt"), path.join(cwd, "hard.txt"));
  // The data folder reached through a link.
  symlinkSync(data, path.join(base, "data-link"), dirLink);
  // File symlinks need Developer Mode or admin rights on Windows.
  let fileLinks = true;
  try {
    symlinkSync(path.join(outside, "secret.txt"), path.join(cwd, "file-link.txt"), "file");
    symlinkSync(path.join(outside, "created.txt"), path.join(cwd, "dangling.txt"), "file");
  } catch {
    fileLinks = false;
  }
  const env = { AURELHAVEN_TEST_OUTSIDE: outside };
  const scope: TargetScope = { cwd, root, home, env };
  const abs = (...parts: string[]) => path.join(cwd, ...parts);
  const posixSlashes = (p: string) => p.replace(/\\/g, "/");

  afterAll(() => rmSync(base, { recursive: true, force: true }));

  const legit: string[] = [
    "notes.md",
    "./notes.md",
    "src/new/deep/file.ts",
    "src/../notes.md",
    "..",
    "",
    "@notes.md",
    "routes/posts.$slug.tsx",
    abs("notes.md"),
    posixSlashes(abs("src", "new.ts")),
    "loop/notes.md",
    ...(win ? [abs("NOTES.md").toUpperCase(), `\\\\?\\${abs("notes.md")}`, "notes.md:Zone.Identifier"] : []),
  ];
  it.each(legit)("keeps %j inside", (raw) => {
    expect(targetInside(raw, scope)).toBe(true);
  });

  const attacks: string[] = [
    "~/.bashrc",
    "~",
    "~/",
    "@~/.gitconfig",
    `@${path.join(outside, "secret.txt")}`,
    pathToFileURL(path.join(outside, "secret.txt")).href,
    `@${pathToFileURL(path.join(outside, "x.txt")).href}`,
    "$AURELHAVEN_TEST_OUTSIDE/x.txt",
    "${AURELHAVEN_TEST_OUTSIDE}/x.txt",
    "$env:AURELHAVEN_TEST_OUTSIDE/x.txt",
    "%AURELHAVEN_TEST_OUTSIDE%/x.txt",
    "$HOME/.ssh/id_ed25519",
    "../../x.txt",
    "../../../outside/secret.txt",
    path.join(outside, "secret.txt"),
    ` ${path.join(outside, "secret.txt")}`,
    `\u00A0${path.join(outside, "secret.txt")}`,
    "linked/secret.txt",
    "linked",
    "linked/new.txt",
    "src/../linked/secret.txt",
    "dangling",
    "dangling/new.txt",
    path.join(base, "data-link", "x.txt"),
    `${"loop/".repeat(50)}notes.md`,
    // The shared .git, named or reached through a link.
    path.join(root, ".git"),
    "../.git/config",
    "gitlink/config",
    "gitlink",
    "loop/gitlink/hooks/post-commit",
    ...(win
      ? [
          `${root}.\\x.txt`,
          path.join(data, "wt", "ab1\u212A2cd3", "x.txt"),
          "nul",
          "aux.ts",
          "\\\\attacker.example\\share\\x.txt",
          "\\\\?\\UNC\\attacker.example\\share\\x.txt",
          "file://attacker.example/share/x.txt",
          "\\\\.\\PhysicalDrive0",
        ]
      : []),
    ...(fileLinks ? ["file-link.txt", "dangling.txt"] : []),
  ];
  it.each(attacks)("catches %j", (raw) => {
    expect(targetInside(raw, scope)).toBe(false);
  });

  it("applies .. after the links: on POSIX the kernel does, on Windows the path is collapsed first", () => {
    expect(targetInside("linked/../notes.md", scope)).toBe(win);
  });

  it("calls a path outside without reading the disk, even one that leads back in through a link", () => {
    // The same worktree through another link to the data folder: the Town Hall does not look
    // past the worktree's own names for it, so it asks.
    expect(targetInside(path.join(base, "data-link", "wt", "ab1k2cd3", "app", "notes.md"), scope)).toBe(false);
  });

  it("counts a hard-linked file as outside for writes only", () => {
    expect(targetInside("hard.txt", { ...scope, write: true })).toBe(false);
    expect(targetInside("hard.txt", scope)).toBe(true);
    expect(targetInside("notes.md", { ...scope, write: true })).toBe(true);
  });

  it("judges a worktree that does not exist yet by its spelling", () => {
    const missing = path.join(base, "data", "wt", "zz9y8x7w");
    expect(targetInside("src/a.ts", { cwd: missing, root: missing, home })).toBe(true);
    expect(targetInside("../ab1k2cd3/app/notes.md", { cwd: missing, root: missing, home })).toBe(false);
  });

  it("follows pi's read into a lookalike spelling of a missing file", () => {
    const quoted = path.join(base, "o'brien", "wt", "ab12cd34");
    mkdirSync(quoted, { recursive: true });
    writeFileSync(path.join(quoted, "real.txt"), "real\n");
    const lookalike = path.join(base, "o\u2019brien", "wt", "ab12cd34");
    mkdirSync(lookalike, { recursive: true });
    writeFileSync(path.join(lookalike, "secret.txt"), "secret\n");
    const there: TargetScope = { cwd: quoted, root: quoted, home };
    expect(reachesOutside("read", { path: "secret.txt" }, there)).toBe(true);
    expect(reachesOutside("read", { path: "real.txt" }, there)).toBe(false);
    expect(reachesOutside("Read", { file_path: path.join(quoted, "secret.txt") }, there)).toBe(false);
  });

  describe("every path field of each harness's tools", () => {
    const outsideGlob = `${posixSlashes(outside)}/*`;
    const msys = win ? `/${cwd[0]!.toLowerCase()}${posixSlashes(cwd.slice(2))}/notes.md` : null;
    const inside70 = Array.from({ length: 70 }, (_, k) => abs("src", `f${k}.ts`));
    const calls: Array<[string, Record<string, unknown>, boolean]> = [
      // Claude Code
      ["Read", { file_path: abs("notes.md") }, false],
      ["Write", { file_path: "~/.bashrc", content: "x" }, true],
      // Its file tools want absolute paths; a relative one would start from the shell's folder.
      ["Read", { file_path: "notes.md" }, true],
      ["Write", { file_path: "src/new.ts", content: "x" }, true],
      ["Edit", { file_path: "./notes.md", old_string: "a", new_string: "b" }, true],
      ["MultiEdit", { file_path: "notes.md", edits: [] }, true],
      ["NotebookEdit", { notebook_path: "nb.ipynb", new_source: "x" }, true],
      ["LS", { path: "src" }, true],
      ["Read", { file_path: "" }, true],
      ...(win ? ([["Read", { file_path: `${cwd.slice(0, 2)}notes.md` }, true]] as Array<[string, Record<string, unknown>, boolean]>) : []),
      ["Grep", { pattern: "x", path: "src" }, false],
      ["Write", { file_path: path.join(root, ".git"), content: "gitdir: evil" }, true],
      ["Write", { file_path: abs("sub", ".git", "config"), content: "[core]" }, true],
      ["Edit", { file_path: abs("gitlink", "config"), old_string: "a", new_string: "b" }, true],
      ["Grep", { pattern: "url", path: path.join(root, ".git") }, true],
      ["Glob", { pattern: "**/.git/config" }, true],
      ["Edit", { file_path: abs("linked", "secret.txt"), old_string: "a", new_string: "b" }, true],
      ["NotebookEdit", { notebook_path: path.join(outside, "nb.ipynb"), new_source: "x" }, true],
      ["Glob", { pattern: "**/*.ts" }, false],
      ["Glob", { pattern: "src/**/*.{ts,tsx}", path: "src" }, false],
      ["Glob", { pattern: outsideGlob }, true],
      ["Glob", { pattern: outsideGlob, path: "src" }, true],
      ["Glob", { pattern: `{${posixSlashes(outside)},src}/*` }, true],
      ["Glob", { pattern: "../*" }, true],
      ["Glob", { pattern: "~/.ssh/*" }, true],
      ["Glob", { pattern: "linked/**" }, true],
      ["Grep", { pattern: "token", path: "~/AppData/Roaming/AgentEmpire", output_mode: "content" }, true],
      ["Grep", { pattern: "/api/users" }, false],
      ["Grep", { pattern: "x", glob: "*.ts" }, false],
      ["Grep", { pattern: "x", glob: outsideGlob }, true],
      ["LS", { path: "linked" }, true],
      // pi
      ["write", { path: "~/.bashrc", content: "x" }, true],
      ["edit", { path: `@${path.join(outside, "secret.txt")}`, edits: [] }, true],
      ["read", { path: pathToFileURL(path.join(outside, "secret.txt")).href }, true],
      ["ls", {}, false],
      ["ls", { path: "~" }, true],
      ["find", { pattern: "*.pem", path: "~" }, true],
      ["find", { pattern: "src/**/*.spec.ts" }, false],
      ["grep", { pattern: "token", path: "@~" }, true],
      ["grep", { pattern: "x", glob: "**/*.ts" }, false],
      ...(msys ? ([["write", { path: msys, content: "x" }, false], ["mcp__files__write", { path: msys }, true]] as Array<[string, Record<string, unknown>, boolean]>) : []),
      // pi resolves a relative path against its own folder, which never moves.
      ["read", { path: "notes.md" }, false],
      ["write", { path: ".git/config", content: "x" }, true],
      // Codex
      ["apply_patch", { path: abs("a.txt"), changes: [abs("a.txt")] }, false],
      ["apply_patch", { path: abs("a.txt"), changes: [abs("a.txt"), path.join(outside, "b.txt")] }, true],
      ["apply_patch", { path: abs("linked"), changes: [abs("a.txt")] }, true],
      // A patch may touch any number of files inside; only one outside makes it reach out.
      ["apply_patch", { path: inside70[0], changes: inside70 }, false],
      ["apply_patch", { path: inside70[0], changes: [...inside70, path.join(outside, "b.txt")] }, true],
      ["apply_patch", { path: abs("a.txt"), changes: [abs(".git", "config")] }, true],
      ["apply_patch", { path: abs("a.txt"), changes: "a.txt" }, true],
      ["shell", { command: "npm test", cwd }, false],
      ["shell", { command: "npm test", cwd: outside }, true],
      ["shell", { command: "git status", cwd: path.join(root, ".git") }, true],
      // MCP and anything else: the common path fields
      ["mcp__files__read", { paths: ["notes.md", path.join(outside, "secret.txt")] }, true],
      ["mcp__files__read", { path: 3 }, true],
      ["mcp__files__read", { paths: Array.from({ length: 1000 }, () => "notes.md") }, true],
      ["mcp__web__fetch", { url: "https://example.org/a/b" }, false],
      ["Bash", { command: "cat ~/.ssh/id_ed25519" }, false],
      // MCP tools: any field whose name says it holds a path.
      ["mcp__filesystem__move_file", { source: abs("notes.md"), destination: path.join(outside, "x.md") }, true],
      ["mcp__filesystem__move_file", { source: path.join(outside, "secret.txt"), destination: abs("moved.md") }, true],
      ["mcp__filesystem__move_file", { source: abs("notes.md"), destination: abs("moved.md") }, false],
      ["mcp__git__git_status", { repo_path: outside }, true],
      ["mcp__files__copy", { targetDir: outside }, true],
      ["mcp__files__read", { fileUri: pathToFileURL(path.join(outside, "secret.txt")).href }, true],
      ["mcp__files__read", { file_paths: [abs("notes.md"), path.join(outside, "secret.txt")] }, true],
      ["mcp__notes__add", { content: path.join(outside, "secret.txt"), title: "x" }, false],
      ["mcp__deploy__run", { target: 5, source: { kind: "git" } }, false],
    ];
    it.each(calls)("%s %j reaches outside: %s", (tool, input, expected) => {
      expect(reachesOutside(tool, input, scope)).toBe(expected);
    });

    it("ignores inputs that are not objects", () => {
      expect(reachesOutside("Write", "~/.bashrc", scope)).toBe(false);
      expect(reachesOutside("Write", null, scope)).toBe(false);
    });
  });

  it("keeps Codex's stricter rules and follows links for it too", () => {
    expect(insideWorkspace("src/a.ts", cwd, root)).toBe(true);
    expect(insideWorkspace("linked/x.txt", cwd, root)).toBe(false);
    expect(insideWorkspace("dangling", cwd, root)).toBe(false);
    expect(insideWorkspace(".git/hooks", cwd, root)).toBe(false);
    expect(insideWorkspace("gitlink", cwd, root)).toBe(false);
    for (const raw of ["", "  ", "~/x", "$UNSET_THING/x", "%UNSET_THING%\\x", "a$b"]) expect(insideWorkspace(raw, cwd, root)).toBe(false);
  });
});
