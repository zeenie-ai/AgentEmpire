import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
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
