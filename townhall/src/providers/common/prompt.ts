import type { RunEvent, RunRequest } from "../types.js";

/** Role and size names from economy.json, for the task framing. */
export interface FramingNames {
  roles: Record<string, { name: string; plain?: string | undefined }>;
  sizes: Record<string, { name: string }>;
}

export interface FramingOptions {
  names: FramingNames;
  /** Extra lines under "How you work", such as the shell the harness uses on this platform. */
  notes?: string[];
  /** A party lead's town tools, as the harness names them; without them the lead has no party section. */
  partyTools?: { delegate: string; status: string; collect: string };
}

/** The "Your party" section for a lead whose harness offers the town tools. */
function partySection(req: RunRequest, opts: FramingOptions): string[] {
  const tools = opts.partyTools;
  if (!req.party || req.depth > 0 || !tools) return [];
  const members = req.party.members.map((m) => {
    const role = opts.names.roles[m.role];
    return `- ${m.name}: ${role ? `${role.name}${role.plain ? ` (${role.plain})` : ""}` : m.role}, on ${m.provider}`;
  });
  return [
    "",
    "## Your party",
    "You lead a party for this task. Its members:",
    ...(members.length > 0 ? members : ["- (none right now)"]),
    `- Hand a part of the task to a member with ${tools.delegate}: give a title and a prompt with everything they need, because they cannot see this conversation or your folder. It returns at once; carry on with your own part meanwhile.`,
    `- ${tools.status} shows how their sub-tasks are doing; ${tools.collect} waits for them and returns each member's summary and changed files.`,
    "- Each member works in their own folder and asks the player before acting, as you do. Their Mana comes out of this task's Mana Seal. Their changes are merged when the player accepts this task.",
    "- Before you finish, collect every sub-task's result, then end with one summary of the whole party's work.",
  ];
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
    ...(req.depth > 0
      ? ["- This is a sub-task your party lead delegated to you: do this part only. Your summary goes back to the lead, who combines the party's work."]
      : []),
    ...(opts.notes ?? []).map((n) => `- ${n}`),
    ...partySection(req, opts),
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

/**
 * Tells the player that a nudge arrived while the run was already ending, so the agent never
 * saw it. Deferred so it follows the supervisor's own note of the nudge.
 */
export function notDelivered(emit: (event: RunEvent) => void): void {
  setImmediate(() => emit({ kind: "activity", activity: "system", text: "The agent was already finishing, so the message was not delivered." }));
}
