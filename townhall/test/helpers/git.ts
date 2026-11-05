import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";

const IDENTITY = ["-c", "user.name=Test Player", "-c", "user.email=player@example.invalid", "-c", "commit.gpgsign=false"];

export function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-c", "core.longpaths=true", ...args], { cwd, encoding: "utf8", windowsHide: true })
    .replace(/\r\n/g, "\n")
    .trim();
}

/** A fresh repository on branch main with one commit. */
export function makeRepo(parent: string, name: string, files: Record<string, string> = { "README.md": "# Test repo\n" }): string {
  const dir = path.join(parent, name);
  mkdirSync(dir, { recursive: true });
  git(dir, "init", "-q", "-b", "main");
  // Byte-for-byte comparisons need line endings git leaves alone, whatever the machine's global config.
  git(dir, "config", "core.autocrlf", "false");
  for (const [rel, content] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    writeFileSync(path.join(dir, rel), content);
  }
  git(dir, "add", "-A");
  git(dir, ...IDENTITY, "commit", "-q", "-m", "initial");
  return dir;
}

export function commitAll(dir: string, message: string): void {
  git(dir, "add", "-A");
  git(dir, ...IDENTITY, "commit", "-q", "-m", message);
}

/**
 * Replaces a file. Windows marks a worktree's `.git` hidden, and a hidden file cannot be opened
 * for truncation, so the old file is removed first.
 */
export function replaceFile(file: string, content: string | Buffer): void {
  rmSync(file, { force: true });
  writeFileSync(file, content);
}

/**
 * A shell command that appends `what` to the file `marks`, standing in for what a hostile git
 * config or hook would run. git runs these through its sh (Git for Windows too), which takes `/`.
 */
export function markCommand(what: string, marks: string): string {
  return `echo ${what} >> '${marks.replace(/\\/g, "/")}'`;
}

/** Hooks that git commands run on their own, even with `--no-verify`. */
export const MARK_HOOKS = [
  "pre-commit",
  "prepare-commit-msg",
  "commit-msg",
  "post-commit",
  "post-checkout",
  "post-merge",
  "pre-merge-commit",
  "post-index-change",
  "reference-transaction",
  "pre-auto-gc",
];

/** Writes each of `MARK_HOOKS` into `dir`, leaving a mark in `marks` when it runs. */
export function writeMarkHooks(dir: string, marks: string): void {
  mkdirSync(dir, { recursive: true });
  for (const hook of MARK_HOOKS) writeFileSync(path.join(dir, hook), `#!/bin/sh\n${markCommand(hook, marks)}\n`, { mode: 0o755 });
}

/**
 * A repository config whose commands leave a mark in `marks` when git runs them: an fsmonitor
 * command, an external diff, a textconv and a clean filter named `mark`, and the ssh command of a
 * partial clone's remote, which git runs to fetch an object it is missing (such as HEAD's).
 */
export function markConfig(marks: string): string {
  const lines = [
    "[core]",
    "\trepositoryformatversion = 1",
    `\tfsmonitor = "${markCommand("fsmonitor", marks)}; false"`,
    `\tsshCommand = "${markCommand("ssh", marks)}; false"`,
    "[extensions]",
    "\tpartialClone = origin",
    '[remote "origin"]',
    "\turl = ssh://example.invalid/planted",
    "\tpromisor = true",
    "[diff]",
    `\texternal = "${markCommand("external-diff", marks)}"`,
    '[diff "mark"]',
    `\ttextconv = "${markCommand("textconv", marks)}; cat"`,
    '[filter "mark"]',
    `\tclean = "${markCommand("filter", marks)}; cat"`,
  ];
  return `${lines.join("\n")}\n`;
}

/**
 * Writes a minimal repository into the folder `gitDir` with plain file writes, as an agent can:
 * its HEAD reads `head`, and its config (`markConfig`) and hooks leave a mark in `marks`.
 */
export function plantRepo(gitDir: string, head: string, marks: string): void {
  for (const dir of ["objects/info", "refs/heads"]) {
    mkdirSync(path.join(gitDir, dir), { recursive: true });
    writeFileSync(path.join(gitDir, dir, ".keep"), "");
  }
  writeFileSync(path.join(gitDir, "HEAD"), `${head}\n`);
  writeFileSync(path.join(gitDir, "config"), markConfig(marks));
  writeMarkHooks(path.join(gitDir, "hooks"), marks);
}

/** Content hashes of every file in the working tree, excluding .git. */
export function treeHashes(dir: string): Map<string, string> {
  const out = new Map<string, string>();
  const walk = (rel: string) => {
    for (const e of readdirSync(path.join(dir, rel), { withFileTypes: true })) {
      if (e.name === ".git") continue;
      const r = path.join(rel, e.name);
      if (e.isDirectory()) walk(r);
      else out.set(r.replace(/\\/g, "/"), createHash("sha256").update(readFileSync(path.join(dir, r))).digest("hex"));
    }
  };
  walk("");
  return out;
}
