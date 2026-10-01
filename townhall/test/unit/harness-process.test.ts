import { existsSync, writeFileSync } from "node:fs";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { Launch } from "../../src/providers/common/exec.js";
import { HarnessProcess, runCapture, waitAny } from "../../src/providers/common/process.js";
import { removeRoot, tempRoot } from "../helpers/harness.js";

// A harness that starts a long-lived program which inherits its stdout (as a shell command, a
// dev server or a build server can), writes that program's pid, and exits with code 3. The
// program is detached: on Windows, Node ends its own non-detached children when it exits. It
// runs in the system temp folder, not the test's, so it never holds the test folder open (a
// process's working folder cannot be removed on Windows, even for a moment after it is killed).
const LEAVES_A_PROGRAM_BEHIND = `
import { spawn } from "node:child_process";
import os from "node:os";
const child = spawn(process.execPath, ["-e", "setTimeout(() => {}, 60000)"], { stdio: "inherit", windowsHide: true, detached: true, cwd: os.tmpdir() });
child.unref();
process.stdout.write(JSON.stringify({ grandchild: child.pid }) + "\\n", () => process.exit(3));
`;

describe("harness processes", () => {
  let root: string;
  const leftovers: number[] = [];
  const launch = (script: string): Launch => ({ file: process.execPath, prefix: [script], source: "env", display: script });
  const write = (name: string, body: string) => {
    const file = path.join(root, name);
    writeFileSync(file, body);
    return file;
  };
  const start = (script: string, records: unknown[] = []) =>
    new HarnessProcess(launch(script), [], { cwd: root, env: process.env, onRecord: (r) => records.push(r) });

  beforeAll(() => {
    root = tempRoot("proc");
  });
  afterAll(async () => {
    for (const pid of leftovers) {
      try {
        process.kill(pid);
      } catch {
        // already gone
      }
    }
    const deadline = Date.now() + 5_000;
    while (leftovers.some(alive) && Date.now() < deadline) await new Promise((r) => setTimeout(r, 50));
    removeRoot(root);
    expect(existsSync(root)).toBe(false);
  });

  it("finishes soon after the harness exits, even while a program it started holds its output open", async () => {
    const records: unknown[] = [];
    const began = Date.now();
    const proc = start(write("parent.mjs", LEAVES_A_PROGRAM_BEHIND), records);
    const exit = await proc.exited;
    // Not at once (the pipe stayed open, so the short drain wait ran), and not after a minute.
    expect(Date.now() - began).toBeGreaterThanOrEqual(1_000);
    expect(Date.now() - began).toBeLessThan(10_000);
    expect(exit).toEqual({ code: 3, signal: null, spawnError: null });
    expect(proc.running).toBe(false);
    const grandchild = (records[0] as { grandchild: number }).grandchild;
    leftovers.push(grandchild);
    // It really did outlive the harness while holding the pipe.
    expect(alive(grandchild)).toBe(true);
    // A kill after the exit signals nothing: the id may already belong to another process.
    await proc.kill();
    expect(proc.forced).toBe(false);
    expect(alive(grandchild)).toBe(true);
  });

  it("probes finish soon after the program exits, for the same reason", async () => {
    const began = Date.now();
    const r = await runCapture(launch(write("probe.mjs", LEAVES_A_PROGRAM_BEHIND)), [], { env: process.env, timeoutMs: 30_000 });
    expect(Date.now() - began).toBeLessThan(10_000);
    expect(r).toMatchObject({ code: 3, timedOut: false, error: null });
    leftovers.push((JSON.parse(r.stdout.trim()) as { grandchild: number }).grandchild);
  });

  it("reports a launch that throws at once as a spawn error, and never throws itself", async () => {
    const proc = new HarnessProcess(launch("unused"), ["bad\u0000arg"], { cwd: root, env: process.env, onRecord: () => undefined });
    const exit = await proc.exited;
    expect(exit.spawnError).toMatch(/null bytes|ERR_INVALID_ARG_VALUE/);
    expect(proc.running).toBe(false);
    expect(proc.send({ a: 1 })).toBe(false);
    await proc.kill();
    expect(await proc.stop(10)).toEqual(exit);
    expect(proc.forced).toBe(false);
  });

  it("stops a harness that exits at the end of its input without forcing it", async () => {
    const records: unknown[] = [];
    const proc = start(write("echo.mjs", "process.stdin.pipe(process.stdout);\n"), records);
    expect(proc.send({ hello: "town" })).toBe(true);
    const exit = await proc.stop(10_000);
    expect(exit).toMatchObject({ code: 0, spawnError: null });
    expect(proc.forced).toBe(false);
    expect(records).toEqual([{ hello: "town" }]);
  });

  it("forces a harness that ignores the end of its input and polite requests, and says so", async () => {
    const proc = start(write("stubborn.mjs", 'process.on("SIGTERM", () => undefined);\nprocess.stdin.resume();\nsetInterval(() => undefined, 1000);\n'));
    await proc.stop(200);
    expect(proc.running).toBe(false);
    expect(proc.forced).toBe(true);
  });

  it("waits for the first promise or the time limit, whichever is sooner", async () => {
    const began = Date.now();
    await waitAny([Promise.reject(new Error("settled")), new Promise(() => undefined)], 10_000);
    await waitAny([new Promise(() => undefined)], 50);
    expect(Date.now() - began).toBeLessThan(5_000);
  });
});

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}
