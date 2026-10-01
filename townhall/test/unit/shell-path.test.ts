import { describe, expect, it } from "vitest";
import { commonBinDirs, userPath, type ShellRunner } from "../../src/providers/common/shell-path.js";

const HOME = "/Users/player";
const MINIMAL = "/usr/bin:/bin:/usr/sbin:/sbin";

function runner(output: string | null, calls: Array<{ shell: string; args: string[] }> = []): ShellRunner {
  return (shell, args) => {
    calls.push({ shell, args });
    return output;
  };
}

describe("userPath", () => {
  it("leaves Windows alone and never starts a shell", () => {
    const calls: Array<{ shell: string; args: string[] }> = [];
    expect(userPath({ PATH: "C:\\Windows;C:\\tools" }, "win32", runner("x", calls), HOME)).toBe("C:\\Windows;C:\\tools");
    expect(calls).toHaveLength(0);
  });

  it("puts the login shell's PATH first, then the inherited one, then common folders", () => {
    const calls: Array<{ shell: string; args: string[] }> = [];
    const out = "Welcome back!\n__AURELHAVEN_PATH__/opt/homebrew/bin:/Users/player/.local/bin:/usr/bin__AURELHAVEN_PATH__";
    const result = userPath({ PATH: MINIMAL, SHELL: "/bin/zsh" }, "darwin", runner(out, calls), HOME)!.split(":");
    expect(result.slice(0, 3)).toEqual(["/opt/homebrew/bin", "/Users/player/.local/bin", "/usr/bin"]);
    expect(result).toContain("/sbin");
    expect(result).toContain("/Users/player/.claude/local");
    expect(new Set(result).size).toBe(result.length);
    expect(calls[0].shell).toBe("/bin/zsh");
    expect(calls[0].args[0]).toBe("-ilc");
  });

  it("falls back to the inherited PATH and common folders when the shell fails", () => {
    const result = userPath({ PATH: MINIMAL }, "linux", runner(null), "/home/player")!.split(":");
    expect(result.slice(0, 4)).toEqual(["/usr/bin", "/bin", "/usr/sbin", "/sbin"]);
    expect(result).toContain("/home/player/.local/bin");
    expect(result).toContain("/snap/bin");
    expect(result).not.toContain("/opt/homebrew/bin");
  });

  it("ignores shell output without the markers", () => {
    const result = userPath({ PATH: MINIMAL }, "darwin", runner("/evil/bin:/usr/bin"), HOME)!.split(":");
    expect(result).not.toContain("/evil/bin");
  });

  it("uses a default shell when SHELL is missing or relative", () => {
    const calls: Array<{ shell: string; args: string[] }> = [];
    userPath({ PATH: MINIMAL, SHELL: "zsh" }, "darwin", runner(null, calls), HOME);
    userPath({ PATH: MINIMAL }, "linux", runner(null, calls), HOME);
    expect(calls.map((c) => c.shell)).toEqual(["/bin/zsh", "/bin/sh"]);
  });
});

describe("commonBinDirs", () => {
  it("names Homebrew's folder on macOS only", () => {
    expect(commonBinDirs(HOME, "darwin")).toContain("/opt/homebrew/bin");
    expect(commonBinDirs(HOME, "linux")).not.toContain("/opt/homebrew/bin");
  });
});
