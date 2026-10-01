import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { packageRoot } from "../../src/paths.js";
import { makeRepo } from "../helpers/git.js";
import { removeRoot, sleep, summonAgent, tempRoot, TestClient, TestTown } from "../helpers/harness.js";

describe("the shutdown command (protocol 1.3)", () => {
  it("replies, tells the client, pauses a running task, and the task resumes after the next start", async () => {
    const town = await TestTown.start("shutdown");
    try {
      const c = await town.client();
      const agentId = await summonAgent(c, { workspace: makeRepo(town.work, "app") });
      const { task_id: taskId } = await c.ok("assign_task", {
        agent_id: agentId,
        title: "Wait for a hint",
        prompt: "[fake:nudge] Wait for a hint",
        size: "S",
        courier: { mode: "express" },
      });
      await c.waitTask(taskId, "running");
      const seen = c.lastSeq();
      const runtimeFile = path.join(town.config.dataDir, "runtime.json");
      expect(existsSync(runtimeFile)).toBe(true);

      expect(await c.ok("shutdown", {})).toEqual({});
      const closed = await c.closed;
      expect(closed.code).toBe(1001);
      // The notice is transient: it carries the current seq without advancing it.
      const notice = c.events.find((e) => e.type === "daemon_shutdown");
      expect(notice?.seq).toBe(seen);
      await town.daemon.stopped;
      expect(existsSync(runtimeFile)).toBe(false);
      // Nothing was finished or failed: the run was only stopped.
      expect(c.events.filter((e) => e.type === "task_updated" && e.seq > seen)).toHaveLength(0);

      // The next start recovers the task the way a restart does, and it carries on.
      await town.restart();
      const c2 = await town.client({ last_seq: seen });
      const paused = await c2.waitTask(taskId, "paused");
      expect(paused.payload.task.state_reason).toBe("restart");
      await c2.waitTask(taskId, "running", 20_000);
      await c2.ok("nudge_task", { task_id: taskId, message: "Here is your hint." });
      const review = await c2.waitTask(taskId, "awaiting_review");
      expect(review.payload.task.attempt).toBe(1);
      await c2.close();
    } finally {
      await town.stop();
    }
  });

  it("ends the Town Hall process with code 0 and removes runtime.json and the discovery copy", async () => {
    const root = tempRoot("shutdown-proc");
    const dataDir = path.join(root, "data");
    const runtimeFile = path.join(dataDir, "runtime.json");
    const discovery = path.join(root, "config", "Aurelhaven", "runtime.json");
    const child = spawn(process.execPath, ["--import", "tsx", path.join("src", "main.ts")], {
      cwd: packageRoot(),
      env: {
        ...process.env,
        AURELHAVEN_DATA_DIR: dataDir,
        AURELHAVEN_DISCOVERY_FILE: discovery,
        AURELHAVEN_PORT: "0",
        AURELHAVEN_PROVIDER: "fake",
        AURELHAVEN_WORK_ROOTS: root,
        AURELHAVEN_LOG_LEVEL: "warn",
      },
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    let output = "";
    child.stdout.on("data", (d: Buffer) => (output += d.toString()));
    child.stderr.on("data", (d: Buffer) => (output += d.toString()));
    const exited = new Promise<number | null>((resolve) => child.once("exit", (code) => resolve(code)));
    try {
      for (let i = 0; i < 150 && !existsSync(runtimeFile); i++) await sleep(100);
      expect(existsSync(runtimeFile), output).toBe(true);
      const runtime = JSON.parse(readFileSync(runtimeFile, "utf8")) as { pid: number; port: number; token: string };
      expect(runtime.pid).toBe(child.pid);
      expect(JSON.parse(readFileSync(discovery, "utf8"))).toEqual(runtime);

      const c = await TestClient.connect(runtime.port);
      expect((await c.hello(runtime.token)).ok).toBe(true);
      expect(await c.ok("shutdown", {})).toEqual({});
      const code = await Promise.race([exited, sleep(20_000).then(() => "timeout")]);
      expect(code, output).toBe(0);
      expect(existsSync(runtimeFile)).toBe(false);
      expect(existsSync(discovery)).toBe(false);
      expect((await c.closed).code).toBe(1001);
    } finally {
      if (child.exitCode === null) child.kill();
      await Promise.race([exited, sleep(5_000)]);
      removeRoot(root);
    }
  });
});
