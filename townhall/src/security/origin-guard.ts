export interface OriginPolicy {
  port: number;
  /** Extra allowed origins, for example a Godot editor web preview. */
  devOrigins: string[];
}

export type GuardResult = { ok: true } | { ok: false; reason: string };

const LOOPBACK_HOSTS = ["127.0.0.1", "localhost"];

/** The Host header must name the loopback address and our port (blocks DNS rebinding). */
export function checkHost(host: string | undefined, port: number): GuardResult {
  if (!host) return { ok: false, reason: "missing Host header" };
  const normalized = host.trim().toLowerCase();
  const allowed = LOOPBACK_HOSTS.map((h) => `${h}:${port}`);
  if (allowed.includes(normalized)) return { ok: true };
  return { ok: false, reason: `Host ${host} not allowed` };
}

function normalizeOrigin(origin: string): string | null {
  try {
    const u = new URL(origin);
    if (u.origin === "null") return null;
    return u.origin.toLowerCase();
  } catch {
    return null;
  }
}

export function ownOrigins(port: number): string[] {
  return LOOPBACK_HOSTS.map((h) => `http://${h}:${port}`);
}

/**
 * Origin must be absent (desktop client), the Town Hall's own origin, or a configured
 * development origin. The literal "null" origin (sandboxed frames, file://) is refused.
 */
export function checkOrigin(origin: string | undefined, policy: OriginPolicy): GuardResult {
  if (origin === undefined) return { ok: true };
  const trimmed = origin.trim();
  if (trimmed === "" || trimmed.toLowerCase() === "null") return { ok: false, reason: "null Origin refused" };
  const normalized = normalizeOrigin(trimmed);
  if (!normalized) return { ok: false, reason: `Origin ${origin} is malformed` };
  const allowed = new Set(ownOrigins(policy.port));
  for (const dev of policy.devOrigins) {
    const n = normalizeOrigin(dev);
    if (n) allowed.add(n);
  }
  if (allowed.has(normalized)) return { ok: true };
  return { ok: false, reason: `Origin ${origin} not allowed` };
}
