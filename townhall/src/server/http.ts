import { createReadStream, existsSync, statSync } from "node:fs";
import http, { type IncomingMessage, type ServerResponse } from "node:http";
import type { Duplex } from "node:stream";
import path from "node:path";
import type { Logger } from "../log.js";
import { DAEMON_VERSION, PROTOCOL_MAJOR, PROTOCOL_MINOR } from "../protocol/version.js";
import { checkHost, checkOrigin } from "../security/origin-guard.js";
import { currentPlatform, isInside } from "../security/path-guard.js";

export const MIME_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".htm": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".wasm": "application/wasm",
  ".pck": "application/octet-stream",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json",
  ".manifest": "application/manifest+json",
  ".css": "text/css; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".webp": "image/webp",
  ".txt": "text/plain; charset=utf-8",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".wav": "audio/wav",
  ".ogg": "audio/ogg",
  ".mp3": "audio/mpeg",
};

export interface HttpOptions {
  webDir: string;
  crossOriginIsolation: boolean;
  devOrigins: string[];
  log: Logger;
  port: () => number;
  onUpgrade: (req: IncomingMessage, socket: Duplex, head: Buffer) => void;
}

/** index.html and the Godot data pack must always be revalidated after a new export. */
export function cacheControlFor(file: string): string {
  const base = path.basename(file).toLowerCase();
  if (base === "index.html" || base.endsWith(".pck")) return "no-cache";
  return "public, max-age=300";
}

function pickEncoding(acceptEncoding: string | undefined, file: string): { file: string; encoding: string | null } {
  const accepted = (acceptEncoding ?? "")
    .split(",")
    .map((s) => s.trim().split(";")[0]!.toLowerCase());
  if (accepted.includes("br") && existsSync(`${file}.br`)) return { file: `${file}.br`, encoding: "br" };
  if (accepted.includes("gzip") && existsSync(`${file}.gz`)) return { file: `${file}.gz`, encoding: "gzip" };
  return { file, encoding: null };
}

function plain(res: ServerResponse, status: number, text: string): void {
  res.writeHead(status, { "Content-Type": "text/plain; charset=utf-8", "X-Content-Type-Options": "nosniff" });
  res.end(text);
}

export function serveStatic(req: IncomingMessage, res: ServerResponse, opts: Pick<HttpOptions, "webDir" | "crossOriginIsolation">): void {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.setHeader("Allow", "GET, HEAD");
    plain(res, 405, "method not allowed");
    return;
  }
  let pathname: string;
  try {
    pathname = decodeURIComponent(new URL(req.url ?? "/", "http://127.0.0.1").pathname);
  } catch {
    plain(res, 400, "bad path");
    return;
  }
  if (pathname.includes("\0")) {
    plain(res, 400, "bad path");
    return;
  }
  if (pathname.endsWith("/")) pathname += "index.html";
  const root = path.resolve(opts.webDir);
  let file = path.resolve(root, `.${pathname}`);
  if (!isInside(file, root, currentPlatform())) {
    plain(res, 404, "not found");
    return;
  }
  try {
    if (statSync(file).isDirectory()) file = path.join(file, "index.html");
  } catch {
    // handled below
  }
  if (!existsSync(file) || !statSync(file).isFile()) {
    plain(res, 404, existsSync(root) ? "not found" : "The web client has not been exported yet.");
    return;
  }
  const type = MIME_TYPES[path.extname(file).toLowerCase()] ?? "application/octet-stream";
  const chosen = pickEncoding(req.headers["accept-encoding"], file);
  const stat = statSync(chosen.file);
  const etag = `"${stat.size.toString(16)}-${Math.floor(stat.mtimeMs).toString(16)}${chosen.encoding ? `-${chosen.encoding}` : ""}"`;
  const headers: Record<string, string> = {
    "Content-Type": type,
    "Cache-Control": cacheControlFor(file),
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    ETag: etag,
    Vary: "Accept-Encoding",
  };
  if (chosen.encoding) headers["Content-Encoding"] = chosen.encoding;
  if (opts.crossOriginIsolation) {
    headers["Cross-Origin-Opener-Policy"] = "same-origin";
    headers["Cross-Origin-Embedder-Policy"] = "require-corp";
  }
  if (req.headers["if-none-match"] === etag) {
    res.writeHead(304, headers);
    res.end();
    return;
  }
  headers["Content-Length"] = String(stat.size);
  res.writeHead(200, headers);
  if (req.method === "HEAD") {
    res.end();
    return;
  }
  const stream = createReadStream(chosen.file);
  stream.on("error", () => res.destroy());
  stream.pipe(res);
}

export function createHttpServer(opts: HttpOptions): http.Server {
  const server = http.createServer((req, res) => {
    const host = checkHost(req.headers.host, opts.port());
    if (!host.ok) {
      plain(res, 403, "forbidden");
      return;
    }
    const pathname = (req.url ?? "/").split("?")[0];
    if (pathname === "/healthz") {
      res.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
      res.end(JSON.stringify({ ok: true, daemon_version: DAEMON_VERSION, protocol: { major: PROTOCOL_MAJOR, minor: PROTOCOL_MINOR } }));
      return;
    }
    if (pathname === "/ws") {
      plain(res, 426, "upgrade required");
      return;
    }
    serveStatic(req, res, opts);
  });

  server.on("upgrade", (req, socket, head) => {
    const refuse = (status: number, reason: string) => {
      opts.log.warn({ reason }, "websocket upgrade refused");
      socket.write(`HTTP/1.1 ${status} ${status === 403 ? "Forbidden" : "Not Found"}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
      socket.destroy();
    };
    const pathname = (req.url ?? "/").split("?")[0];
    if (pathname !== "/ws") return refuse(404, "unknown path");
    const host = checkHost(req.headers.host, opts.port());
    if (!host.ok) return refuse(403, host.reason);
    const origin = checkOrigin(req.headers.origin, { port: opts.port(), devOrigins: opts.devOrigins });
    if (!origin.ok) return refuse(403, origin.reason);
    opts.onUpgrade(req, socket, head);
  });
  return server;
}
