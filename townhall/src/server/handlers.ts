import { existsSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import type { Ctx } from "../core/context.js";
import { fail } from "../protocol/errors.js";
import { canonicalDrive, checkInputPath, displayPath, isInside, realpathOrNull } from "../security/path-guard.js";
import type { Handlers } from "./router.js";

const MAX_BROWSE_ENTRIES = 500;

export function getState(ctx: Ctx) {
  return {
    seq: ctx.bus.currentSeq(),
    age: ctx.ages.state(),
    treasury: ctx.treasury.balance(),
    mana: ctx.mana.state(),
    agents: ctx.agents.list(),
    tools: ctx.tools.list(),
    tasks: ctx.tasks.listForState(),
    approvals: ctx.approvals.listOpen(),
    parties: ctx.parties.list(),
    incidents: ctx.incidents.listOpen(),
    town: ctx.town.latestRef(),
    settings: ctx.settings.get(),
    providers: ctx.providers.cached(),
    progress: ctx.progress.snapshot(),
  };
}

/** What the handlers need from the process that owns the Town Hall. */
export interface DaemonControl {
  /** The `shutdown` command: stop after the reply has gone out. */
  requestShutdown(): void;
}

/** Lists sub-folders inside the allowed work roots for the summoning dialog's folder browser. */
export function browseFolder(ctx: Ctx, requested: string | null) {
  const policy = ctx.pathPolicy;
  const roots = policy.allowedRoots.map(displayPath);
  const isRepo = (dir: string) => existsSync(path.join(dir, ".git"));
  if (!requested) {
    return {
      path: null,
      parent: null,
      entries: policy.allowedRoots
        .filter((r) => existsSync(r))
        .map((r) => ({ name: displayPath(r), path: displayPath(r), is_git_repo: isRepo(r) })),
      roots,
    };
  }
  const lexical = checkInputPath(requested, policy.platform);
  if (!lexical.ok) throw fail.workspace(lexical.reason);
  const real = realpathOrNull(lexical.path);
  if (!real) throw fail.notFound("folder", requested);
  const dir = canonicalDrive(real, policy.platform);
  const insideRoot = policy.allowedRoots.some((r) => isInside(dir, r, policy.platform));
  if (!insideRoot) throw fail.workspace("the folder is outside the allowed work roots");
  if (isInside(dir, policy.dataDir, policy.platform)) throw fail.workspace("the Town Hall data folder cannot be browsed");
  if (policy.systemDirs.some((s) => isInside(dir, s, policy.platform))) throw fail.workspace("system folders cannot be browsed");
  const entries: Array<{ name: string; path: string; is_git_repo: boolean }> = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (!e.isDirectory() || e.name === ".git" || e.name.startsWith("$")) continue;
    const full = path.join(dir, e.name);
    try {
      statSync(full);
    } catch {
      continue;
    }
    if (isInside(full, policy.dataDir, policy.platform)) continue;
    if (policy.systemDirs.some((s) => isInside(full, s, policy.platform))) continue;
    entries.push({ name: e.name, path: displayPath(full), is_git_repo: isRepo(full) });
    if (entries.length >= MAX_BROWSE_ENTRIES) break;
  }
  entries.sort((a, b) => a.name.localeCompare(b.name));
  const parentDir = path.dirname(dir);
  const parentAllowed = parentDir !== dir && policy.allowedRoots.some((r) => isInside(parentDir, r, policy.platform));
  return { path: displayPath(dir), parent: parentAllowed ? displayPath(parentDir) : null, entries, roots };
}

export function buildHandlers(ctx: Ctx, control: DaemonControl = { requestShutdown: () => undefined }): Handlers {
  return {
    ping: () => ({}),
    get_state: () => getState(ctx),
    check_providers: async () => ({ providers: await ctx.providers.refresh() }),
    list_models: async (p) => ({ models: await ctx.providers.listModels(p.provider) }),
    browse_folder: (p) => browseFolder(ctx, p.path ?? null),
    create_agent: (p) => ctx.agents.create(p.spec),
    agent_trained: (p) => {
      ctx.agents.trained(p.agent_id);
      return {};
    },
    place_home: (p) => ctx.agents.placeHome(p.agent_id, p.tile),
    home_built: (p) => {
      ctx.agents.homeBuilt(p.agent_id);
      return {};
    },
    update_agent: (p) => ({ agent: ctx.agents.update(p.agent_id, p.patch, p.expected_version) }),
    retire_agent: (p) => {
      ctx.agents.retire(p.agent_id, p.when);
      return {};
    },
    attach_tool: (p) => ctx.tools.attach(p.agent_id, p.type, p.tile, p.config),
    tool_built: (p) => {
      ctx.tools.built(p.tool_id);
      return {};
    },
    detach_tool: (p) => ctx.tools.detach(p.tool_id),
    assign_task: (p) => ctx.tasks.assign(p),
    task_delivered: (p) => {
      ctx.tasks.delivered(p.task_id);
      return {};
    },
    cancel_task: (p) => {
      ctx.tasks.cancel(p.task_id);
      return {};
    },
    resume_task: (p) => {
      ctx.tasks.resume(p.task_id, p.extend_seal_mana);
      return {};
    },
    stop_and_review: (p) => {
      ctx.tasks.stopAndReview(p.task_id);
      return {};
    },
    nudge_task: (p) => {
      ctx.tasks.nudge(p.task_id, p.message);
      return {};
    },
    respond_approval: (p) => {
      ctx.approvals.respond(p);
      return {};
    },
    get_task_detail: (p) => ctx.tasks.detail(p.task_id, p.include),
    accept_result: (p) => ctx.tasks.accept(p.task_id, p.integrate),
    send_back: (p) => {
      ctx.tasks.sendBack(p.task_id, p.feedback);
      return {};
    },
    abandon_task: (p) => {
      ctx.tasks.abandon(p.task_id);
      return {};
    },
    discard_workspace: async (p) => {
      await ctx.tasks.discard(p.task_id);
      return {};
    },
    form_party: (p) => ctx.parties.form(p.lead_agent_id, p.member_ids),
    disband_party: (p) => {
      ctx.parties.disband(p.party_id);
      return {};
    },
    set_budget: (p) => ({ mana: ctx.mana.setBudget(p) }),
    spend_resources: (p) => ({ treasury: ctx.treasury.spend(p.op_id, p.reason, p.cost, p.ref) }),
    refund_resources: (p) => ({ treasury: ctx.treasury.refund(p.op_id, p.spend_op_id, p.fraction) }),
    report_gather: (p) => ({ treasury: ctx.treasury.gather(p.op_id, p.deposits, p.storehouses) }),
    trade: (p) => ctx.treasury.trade(p.op_id, p.give, p.get),
    advance_age: () => ctx.ages.advance(),
    save_town: (p) => ctx.town.save(p.base_rev, p.schema_version, p.snapshot),
    load_town: () => ctx.town.load(),
    set_setting: (p) => {
      if (p.key === "lantern_hours") return { settings: ctx.settings.set("lantern_hours", p.value) };
      return { settings: ctx.settings.set(p.key, p.value) };
    },
    get_ledger: (p) => ({ entries: ctx.treasury.entries(p.limit ?? 100), treasury: ctx.treasury.balance() }),
    get_progress: () => ctx.progress.snapshot(),
    shutdown: () => {
      control.requestShutdown();
      return {};
    },
  };
}
