import { fromJson, toJson } from "../db/db.js";
import { fail } from "../protocol/errors.js";
import type { WaygateConfig } from "../protocol/commands.js";
import type { Role, Tile, ToolAddon, ToolStatus, ToolType } from "../protocol/objects.js";
import type { Ctx } from "./context.js";
import { scaleCost, toResources, zeroResources, type Resources } from "./economy.js";
import type { DirtySet } from "./events.js";

interface ToolRow {
  id: string;
  agent_id: string;
  type: ToolType;
  status: ToolStatus;
  tile_json: string;
  config_json: string | null;
  config_summary_json: string | null;
  health_json: string | null;
  cost_json: string;
  free: number;
  created_at: string;
  built_at: string | null;
  removed_at: string | null;
}

export class ToolService {
  private readonly dirty: DirtySet;

  constructor(private readonly ctx: Ctx) {
    this.dirty = ctx.bus.newDirtySet();
    ctx.bus.addFlusher(() => {
      const ids = this.dirty.take();
      for (const id of ids) {
        const row = this.ctx.db.get<ToolRow>("SELECT * FROM tool_addons WHERE id = ?", [id]);
        if (row) this.ctx.bus.emit("tool_updated", { tool: this.toProtocol(row) }, `tool/${id}`);
      }
      return ids.length > 0;
    });
  }

  private markDirty(toolId: string, agentId: string): void {
    this.dirty.add(toolId);
    this.ctx.agents.markDirty(agentId);
  }

  private row(toolId: string): ToolRow {
    const r = this.ctx.db.get<ToolRow>("SELECT * FROM tool_addons WHERE id = ?", [toolId]);
    if (!r) throw fail.notFound("tool", toolId);
    return r;
  }

  toProtocol(r: ToolRow): ToolAddon {
    return {
      id: r.id,
      agent_id: r.agent_id,
      type: r.type,
      status: r.status,
      tile: fromJson<Tile>(r.tile_json, { x: 0, y: 0 }),
      config_summary: fromJson(r.config_summary_json, null),
      health: fromJson(r.health_json, null),
    };
  }

  list(): ToolAddon[] {
    return this.ctx.db
      .all<ToolRow>("SELECT * FROM tool_addons WHERE status != 'removed' ORDER BY created_at ASC")
      .map((r) => this.toProtocol(r));
  }

  idsForAgent(agentId: string): string[] {
    return this.ctx.db
      .all<{ id: string }>("SELECT id FROM tool_addons WHERE agent_id = ? AND status != 'removed' ORDER BY created_at ASC", [
        agentId,
      ])
      .map((r) => r.id);
  }

  activeTypes(agentId: string): Set<ToolType> {
    return new Set(
      this.ctx.db
        .all<{ type: ToolType }>("SELECT type FROM tool_addons WHERE agent_id = ? AND status = 'active'", [agentId])
        .map((r) => r.type),
    );
  }

  requiredToolsActive(agentId: string, role: Role): boolean {
    const required = this.ctx.econ.data.roles[role]?.required_tools ?? [];
    const active = this.activeTypes(agentId);
    return required.every((t) => active.has(t as ToolType));
  }

  hasRecommendedTools(agentId: string, role: Role): boolean {
    const recommended = this.ctx.econ.data.roles[role]?.recommended_tools ?? [];
    const active = this.activeTypes(agentId);
    return recommended.every((t) => active.has(t as ToolType));
  }

  /** Tools that are built and not dismantled, town-wide (the "add-ons built" milestone). */
  builtCount(): number {
    return this.ctx.db.get<{ n: number }>("SELECT COUNT(*) AS n FROM tool_addons WHERE status = 'active'")?.n ?? 0;
  }

  private validateWaygate(config: WaygateConfig | undefined): WaygateConfig {
    if (!config) throw fail.badRequest("a Waygate needs a config");
    if (config.transport === "stdio" && !config.command) throw fail.badRequest("a stdio Waygate needs a command");
    if (config.transport === "http" && !config.url) throw fail.badRequest("an http Waygate needs a url");
    // Secrets belong in environment variables named by env_refs / header_refs, never in the config.
    const literal = [config.command ?? "", config.url ?? "", ...(config.args ?? [])];
    for (const value of literal) {
      if (this.ctx.redactor.redact(value) !== value) {
        throw fail.badRequest("the Waygate config looks like it contains a secret; name an environment variable instead");
      }
    }
    return config;
  }

