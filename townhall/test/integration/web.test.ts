import { mkdirSync, writeFileSync } from "node:fs";
import http from "node:http";
import path from "node:path";
import { brotliCompressSync, gzipSync } from "node:zlib";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { tempRoot, TestTown } from "../helpers/harness.js";

interface Res {
  status: number;
  headers: http.IncomingHttpHeaders;
  body: Buffer;
}

function get(port: number, urlPath: string, headers: Record<string, string> = {}): Promise<Res> {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, path: urlPath, headers }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (d: Buffer) => chunks.push(d));
      res.on("end", () => resolve({ status: res.statusCode ?? 0, headers: res.headers, body: Buffer.concat(chunks) }));
    });
    req.on("error", reject);
    req.end();
  });
}

function makeExport(root: string): void {
  const web = path.join(root, "web");
  mkdirSync(web, { recursive: true });
  writeFileSync(path.join(web, "index.html"), "<!doctype html><title>Aurelhaven</title>");
  writeFileSync(path.join(web, "index.js"), "console.log('engine')");
  const wasm = Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]);
  writeFileSync(path.join(web, "index.wasm"), wasm);
  writeFileSync(path.join(web, "index.wasm.br"), brotliCompressSync(wasm));
  writeFileSync(path.join(web, "index.pck"), Buffer.from("GDPC"));
  writeFileSync(path.join(web, "index.pck.gz"), gzipSync(Buffer.from("GDPC")));
  writeFileSync(path.join(root, "secret.txt"), "do not serve");
}

describe("serving the web export", () => {
  let town: TestTown;
  let isolated: TestTown;

  beforeAll(async () => {
    const root = tempRoot("web");
    makeExport(root);
    town = await TestTown.start("web", { root });
    const root2 = tempRoot("web-coi");
    makeExport(root2);
    isolated = await TestTown.start("web-coi", { root: root2, config: { crossOriginIsolation: true } });
  });

  afterAll(async () => {
    await town.stop();
    await isolated.stop();
  });

  it("serves index.html without caching", async () => {
    const r = await get(town.port, "/");
    expect(r.status).toBe(200);
    expect(r.headers["content-type"]).toBe("text/html; charset=utf-8");
    expect(r.headers["cache-control"]).toBe("no-cache");
    expect(r.headers["cross-origin-opener-policy"]).toBeUndefined();
    expect(r.body.toString()).toContain("Aurelhaven");
  });

  it("serves wasm as application/wasm, precompressed with brotli when accepted", async () => {
    const plain = await get(town.port, "/index.wasm");
    expect(plain.headers["content-type"]).toBe("application/wasm");
    expect(plain.headers["content-encoding"]).toBeUndefined();
    expect(plain.body).toEqual(Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]));
    const br = await get(town.port, "/index.wasm", { "Accept-Encoding": "gzip, deflate, br" });
    expect(br.headers["content-type"]).toBe("application/wasm");
    expect(br.headers["content-encoding"]).toBe("br");
    expect(br.headers.vary).toBe("Accept-Encoding");
  });

  it("serves the pck with no-cache and gzip when that is all that exists", async () => {
    const r = await get(town.port, "/index.pck", { "Accept-Encoding": "gzip, br" });
    expect(r.headers["cache-control"]).toBe("no-cache");
    expect(r.headers["content-encoding"]).toBe("gzip");
    expect(r.headers["content-type"]).toBe("application/octet-stream");
  });

  it("caches other files briefly and answers If-None-Match with 304", async () => {
    const r = await get(town.port, "/index.js");
    expect(r.headers["content-type"]).toBe("text/javascript; charset=utf-8");
    expect(r.headers["cache-control"]).toBe("public, max-age=300");
    const again = await get(town.port, "/index.js", { "If-None-Match": String(r.headers.etag) });
    expect(again.status).toBe(304);
  });

  it("never serves files outside the export folder", async () => {
    expect((await get(town.port, "/../secret.txt")).status).toBe(404);
    expect((await get(town.port, "/%2e%2e/secret.txt")).status).toBe(404);
    expect((await get(town.port, "/nothing-here.js")).status).toBe(404);
  });

  it("adds COOP/COEP only behind the config flag", async () => {
    const r = await get(isolated.port, "/");
    expect(r.headers["cross-origin-opener-policy"]).toBe("same-origin");
    expect(r.headers["cross-origin-embedder-policy"]).toBe("require-corp");
  });
});
