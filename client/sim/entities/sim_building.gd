class_name SimBuilding
extends RefCounted
## A building or construction site. The type keys into economy.json "buildings". Phase 3 agent
## homes and tool add-ons use the same record with owner_agent_id set.

var id: int = 0
var type: String = ""
## Top-left cell of the footprint.
var cell: Vector2i = Vector2i.ZERO
var size: Vector2i = Vector2i.ONE
var complete: bool = false
## Construction progress, 0..SimConst.WORK_SCALE.
var work: int = 0
## Ledger op that paid for it; cancel and dismantle refund against it.
var spend_op: String = ""
## Phase 3: Town Hall agent id for agent homes and tool add-ons.
var owner_agent_id: String = ""
## Fields (farms) can be walked over and are worked from inside.
var walkable: bool = false

## Training queue: [{"unit": String, "op": String, "ticks": int, "needed": int}], head first.
var queue: Array[Dictionary] = []
## True while the head of the queue waits for population room.
var training_blocked: bool = false
## Rally point: {} or {"x": int, "y": int, "target": int}. New units go there.
var rally: Dictionary = {}
## Keep only: "auto" (whichever of Food and Wood is lower) or a resource name.
var gather_focus: String = "auto"
## Farms: the unit working it (one gatherer per farm).
var farmer_id: int = 0
## Builders counted this tick (transient, always 0 between ticks).
var builders_tick: int = 0


func rect() -> Rect2i:
	return Rect2i(cell, size)


func center() -> Vector2:
	return Vector2(cell) + Vector2(size) * 0.5


func progress() -> float:
	if complete:
		return 1.0
	return clampf(float(work) / float(SimConst.WORK_SCALE), 0.0, 1.0)


func head_progress() -> float:
	if queue.is_empty():
		return 0.0
	var item: Dictionary = queue[0]
	return clampf(float(item.get("ticks", 0)) / maxf(float(item.get("needed", 1)), 1.0), 0.0, 1.0)


func to_dict() -> Dictionary:
	var q := []
	for item in queue:
		q.append({"unit": String(item.get("unit", "")), "op": String(item.get("op", "")),
			"ticks": int(item.get("ticks", 0)), "needed": int(item.get("needed", 1))})
	return {
		"id": id, "type": type, "cell": [cell.x, cell.y], "size": [size.x, size.y],
		"complete": complete, "work": work, "spend_op": spend_op,
		"owner_agent_id": owner_agent_id, "walkable": walkable, "queue": q,
		"training_blocked": training_blocked, "rally": rally.duplicate(true),
		"gather_focus": gather_focus, "farmer_id": farmer_id,
	}


static func from_dict(d: Dictionary) -> SimBuilding:
	var b := SimBuilding.new()
	b.id = int(d.get("id", 0))
	b.type = String(d.get("type", ""))
	var c: Array = d.get("cell", [0, 0])
	b.cell = Vector2i(int(c[0]), int(c[1]))
	var s: Array = d.get("size", [1, 1])
	b.size = Vector2i(int(s[0]), int(s[1]))
	b.complete = bool(d.get("complete", false))
	b.work = int(d.get("work", 0))
	b.spend_op = String(d.get("spend_op", ""))
	b.owner_agent_id = String(d.get("owner_agent_id", ""))
	b.walkable = bool(d.get("walkable", false))
	b.queue.clear()
	for item: Dictionary in d.get("queue", []):
		b.queue.append({"unit": String(item.get("unit", "")), "op": String(item.get("op", "")),
			"ticks": int(item.get("ticks", 0)), "needed": int(item.get("needed", 1))})
	b.training_blocked = bool(d.get("training_blocked", false))
	var r: Dictionary = d.get("rally", {})
	b.rally = {}
	if not r.is_empty():
		b.rally = {"x": int(r.get("x", 0)), "y": int(r.get("y", 0)), "target": int(r.get("target", 0))}
	b.gather_focus = String(d.get("gather_focus", "auto"))
	b.farmer_id = int(d.get("farmer_id", 0))
	return b
