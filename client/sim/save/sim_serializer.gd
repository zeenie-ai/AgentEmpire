class_name SimSerializer
extends RefCounted
## JSON-safe snapshot of a SimWorld and back. This is the payload Phase 3 sends with
## save_town ({base_rev, schema_version, snapshot}). The ledger is not part of it: the Town Hall
## owns the treasury (offline saves store LocalLedger.to_dict() next to it).
##
## Save with JSON.stringify(snapshot, "", true, true) (sorted keys, full float precision) so
## positions survive the round trip exactly and the loaded world steps identically.
##
## Schema 3 adds the town walls ("walls": whether the town has them; which rings stand follows
## from the age) and the wanderer rescue ("wanderer"). Older snapshots are towns from before the
## walls: they get walls and wanderers on load. A building that stands on a wall's line leaves a
## gap there, and trees on it are cleared when its ring stands.


static func to_dict(w: SimWorld) -> Dictionary:
	var units := []
	for u: SimUnit in w.units.values():
		units.append(u.to_dict())
	var buildings := []
	for b: SimBuilding in w.buildings.values():
		buildings.append(b.to_dict())
	var kinds: Array[String] = []
	var rows := []
	for n: SimResourceNode in w.nodes.values():
		var k := kinds.find(n.kind)
		if k < 0:
			kinds.append(n.kind)
			k = kinds.size() - 1
		rows.append([n.id, k, n.cell.x, n.cell.y, n.amount_m, n.max_m, n.regrow_ticks, 1 if n.depleted else 0, n.variant])
	var rocks := []
	for c in w.rocks:
		rocks.append([c.x, c.y])
	return {
		"schema_version": SimConst.SCHEMA_VERSION,
		"town_id": w.town_id,
		"seed": w.map_seed,
		"tick": w.tick,
		"age": w.age,
		"next_id": w.next_id,
		"op_seq": w.op_seq,
		"keep_id": w.keep_id,
		"map": {"size": w.grid.size, "rocks": rocks},
		"units": units,
		"buildings": buildings,
		"nodes": {"kinds": kinds, "rows": rows},
		"regrowing": w.regrowing.duplicate(),
		"wisps": WispSystem.to_list(w),
		"walls": w.walls != null,
		"wanderer": {"enabled": w.wanderers_enabled, "wait": w.wanderer_wait, "sent": w.wanderers_sent},
		"path_queue": w.path_service.snapshot(),
		"pending_commands": w.commands.pending_snapshot(),
	}


## Rebuilds a world from to_dict() output (also after a JSON round trip, where every number is
## a float). Returns null when the snapshot is from a newer schema.
static func from_dict(d: Dictionary, econ: EconomyData, ledger: Ledger) -> SimWorld:
	var schema := int(d.get("schema_version", 0))
	if schema > SimConst.SCHEMA_VERSION:
		return null
	var legacy := schema < 3
	var w := SimWorld.new(econ, ledger)
	w.town_id = String(d.get("town_id", "town"))
	w.map_seed = int(d.get("seed", 0))
	w.tick = int(d.get("tick", 0))
	w.age = maxi(int(d.get("age", 1)), 1)
	w.next_id = int(d.get("next_id", 1))
	w.op_seq = int(d.get("op_seq", 0))
	w.ledger.set_age(w.age)

	var map: Dictionary = d.get("map", {})
	for c: Array in map.get("rocks", []):
		w.add_rock(Vector2i(int(c[0]), int(c[1])))

	var node_data: Dictionary = d.get("nodes", {})
	var kinds: Array = node_data.get("kinds", [])
	for row: Array in node_data.get("rows", []):
		var n := SimResourceNode.new()
		n.id = int(row[0])
		n.kind = String(kinds[int(row[1])])
		n.cell = Vector2i(int(row[2]), int(row[3]))
		n.amount_m = int(row[4])
		n.max_m = int(row[5])
		n.regrow_ticks = int(row[6])
		n.depleted = int(row[7]) != 0
		n.variant = int(row[8])
		w._restore_node(n)

	for bd: Dictionary in d.get("buildings", []):
		w._restore_building(SimBuilding.from_dict(bd))
	w.keep_id = int(d.get("keep_id", w.keep_id))

	for ud: Dictionary in d.get("units", []):
		var u := SimUnit.from_dict(ud)
		w.units[u.id] = u

	w.regrowing.clear()
	for v: Variant in d.get("regrowing", []):
		w.regrowing.append(int(v))
	WispSystem.from_list(w, d.get("wisps", []))
	var wanderer: Dictionary = d.get("wanderer", {})
	w.wanderers_enabled = bool(wanderer.get("enabled", legacy))
	w.wanderer_wait = int(wanderer.get("wait", -1))
	w.wanderers_sent = int(wanderer.get("sent", 0))
	w.path_service.restore(d.get("path_queue", []))
	w.commands.restore_pending(d.get("pending_commands", []))
	# Last, so a town from before the walls can make way for them (and queue the new routes).
	if bool(d.get("walls", legacy)):
		w.enable_walls()
	return w
