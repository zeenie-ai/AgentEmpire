class_name RightClickRules
extends RefCounted
## What a right-click does, as a pure table. The input layer describes the situation as a
## context, resolve() returns the action of the first matching row, and command_for() turns it
## into a GameCommands command. No nodes involved, so the table is unit-tested headless.
##
## Context:
##   selection: "units" | "rally_building" | "building" | "none"
##   target:    "ground" | "tree" | "berry_bush" | "farm" | "site" | "dropoff" | "building" | "unit"
##   carrying:  true when a selected unit carries something the target drop-off accepts

const ACTION_NONE := "none"
const ACTION_MOVE := "move"
const ACTION_GATHER := "gather"
const ACTION_BUILD := "build"
const ACTION_DEPOSIT := "deposit"
const ACTION_RALLY := "rally"

## Checked top to bottom. "*" matches any target; "when" names a context flag that must be true.
const TABLE: Array[Dictionary] = [
	{"selection": "rally_building", "target": "*", "action": ACTION_RALLY},
	{"selection": "units", "target": "site", "action": ACTION_BUILD},
	{"selection": "units", "target": "tree", "action": ACTION_GATHER},
	{"selection": "units", "target": "berry_bush", "action": ACTION_GATHER},
	{"selection": "units", "target": "farm", "action": ACTION_GATHER},
	{"selection": "units", "target": "dropoff", "when": "carrying", "action": ACTION_DEPOSIT},
	{"selection": "units", "target": "*", "action": ACTION_MOVE},
]


static func resolve(ctx: Dictionary) -> String:
	var sel := String(ctx.get("selection", "none"))
	var target := String(ctx.get("target", "ground"))
	for row in TABLE:
		if String(row["selection"]) != sel:
			continue
		if String(row["target"]) != "*" and String(row["target"]) != target:
			continue
		if row.has("when") and not bool(ctx.get(String(row["when"]), false)):
			continue
		return String(row["action"])
	return ACTION_NONE


## Builds the context for `selection` (entity ids) and a picked `target`
## ({"kind": "ground"|"unit"|"building"|"node", "id": int, "cell": Vector2i}).
static func context_for(w: SimWorld, selection: Array, target: Dictionary) -> Dictionary:
	var tk := target_kind(w, target)
	var carrying := false
	if tk == "dropoff":
		var b: SimBuilding = w.buildings.get(int(target.get("id", 0)))
		for id: Variant in selection:
			var u: SimUnit = w.units.get(int(id))
			if u != null and u.is_carrying() and w.accepts(b, u.carry_res):
				carrying = true
				break
	return {"selection": selection_kind(w, selection), "target": tk, "carrying": carrying}


static func selection_kind(w: SimWorld, selection: Array) -> String:
	if selection.is_empty():
		return "none"
	for id: Variant in selection:
		var u: SimUnit = w.units.get(int(id))
		if u != null and u.kind == "townsfolk":
			return "units"
	var b: SimBuilding = w.buildings.get(int(selection[0]))
	if b == null:
		return "none"
	if b.complete and SimWorld.TRAINERS.has(b.type):
		return "rally_building"
	return "building"


static func target_kind(w: SimWorld, target: Dictionary) -> String:
	var id := int(target.get("id", 0))
	match String(target.get("kind", "ground")):
		"node":
			var n: SimResourceNode = w.nodes.get(id)
			return n.kind if n != null and n.is_live() else "ground"
		"building":
			var b: SimBuilding = w.buildings.get(id)
			if b == null:
				return "ground"
			if not b.complete:
				return "site"
			if w.econ.building_is_field(b.type):
				return b.type
			if not w.econ.building_dropoffs(b.type).is_empty():
				return "dropoff"
			return "building"
		"unit":
			return "unit"
	return "ground"


## The command for `action`, or {} for none.
static func command_for(w: SimWorld, selection: Array, target: Dictionary, action: String) -> Dictionary:
	var units: Array = []
	for id: Variant in selection:
		var u: SimUnit = w.units.get(int(id))
		if u != null and u.kind == "townsfolk":
			units.append(u.id)
	var cell: Vector2i = target.get("cell", Vector2i.ZERO)
	var tid := int(target.get("id", 0))
	match action:
		ACTION_MOVE:
			return GameCommands.move(units, cell)
		ACTION_GATHER:
			return GameCommands.gather(units, tid)
		ACTION_BUILD:
			return GameCommands.build(units, tid)
		ACTION_DEPOSIT:
			return GameCommands.deposit(units, tid)
		ACTION_RALLY:
			var kind := String(target.get("kind", "ground"))
			var rally_target := tid if kind == "node" or kind == "building" else 0
			return GameCommands.set_rally(int(selection[0]), cell, rally_target)
	return {}
