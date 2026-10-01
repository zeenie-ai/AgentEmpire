import { execFileSync } from "node:child_process";
import os from "node:os";
import path from "node:path";

/** Runs a shell with arguments and returns its standard output, or null when it fails or times out. */
export type ShellRunner = (shell: string, args: string[], timeoutMs: number) => string | null;

const defaultRunner: ShellRunner = (shell, args, timeoutMs) => {
  try {
    return execFileSync(shell, args, { encoding: "utf8", timeout: timeoutMs, stdio: ["ignore", "pipe", "ignore"] });
  } catch {
    return null;
  }
};

/** Brackets the PATH in the shell's output, so a greeting printed by the shell's startup files is ignored. */
const MARK = "__AURELHAVEN_PATH__";
const SHELL_TIMEOUT_MS = 5000;

/** Folders where Claude Code, Codex, pi and Node.js are commonly installed on macOS and Linux. */
export function commonBinDirs(home: string, platform: NodeJS.Platform): string[] {
  const dirs = [
    path.posix.join(home, ".local", "bin"),
    path.posix.join(home, ".claude", "local"),
    path.posix.join(home, ".npm-global", "bin"),
    path.posix.join(home, ".bun", "bin"),
    path.posix.join(home, ".volta", "bin"),
    "/usr/local/bin",
  ];
  if (platform === "darwin") dirs.push("/opt/homebrew/bin");
  else dirs.push("/home/linuxbrew/.linuxbrew/bin", "/snap/bin");
  return dirs;
}

/**
 * The PATH the Town Hall should run with. On macOS and Linux a game opened from Finder or a
 * desktop launcher passes on a minimal PATH (/usr/bin:/bin:...) that misses where the harnesses
 * and Node.js usually live, so neither the harnesses nor the commands agents run (npm test, say)
 * would be found. This puts the user's login shell PATH (what a terminal would have) first, then
 * the inherited one, then common install folders. Windows passes on the full PATH already, so it
 * is returned unchanged.
 */
export function userPath(
  env: NodeJS.ProcessEnv,
  platform: NodeJS.Platform = process.platform,
  run: ShellRunner = defaultRunner,
  home: string = os.homedir(),
): string | undefined {
  if (platform === "win32") return env.PATH;
  const dirs: string[] = [];
  const add = (list: string | undefined) => {
    for (const raw of (list ?? "").split(":")) {
      const dir = raw.trim();
      if (dir !== "" && !dirs.includes(dir)) dirs.push(dir);
    }
  };
  const shell = env.SHELL && path.posix.isAbsolute(env.SHELL) ? env.SHELL : platform === "darwin" ? "/bin/zsh" : "/bin/sh";
  const out = run(shell, ["-ilc", `printf '${MARK}%s${MARK}' "$PATH"`], SHELL_TIMEOUT_MS);
  const found = out ? new RegExp(`${MARK}(.*?)${MARK}`, "s").exec(out) : null;
  if (found) add(found[1]);
  add(env.PATH);
  add(commonBinDirs(home, platform).join(":"));
  return dirs.join(":");
}
