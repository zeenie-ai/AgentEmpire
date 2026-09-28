import { describe, expect, it } from "vitest";
import { checkHost, checkOrigin } from "../../src/security/origin-guard.js";

describe("Host guard", () => {
  it("accepts the loopback names with our port only", () => {
    expect(checkHost("127.0.0.1:4100", 4100).ok).toBe(true);
    expect(checkHost("localhost:4100", 4100).ok).toBe(true);
    expect(checkHost("LOCALHOST:4100", 4100).ok).toBe(true);
    expect(checkHost("127.0.0.1:4101", 4100).ok).toBe(false);
    expect(checkHost("127.0.0.1", 4100).ok).toBe(false);
    expect(checkHost("evil.example:4100", 4100).ok).toBe(false);
    expect(checkHost("127.0.0.1.evil.example:4100", 4100).ok).toBe(false);
    expect(checkHost("[::1]:4100", 4100).ok).toBe(false);
    expect(checkHost(undefined, 4100).ok).toBe(false);
  });
});

describe("Origin guard", () => {
  const policy = { port: 4100, devOrigins: ["http://localhost:8060"] };

  it("accepts an absent Origin (desktop client), our own origin and dev origins", () => {
    expect(checkOrigin(undefined, policy).ok).toBe(true);
    expect(checkOrigin("http://127.0.0.1:4100", policy).ok).toBe(true);
    expect(checkOrigin("http://localhost:4100", policy).ok).toBe(true);
    expect(checkOrigin("http://LOCALHOST:4100", policy).ok).toBe(true);
    expect(checkOrigin("http://localhost:8060", policy).ok).toBe(true);
  });

  it("refuses null, empty, foreign, other-port, other-scheme and malformed origins", () => {
    expect(checkOrigin("null", policy).ok).toBe(false);
    expect(checkOrigin("", policy).ok).toBe(false);
    expect(checkOrigin("http://evil.example", policy).ok).toBe(false);
    expect(checkOrigin("http://127.0.0.1:4101", policy).ok).toBe(false);
    expect(checkOrigin("https://127.0.0.1:4100", policy).ok).toBe(false);
    expect(checkOrigin("http://localhost:4100.evil.example", policy).ok).toBe(false);
    expect(checkOrigin("not a url", policy).ok).toBe(false);
    expect(checkOrigin("file://", policy).ok).toBe(false);
  });
});
