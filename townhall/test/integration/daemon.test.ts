import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import net, { type AddressInfo } from "node:net";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { removeRoot, tempRoot, TestTown } from "../helpers/harness.js";

/** A live process that is not a Town Hall. */
function otherProgram(): ChildProcess {
  return spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
}

/** A port on 127.0.0.1 that nothing listens on (a moment ago it was free). */
async function closedPort(): Promise<number> {
  const server = net.createServer().listen(0, "127.0.0.1");
  await once(server, "listening");
  const port = (server.address() as AddressInfo).port;
  server.close();
  await once(server, "close");
  return port;
}

function writeOldRuntime(root: string, pid: number, port: number): void {
  mkdirSync(path.join(root, "data"), { recursive: true });
  const info = { pid, port, token: "old-token", url: `http://127.0.0.1:${port}/#t=old-token`, data_dir: path.join(root, "data") };
  writeFileSync(path.join(root, "data", "runtime.json"), JSON.stringify(info));
}

describe("daemon lifecycle", () => {
  it("writes runtime.json with a fresh 32-byte token per launch and removes it on a clean stop", async () => {
    const town = await TestTown.start("daemon");
    const file = path.join(town.config.dataDir, "runtime.json");
    const first = JSON.parse(readFileSync(file, "utf8")) as { pid: number; port: number; token: string; url: string };
    expect(first.pid).toBe(process.pid);
    expect(first.port).toBe(town.port);
    expect(Buffer.from(first.token, "base64url")).toHaveLength(32);
    expect(first.url).toBe(`http://127.0.0.1:${first.port}/#t=${first.token}`);

    await town.restart();
    const second = JSON.parse(readFileSync(file, "utf8")) as { token: string };
    expect(second.token).not.toBe(first.token);

    // The database survives the restart; events keep their sequence.
    const c = await town.client();
    const state = await c.ok("get_state");
    expect(state.treasury).toEqual({ food: 200, wood: 200, stone: 150, gold: 100 });
    await c.close();

    await town.daemon.stop();
    expect(existsSync(file)).toBe(false);
    await town.stop();
  });

  it("starts over a runtime.json left by a killed Town Hall whose process id now belongs to another program", async () => {
    const root = tempRoot("stale-runtime");
    const other = otherProgram();
    try {
      writeOldRuntime(root, other.pid!, await closedPort());
      const town = await TestTown.start("stale-runtime", { root });
      const now = JSON.parse(readFileSync(path.join(root, "data", "runtime.json"), "utf8")) as { pid: number; port: number };
      expect(now.pid).toBe(process.pid);
      expect(now.port).toBe(town.port);
      await town.stop();
    } finally {
      other.kill();
      removeRoot(root);
    }
  });

  it("refuses to start while the Town Hall named in runtime.json still answers", async () => {
    const root = tempRoot("busy-runtime");
    const other = otherProgram();
    const server = net.createServer().listen(0, "127.0.0.1");
    await once(server, "listening");
    try {
      writeOldRuntime(root, other.pid!, (server.address() as AddressInfo).port);
      await expect(TestTown.start("busy-runtime", { root })).rejects.toThrow(/another Town Hall/);
    } finally {
      server.close();
      other.kill();
      removeRoot(root);
    }
  });
});
