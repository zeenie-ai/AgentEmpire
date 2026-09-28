const REDACTED = "[REDACTED]";

const PATTERNS: RegExp[] = [
  /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g,
  /\bsk-ant-[A-Za-z0-9_-]{10,}/g,
  /\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}/g,
  /\bgh[pousr]_[A-Za-z0-9]{20,}/g,
  /\bgithub_pat_[A-Za-z0-9_]{20,}/g,
  /\bxox[abposr]-[A-Za-z0-9-]{10,}/g,
  /\bAKIA[0-9A-Z]{16}\b/g,
  /\bAIza[0-9A-Za-z_-]{30,}/g,
  /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g,
];

// key=value / key: value pairs whose key names a secret.
const KEYED = /((?:api[_-]?key|secret|token|password|passwd|pwd|auth(?:orization)?|client[_-]?secret|access[_-]?key)["']?\s*[:=]\s*["']?)([^\s"',;]{4,})/gi;
const BEARER = /\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}/g;

const SECRET_ENV_NAMES = [
  "ANTHROPIC_API_KEY",
  "OPENAI_API_KEY",
  "CODEX_API_KEY",
  "CLAUDE_CODE_OAUTH_TOKEN",
  "GITHUB_TOKEN",
  "GH_TOKEN",
];

export class Redactor {
  private readonly literals: string[];

  constructor(extraSecrets: string[] = [], env: Record<string, string | undefined> = process.env) {
    const fromEnv = SECRET_ENV_NAMES.map((n) => env[n]).filter((v): v is string => !!v && v.length >= 8);
    this.literals = [...new Set([...extraSecrets.filter((s) => s.length >= 8), ...fromEnv])];
  }

  addSecret(secret: string): void {
    if (secret.length >= 8 && !this.literals.includes(secret)) this.literals.push(secret);
  }

  redact(text: string): string {
    let out = text;
    for (const lit of this.literals) out = out.split(lit).join(REDACTED);
    for (const p of PATTERNS) out = out.replace(p, REDACTED);
    out = out.replace(BEARER, (_m, scheme: string) => `${scheme} ${REDACTED}`);
    out = out.replace(KEYED, (_m, prefix: string) => `${prefix}${REDACTED}`);
    return out;
  }
}

/** What Buffer#toString produces for a UTF-8 sequence cut in half. */
const REPLACEMENT_CHAR = String.fromCharCode(0xfffd);

/** Truncates to at most `maxBytes` UTF-8 bytes, keeping the start. */
export function capBytes(text: string, maxBytes: number, marker = "...[truncated]"): string {
  if (Buffer.byteLength(text, "utf8") <= maxBytes) return text;
  const budget = Math.max(0, maxBytes - Buffer.byteLength(marker, "utf8"));
  let cut = Buffer.from(text, "utf8").subarray(0, budget).toString("utf8");
  // Drop a trailing partial character produced by the byte cut.
  if (cut.endsWith(REPLACEMENT_CHAR)) cut = cut.slice(0, -1);
  return cut + marker;
}

/** Keeps the last `maxBytes` UTF-8 bytes (for command output tails). */
export function tailBytes(text: string, maxBytes: number): string {
  const buf = Buffer.from(text, "utf8");
  if (buf.length <= maxBytes) return text;
  let tail = buf.subarray(buf.length - maxBytes).toString("utf8");
  if (tail.startsWith(REPLACEMENT_CHAR)) tail = tail.slice(1);
  return tail;
}
