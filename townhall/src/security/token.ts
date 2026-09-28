import { randomBytes, timingSafeEqual } from "node:crypto";

/** A fresh 32-byte launch token, base64url so it can travel in a URL fragment. */
export function generateToken(): string {
  return randomBytes(32).toString("base64url");
}

export function tokensEqual(expected: string, given: unknown): boolean {
  if (typeof given !== "string") return false;
  const a = Buffer.from(expected, "utf8");
  const b = Buffer.from(given, "utf8");
  if (a.length !== b.length) {
    // Compare anyway so the timing does not reveal the length check.
    timingSafeEqual(a, a);
    return false;
  }
  return timingSafeEqual(a, b);
}
