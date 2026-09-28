import { z } from "zod";

export const ErrorCode = z.enum([
  "AUTH_FAILED",
  "BAD_REQUEST",
  "NOT_FOUND",
  "INSUFFICIENT_RESOURCES",
  "INSUFFICIENT_MANA",
  "AGE_REQUIRED",
  "RANK_REQUIRED",
  "LIMIT_REACHED",
  "INVALID_STATE",
  "CONFLICT",
  "PROVIDER_UNAVAILABLE",
  "WORKSPACE_DENIED",
  "SESSION_BUSY",
  "INTERNAL",
]);
export type ErrorCode = z.infer<typeof ErrorCode>;

export const ErrorBody = z.object({
  code: ErrorCode,
  message: z.string(),
  retryable: z.boolean(),
});
export type ErrorBody = z.infer<typeof ErrorBody>;

/** An error that is reported to the client with a protocol error code. */
export class TownError extends Error {
  constructor(
    readonly code: ErrorCode,
    message: string,
    readonly retryable = false,
  ) {
    super(message);
    this.name = "TownError";
  }

  toBody(): ErrorBody {
    return { code: this.code, message: this.message, retryable: this.retryable };
  }
}

export function isTownError(err: unknown): err is TownError {
  return err instanceof TownError;
}

export const fail = {
  badRequest: (m: string) => new TownError("BAD_REQUEST", m),
  notFound: (what: string, id: string) => new TownError("NOT_FOUND", `${what} ${id} not found`),
  invalidState: (m: string) => new TownError("INVALID_STATE", m),
  conflict: (m: string) => new TownError("CONFLICT", m),
  limit: (m: string) => new TownError("LIMIT_REACHED", m),
  age: (m: string) => new TownError("AGE_REQUIRED", m),
  rank: (m: string) => new TownError("RANK_REQUIRED", m),
  resources: (m: string) => new TownError("INSUFFICIENT_RESOURCES", m),
  mana: (m: string) => new TownError("INSUFFICIENT_MANA", m, true),
  workspace: (m: string) => new TownError("WORKSPACE_DENIED", m),
  provider: (m: string) => new TownError("PROVIDER_UNAVAILABLE", m, true),
  internal: (m: string) => new TownError("INTERNAL", m, true),
};
