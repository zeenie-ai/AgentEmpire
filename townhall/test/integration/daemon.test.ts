import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { TestTown } from "../helpers/harness.js";

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
});
