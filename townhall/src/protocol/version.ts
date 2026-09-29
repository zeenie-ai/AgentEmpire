export const PROTOCOL_MAJOR = 1;
export const PROTOCOL_MINOR = 1;
export const ENVELOPE_VERSION = 1;
export const DAEMON_VERSION = "0.1.0";

export const MAX_FRAME_BYTES = 1024 * 1024;
export const HELLO_TIMEOUT_MS = 5_000;
export const IDEMPOTENCY_TTL_MS = 10 * 60 * 1000;
export const MAX_REQUEST_ID_LENGTH = 128;
export const TASK_PROGRESS_MIN_INTERVAL_MS = 500;
export const ACTIVITY_TEXT_MAX_BYTES = 2 * 1024;
export const APPROVAL_PREVIEW_MAX_BYTES = 4 * 1024;
export const DIFF_PATCH_MAX_BYTES = 512 * 1024;
export const RECENT_TASKS_IN_STATE = 50;
export const TOWN_SAVES_KEPT = 20;
export const PRE_APPROVAL_TTL_MS = 10 * 60 * 1000;

export const CloseCode = {
  BAD_TOKEN: 4001,
  NO_HELLO: 4002,
  PROTOCOL_MISMATCH: 4400,
  REPLACED: 4409,
} as const;
