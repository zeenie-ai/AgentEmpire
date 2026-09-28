import http from "node:http";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { TestClient, TestTown } from "../helpers/harness.js";

function get(port: number, path: string, host: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, path, headers: { Host: host } }, (res) => {
      res.resume();
      resolve(res.statusCode ?? 0);
    });
    req.on("error", reject);
    req.end();
  });
}

describe("connection security", () => {
  let town: TestTown;

  beforeAll(async () => {
    town = await TestTown.start("auth", { config: { devOrigins: ["http://localhost:8060"] } });
  });

  afterAll(async () => {
    await town.stop();
  });

  it("closes with 4001 on a bad token", async () => {
    const c = await TestClient.connect(town.port);
    const r = await c.hello("not-the-token");
    expect(r.ok).toBe(false);
    expect(r.error?.code).toBe("AUTH_FAILED");
    expect((await c.closed).code).toBe(4001);
  });

  it("closes with 4001 when the token is missing", async () => {
    const c = await TestClient.connect(town.port);
    const r = await c.send("hello", { protocol: { major: 1, minor: 0 }, client: { name: "x", version: "1", platform: "web" } });
    expect(r.error?.code).toBe("AUTH_FAILED");
    expect((await c.closed).code).toBe(4001);
  });

  it("refuses a foreign Origin and the null Origin at the upgrade", async () => {
    await expect(TestClient.connect(town.port, { origin: "http://evil.example" })).rejects.toThrow(/403/);
    await expect(TestClient.connect(town.port, { origin: "null" })).rejects.toThrow(/403/);
  });

  it("accepts no Origin, its own origin and a configured dev origin", async () => {
    for (const origin of [undefined, `http://127.0.0.1:${town.port}`, `http://localhost:${town.port}`, "http://localhost:8060"]) {
      const c = await TestClient.connect(town.port, origin ? { origin } : {});
      const r = await c.hello(town.token);
      expect(r.ok).toBe(true);
      await c.close();
    }
  });

  it("refuses a foreign Host header for the WebSocket and for HTTP", async () => {
    await expect(TestClient.connect(town.port, { host: `evil.example:${town.port}` })).rejects.toThrow(/403/);
    await expect(TestClient.connect(town.port, { host: `127.0.0.1:${town.port + 1}` })).rejects.toThrow(/403/);
    expect(await get(town.port, "/healthz", `evil.example:${town.port}`)).toBe(403);
    expect(await get(town.port, "/healthz", `localhost:${town.port}`)).toBe(200);
  });

  it("closes with 4002 when no hello arrives within 5 s", async () => {
    const c = await TestClient.connect(town.port);
    town.clock.advance(4_900);
    expect(c.closeInfo).toBeNull();
    town.clock.advance(200);
    expect((await c.closed).code).toBe(4002);
  });

  it("closes with 4002 when the first frame is not a hello", async () => {
    const c = await TestClient.connect(town.port);
    void c.send("get_state", {}).catch(() => undefined);
    expect((await c.closed).code).toBe(4002);
  });

  it("closes with 4400 on a protocol major mismatch", async () => {
    const c = await TestClient.connect(town.port);
    const r = await c.hello(town.token, { protocol: { major: 2, minor: 0 } });
    expect(r.ok).toBe(false);
    expect((await c.closed).code).toBe(4400);
  });

  it("serves healthz without the token and refuses commands before hello", async () => {
    expect(await get(town.port, "/healthz", `127.0.0.1:${town.port}`)).toBe(200);
    expect(await get(town.port, "/ws", `127.0.0.1:${town.port}`)).toBe(426);
  });
});
