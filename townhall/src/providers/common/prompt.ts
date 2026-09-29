import type { RunRequest } from "../types.js";

/** Role and size names from economy.json, for the task framing. */
export interface FramingNames {
  roles: Record<string, { name: string; plain?: string | undefined }>;
  sizes: Record<string, { name: string }>;
}

export interface FramingOptions {
  names: FramingNames;
  /** Extra lines under "How you work", such as the shell the harness uses on this platform. */
  notes?: string[];
}

/**
 * The text appended to the harness's own system prompt: the task framing (who the agent is,
 * the rules of the town, the task title and acceptance criteria) and the player's Oath.
 */
export function systemPromptFor(req: RunRequest, opts: FramingOptions): string {
  const role = opts.names.roles[req.role];
  const roleText = role ? `${role.name}${role.plain ? ` (${role.plain})` : ""}` : req.role;
  const size = opts.names.sizes[req.size]?.name ?? req.size;
  const lines: string[] = [
    "# Aurelhaven",
    `You are an agent of the town of Aurelhaven. Your role: ${roleText}. The player gives you tasks and reviews your work.`,
    "",
    "## How you work",
    `- Your work folder is ${req.cwd}. Stay inside ${req.workspaceRoot}: do not read or change anything outside it.`,
    "- The Town Hall checks every action against the player's approval rules, and some actions wait for the player. When an action is denied, respect the reason: find another way within the rules, or stop and explain.",
    "- Do not push to remotes, and never throw work away or rewrite git history (no hard resets, forced checkouts, stashes, cleans or force pushes). The Town Hall records your changes when you finish.",
    "- When the task is done, end with a short summary of what you changed and anything the player should check.",
    ...(opts.notes ?? []).map((n) => `- ${n}`),
    "",
    `## Task: ${req.title}`,
    `Size: ${size}.`,
  ];
  if (req.acceptance.length > 0) {
    lines.push("Acceptance criteria:", ...req.acceptance.map((a) => `- ${a}`));
  } else {
    lines.push("No acceptance criteria were given; use your judgement about when the task is done.");
  }
  const oath = req.instructions.trim();
  if (oath) lines.push("", "## Your Oath (the player's standing instructions)", oath);
  return lines.join("\n");
}

/** Wraps send_back feedback as the first message of a resumed session. */
export function feedbackMessage(feedback: string): string {
  return [
    "The player reviewed your work on this task and sent it back with this feedback:",
    "",
    feedback.trim(),
    "",
    "Address the feedback, then end with a short summary of what you changed.",
  ].join("\n");
}

/** The first message of an attempt. */
export function firstMessageFor(req: RunRequest, resumedSession: boolean): string {
  const feedback = req.resume?.feedback?.trim() || null;
  if (resumedSession) {
    if (feedback) return feedbackMessage(feedback);
    return "The Town Hall paused this task and has now resumed it. Continue from where you stopped; if the task is already complete, end with a short summary of what you changed.";
  }
  if (feedback) {
    // The earlier session could not be resumed: start over with the task and the feedback.
    return `${req.prompt}\n\nThe player reviewed an earlier attempt at this task and sent it back with this feedback:\n\n${feedback}`;
  }
  return req.prompt;
}

/** A nudge sent while the agent works. */
export function nudgeMessage(message: string): string {
  return `Message from the player: ${message.trim()}`;
}
