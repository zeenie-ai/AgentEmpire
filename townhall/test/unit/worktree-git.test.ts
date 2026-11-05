import { existsSync, readFileSync, realpathSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Git, isDotGit, TOWN_HALL_IDENTITY, worktreeGitDir } from "../../src/core/workspace.js";
import { git, makeRepo, markCommand, plantRepo, replaceFile, writeMarkHooks } from "../helpers/git.js";
import { removeRoot, tempRoot } from "../helpers/harness.js";

function errorOf(fn: () => unknown): { code?: string; message: string } {
  try {
    fn();
  } catch (err) {
    return err as { code?: string; message: string };
  }
  throw new Error("expected an error");
}

describe("the check of a worktree's .git", () => {
  let root: string;
  let repo: string;
  let common: string;
  let marks: string;
  let count = 0;

  beforeAll(() => {
    root = tempRoot("wt-pointer");
    repo = makeRepo(root, "repo");
    common = path.join(repo, ".git");
    marks = path.join(root, "marks.txt");
  });

  afterAll(() => removeRoot(root));

  /** A new worktree of the repository, as `git worktree add` makes it. */
  function addWorktree(...config: string[]): string {
    const wt = path.join(root, `wt${++count}`);
    git(repo, ...config, "worktree", "add", "-q", "-b", `task${count}`, wt, "HEAD");
    return wt;
  }

  function expectRefused(wt: string, why: RegExp): void {
    const err = errorOf(() => worktreeGitDir(wt, common));
    expect(err.code).toBe("WORKSPACE_DENIED");
    expect(err.message).toMatch(/the work folder's \.git was changed/);
    expect(err.message).toMatch(why);
  }

  it("returns the git folder that git worktree add made", () => {
    const wt = addWorktree();
    const made = realpathSync.native(path.resolve(git(wt, "rev-parse", "--path-format=absolute", "--git-dir")));
    expect(worktreeGitDir(wt, common)).toBe(made);
  });

  it("follows the links both ways when git wrote them relative (worktree.useRelativePaths)", () => {
    const wt = addWorktree("-c", "worktree.useRelativePaths=true");
    expect(worktreeGitDir(wt, common)).toBe(realpathSync.native(path.join(common, "worktrees", path.basename(wt))));
  });

  it("refuses a .git aimed at a repository planted in the worktree", () => {
    const wt = addWorktree();
    plantRepo(path.join(wt, "evil"), "ref: refs/heads/main", marks);
    replaceFile(path.join(wt, ".git"), "gitdir: evil\n");
    expectRefused(wt, /not one of the repository's worktrees/);
    // The planted folder may even name this .git back, as git's own folder for it does.
    writeFileSync(path.join(wt, "evil", "gitdir"), `${path.join(wt, ".git")}\n`);
    replaceFile(path.join(wt, ".git"), `gitdir: ${path.join(wt, "evil")}\n`);
    expectRefused(wt, /not one of the repository's worktrees/);
  });

  it("refuses a network or device path before touching it", () => {
    const wt = addWorktree();
    for (const target of ["//example.invalid/share/repo/.git/worktrees/x", "\\\\?\\C:\\repo\\.git\\worktrees\\x"]) {
      replaceFile(path.join(wt, ".git"), `gitdir: ${target}\n`);
      if (process.platform === "win32") expectRefused(wt, /a network or device path/);
      else expect(errorOf(() => worktreeGitDir(wt, common)).code).toBe("WORKSPACE_DENIED");
    }
  });

  it("refuses the git folder of another worktree of the same repository", () => {
    const wt = addWorktree();
    const other = addWorktree();
    replaceFile(path.join(wt, ".git"), readFileSync(path.join(other, ".git")));
    expectRefused(wt, /another worktree/);
  });

  it("refuses a .git that is a folder, a link, missing or unreadable", () => {
    const folder = addWorktree();
    unlinkSync(path.join(folder, ".git"));
    plantRepo(path.join(folder, ".git"), "ref: refs/heads/main", marks);
    expectRefused(folder, /no longer a plain file/);

    const linked = addWorktree();
    const pointer = path.join(linked, ".git");
    const copy = path.join(root, "pointer-copy");
    writeFileSync(copy, readFileSync(pointer));
    unlinkSync(pointer);
    let made = true;
    try {
      symlinkSync(copy, pointer, "file");
    } catch {
      made = false; // Windows without Developer Mode cannot make file links
    }
    if (made) expectRefused(linked, /no longer a plain file/);

    const gone = addWorktree();
    unlinkSync(path.join(gone, ".git"));
    expectRefused(gone, /missing/);

    const garbled = addWorktree();
    for (const text of ["", "gitdir:evil\n", "gitdir: \n", `gitdir: ${path.join(common, "worktrees", path.basename(garbled))}\nmore\n`]) {
      replaceFile(path.join(garbled, ".git"), text);
      expect(errorOf(() => worktreeGitDir(garbled, common)).code).toBe("WORKSPACE_DENIED");
    }
    replaceFile(path.join(garbled, ".git"), "x".repeat(10_000));
    expectRefused(garbled, /no longer names a git folder/);
  });
});

describe("the Town Hall's git settings", () => {
  let root: string;
  let hooksDir: string;
  let gitRunner: Git;

  beforeAll(() => {
    root = tempRoot("git-settings");
    hooksDir = path.join(root, "data", "no-hooks");
    gitRunner = new Git(0, async () => undefined, hooksDir);
  });

  afterAll(() => removeRoot(root));

  it("runs no fsmonitor command and no hook from the repository's own config", async () => {
    // What an approved `git config` command could leave in the repository that worktrees share.
    const repo = makeRepo(root, "hostile");
    const marks = path.join(root, "marks.txt");
    git(repo, "config", "core.fsmonitor", `${markCommand("fsmonitor", marks)}; false`);
    writeMarkHooks(path.join(repo, ".git", "hooks"), marks);
    writeFileSync(path.join(repo, "change.txt"), "a change\n");

    await gitRunner.run(repo, ["add", "-A"]);
    await gitRunner.run(repo, ["status", "--porcelain", "-z"]);
    await gitRunner.run(repo, [...TOWN_HALL_IDENTITY, "commit", "--no-verify", "-q", "-m", "change"]);
    expect(existsSync(marks)).toBe(false);
    expect((await gitRunner.run(repo, ["log", "-1", "--format=%s"])).stdout.trim()).toBe("change");

    // The same commands without the Town Hall's settings run both.
    writeFileSync(path.join(repo, "change.txt"), "another change\n");
    git(repo, "add", "-A");
    git(repo, "-c", "user.name=Test Player", "-c", "user.email=player@example.invalid", "commit", "--no-verify", "-q", "-m", "again");
    const ran = readFileSync(marks, "utf8");
    expect(ran).toContain("fsmonitor");
    expect(ran).toContain("post-commit");
  });

  it("names its settings on the command line, where they win over every config file", async () => {
    const repo = makeRepo(root, "plain");
    git(repo, "config", "protocol.ext.allow", "always");
    git(repo, "config", "submodule.recurse", "true");
    const get = async (key: string) => (await gitRunner.run(repo, ["config", "--get", key])).stdout.trim();
    expect(await get("core.fsmonitor")).toBe("false");
    expect(await get("core.hooksPath")).toBe(hooksDir);
    expect(await get("protocol.ext.allow")).toBe("never");
    expect(await get("submodule.recurse")).toBe("false");
  });

  it("refuses to run while its hooks folder holds anything", async () => {
    const repo = makeRepo(root, "hooks-folder");
    writeFileSync(path.join(hooksDir, "post-commit"), "#!/bin/sh\n");
    await expect(gitRunner.run(repo, ["status"])).rejects.toThrow(/must be an empty folder/);
    rmSync(path.join(hooksDir, "post-commit"));
    await expect(gitRunner.run(repo, ["status"])).resolves.toMatchObject({ code: 0 });
  });
});

describe("spellings of .git", () => {
  it("covers every name that is or may stand for .git, and nothing else", () => {
    for (const name of [".git", ".GIT", ".Git", ".git.", ".git ", ".git. .", "GIT~1", "git~1"]) expect(isDotGit(name), name).toBe(true);
    for (const name of ["git", ".github", ".gitignore", ".git2", "x.git", "GIT~2", ".", ""]) expect(isDotGit(name), name).toBe(false);
  });
});
