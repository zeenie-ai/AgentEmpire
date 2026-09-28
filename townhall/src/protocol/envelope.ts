import { z } from "zod";
import { ErrorBody } from "./errors.js";
import { ENVELOPE_VERSION, MAX_REQUEST_ID_LENGTH } from "./version.js";

export const CommandEnvelope = z.object({
  v: z.literal(ENVELOPE_VERSION),
  type: z.string().min(1).max(64),
  request_id: z.string().min(1).max(MAX_REQUEST_ID_LENGTH),
  payload: z.unknown().optional(),
});
export type CommandEnvelope = z.infer<typeof CommandEnvelope>;

export const ReplyEnvelope = z.union([
  z.object({
    v: z.literal(ENVELOPE_VERSION),
    type: z.string(),
    request_id: z.string(),
    ok: z.literal(true),
    payload: z.unknown(),
  }),
  z.object({
    v: z.literal(ENVELOPE_VERSION),
    type: z.string(),
    request_id: z.string(),
    ok: z.literal(false),
    error: ErrorBody,
  }),
]);
export type ReplyEnvelope = z.infer<typeof ReplyEnvelope>;

export const EventEnvelope = z.object({
  v: z.literal(ENVELOPE_VERSION),
  type: z.string(),
  seq: z.number().int().min(1),
  id: z.string(),
  time: z.string(),
  subject: z.string().nullable(),
  causation_id: z.string().nullable(),
  payload: z.unknown(),
});
export type EventEnvelope = z.infer<typeof EventEnvelope>;

export function replyOk(type: string, requestId: string, payload: unknown): ReplyEnvelope {
  return { v: ENVELOPE_VERSION, type: `${type}_result`, request_id: requestId, ok: true, payload };
}

export function replyError(type: string, requestId: string, error: ErrorBody): ReplyEnvelope {
  return { v: ENVELOPE_VERSION, type: `${type}_result`, request_id: requestId, ok: false, error };
}

/** Formats zod issues without decorative glyphs. */
export function formatIssues(error: z.ZodError, max = 5): string {
  return error.issues
    .slice(0, max)
    .map((i) => `${i.path.length ? i.path.join(".") : "(root)"}: ${i.message}`)
    .join("; ");
}
