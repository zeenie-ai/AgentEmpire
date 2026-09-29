import type { Env } from "./exec.js";

/**
 * Variables a parent agent session sets for its own child processes. When the Town Hall is
 * started from inside Claude Code, Codex or pi they would leak into the harnesses it launches
 * and make them believe they are nested (or hand them another session's messaging token).
 */
const INHERITED_SESSION_VARS: RegExp[] = [
  /^CLAUDECODE$/,
  /^CLAUDE_CODE_(ENTRYPOINT|SESSION_ID|CHILD_SESSION|SESSION_ATTENDED|MESSAGING_SOCKET|MESSAGING_TOKEN|EXECPATH|SSE_PORT|ENABLE_SDK_FILE_CHECKPOINTING|ENABLE_TASKS)$/,
  /^CLAUDE_(PID|EFFORT|AGENT_SDK_VERSION)$/,
  /^MCP_CONNECTION_NONBLOCKING$/,
  /^AI_AGENT$/,
  /^PI_(CODING_AGENT|SESSION_ID|SESSION_FILE|PROVIDER|MODEL|REASONING_LEVEL)$/,
  /^CODEX_(THREAD_ID|SANDBOX|SANDBOX_NETWORK_DISABLED|MANAGED_BY_NPM|MANAGED_BY_BUN|MANAGED_BY_PNPM|MANAGED_PACKAGE_ROOT)$/,
];

/** The environment for a harness: the Town Hall's own, minus parent-session markers, plus `extra`. */
export function harnessEnv(base: Env, extra: Record<string, string> = {}): Env {
  const env: Env = {};
  for (const [key, value] of Object.entries(base)) {
    if (value === undefined) continue;
    if (INHERITED_SESSION_VARS.some((re) => re.test(key))) continue;
    env[key] = value;
  }
  return { ...env, ...extra };
}