  attach(agentId: string, type: ToolType, tile: Tile, config?: WaygateConfig): { tool_id: string; cost: Resources } {
    const econ = this.ctx.econ;
    return this.ctx.db.tx(() => {
      const agent = this.ctx.agents.row(agentId);
      if (agent.retired_at) throw fail.invalidState("the agent is retired");
      if (!agent.home_tile_json) throw fail.invalidState("the agent has no home yet");
      const def = econ.data.tools[type];
      if (!def) throw fail.badRequest(`unknown tool ${type}`);
      const age = this.ctx.ages.current();
      if (def.age > age) throw fail.age(`${def.name} needs Age ${def.age}`);
      const existing = this.ctx.db.all<ToolRow>("SELECT * FROM tool_addons WHERE agent_id = ? AND status != 'removed'", [
        agentId,
      ]);
      if (existing.length >= econ.toolSlots(age)) throw fail.limit(`Age ${age} allows ${econ.toolSlots(age)} add-ons per home`);
      if (type !== "waygate" && existing.some((t) => t.type === type)) throw fail.conflict(`the agent already has a ${def.name}`);
      for (const req of def.requires) {
        if (!existing.some((t) => t.type === req)) {
          throw fail.invalidState(`${def.name} needs a ${econ.data.tools[req]?.name ?? req} first`);
        }
      }
      const waygate = type === "waygate" ? this.validateWaygate(config) : null;
      const role = econ.data.roles[agent.role]!;
      const alreadyFree = !!this.ctx.db.get("SELECT id FROM tool_addons WHERE agent_id = ? AND type = ? AND free = 1", [
        agentId,
        type,
      ]);
      const free = this.ctx.agents.graceFrees(agent, "required_tools") && role.required_tools.includes(type) && !alreadyFree;
      const cost = free ? zeroResources() : toResources(def.cost);
      const id = this.ctx.ids.next("tl");
      this.ctx.treasury.charge(cost, `tool:${type}`, id, `tool:${id}`);
      this.ctx.db.run(
        `INSERT INTO tool_addons (id, agent_id, type, status, tile_json, config_json, config_summary_json, cost_json, free, created_at)
         VALUES (?, ?, ?, 'building', ?, ?, ?, ?, ?, ?)`,
        [
          id,
          agentId,
          type,
          toJson(tile),
          waygate ? toJson(waygate) : null,
          waygate
            ? toJson({ server_name: waygate.server_name, transport: waygate.transport, allowed_tools: waygate.allowed_tools ?? [] })
            : null,
          toJson(cost),
          free ? 1 : 0,
          this.ctx.clock.iso(),
        ],
      );
      this.markDirty(id, agentId);
      return { tool_id: id, cost };
    });
  }

  built(toolId: string): void {
    this.ctx.db.tx(() => {
      const r = this.row(toolId);
      if (r.status === "removed") throw fail.invalidState("the add-on was dismantled");
      if (r.status === "active") return;
      this.ctx.db.run("UPDATE tool_addons SET status = 'active', built_at = ? WHERE id = ?", [this.ctx.clock.iso(), toolId]);
      this.markDirty(toolId, r.agent_id);
    });
    this.ctx.scheduler.kick();
  }

  detach(toolId: string): { refund: Resources } {
    return this.ctx.db.tx(() => {
      const r = this.row(toolId);
      if (r.status === "removed") throw fail.invalidState("the add-on was already dismantled");
      const others = this.ctx.db.all<ToolRow>(
        "SELECT * FROM tool_addons WHERE agent_id = ? AND status != 'removed' AND id != ?",
        [r.agent_id, toolId],
      );
      const stillProvided = others.some((t) => t.type === r.type);
      if (!stillProvided) {
        const dependant = others.find((t) => this.ctx.econ.data.tools[t.type]?.requires.includes(r.type));
        if (dependant) {
          throw fail.invalidState(`dismantle the ${this.ctx.econ.data.tools[dependant.type]?.name} first; it needs this add-on`);
        }
      }
      const paid = toResources(fromJson(r.cost_json, {}));
      const refund = scaleCost(paid, this.ctx.econ.data.refunds.dismantle, Math.floor);
      this.ctx.db.run("UPDATE tool_addons SET status = 'removed', removed_at = ? WHERE id = ?", [this.ctx.clock.iso(), toolId]);
      this.ctx.treasury.credit(refund, "dismantle", `dismantle:${r.type}`, toolId, `dismantle:${toolId}`);
      this.markDirty(toolId, r.agent_id);
      return { refund };
    });
  }

  removeAllForAgent(agentId: string): void {
    const rows = this.ctx.db.all<ToolRow>("SELECT * FROM tool_addons WHERE agent_id = ? AND status != 'removed'", [agentId]);
    for (const r of rows) {
      this.ctx.db.run("UPDATE tool_addons SET status = 'removed', removed_at = ? WHERE id = ?", [this.ctx.clock.iso(), r.id]);
      this.markDirty(r.id, agentId);
    }
  }

  waygateConfigs(agentId: string): WaygateConfig[] {
    return this.ctx.db
      .all<ToolRow>("SELECT * FROM tool_addons WHERE agent_id = ? AND type = 'waygate' AND status = 'active'", [agentId])
      .map((r) => fromJson<WaygateConfig | null>(r.config_json, null))
      .filter((c): c is WaygateConfig => c !== null);
  }
}
