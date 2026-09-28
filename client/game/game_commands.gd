class_name GameCommands
extends RefCounted
## Serializable game commands: the only way game state changes.
##
## The input layer (and, from Phase 3, the Town Hall bridge) pushes plain JSON-safe
## dictionaries built with the constructors below. SimWorld applies them in order at the start
## of its next tick (CommandApplier) and records each one in `history` with that tick. This log
## is what makes replays and shared team towns possible later. Numbers may come back from JSON
## as floats; the applier converts them with int().
##
## Reserved for Phase 3 (agents): "spawn_agent" (agent trained at the Keep), "place_home",
## "place_tool", "courier" (walk a scroll to a home) and "set_agent_state".

## Emitted when a command is queued (before it is applied).
signal pushed(cmd: Dictionary)

const MOVE := "move"
const GATHER := "gather"
const BUILD := "build"
const DEPOSIT := "deposit"
const STOP := "stop"
## Idle-style work picking: whichever of Food and Wood is lower (or the Keep's focus).
const AUTO_GATHER := "auto_gather"
const PLACE_BUILDING := "place_building"
const CANCEL_SITE := "cancel_site"
const DISMANTLE := "dismantle"
const TRAIN := "train"
const CANCEL_TRAIN := "cancel_train"
const SET_RALLY := "set_rally"
const SET_GATHER_FOCUS := "set_gather_focus"
## Tools only (perf stress, screenshots); ignored unless SimWorld.allow_debug_commands.
const DEBUG_SPAWN := "debug_spawn"

const HISTORY_LIMIT := 4096

## Applied commands, oldest first: {"tick": int, "cmd": Dictionary}.
var history: Array[Dictionary] = []

var _pending: Array[Dictionary] = []


func push(cmd: Dictionary) -> void:
	if not cmd.has("type"):
		return
	var c := cmd.duplicate(true)
	_pending.append(c)
	pushed.emit(c)


func pending_count() -> int:
	return _pending.size()


func take_pending() -> Array[Dictionary]:
	var out := _pending
	_pending = []
	return out


func record(tick: int, cmd: Dictionary) -> void:
	history.append({"tick": tick, "cmd": cmd})
	if history.size() > HISTORY_LIMIT + 256:
		var recent := history.slice(history.size() - HISTORY_LIMIT)
		history.clear()
		history.append_array(recent)


func pending_snapshot() -> Array:
	return _pending.duplicate(true)


func restore_pending(cmds: Array) -> void:
	_pending.clear()
	for c: Variant in cmds:
		if typeof(c) == TYPE_DICTIONARY:
			_pending.append((c as Dictionary).duplicate(true))


# --- constructors ---------------------------------------------------------------------------

static func move(unit_ids: Array, cell: Vector2i) -> Dictionary:
	return {"type": MOVE, "units": _ids(unit_ids), "x": cell.x, "y": cell.y}


static func gather(unit_ids: Array, target_id: int) -> Dictionary:
	return {"type": GATHER, "units": _ids(unit_ids), "target": target_id}


static func build(unit_ids: Array, site_id: int) -> Dictionary:
	return {"type": BUILD, "units": _ids(unit_ids), "building": site_id}


static func deposit(unit_ids: Array, building_id: int) -> Dictionary:
	return {"type": DEPOSIT, "units": _ids(unit_ids), "building": building_id}


static func stop(unit_ids: Array) -> Dictionary:
	return {"type": STOP, "units": _ids(unit_ids)}


static func auto_gather(unit_ids: Array) -> Dictionary:
	return {"type": AUTO_GATHER, "units": _ids(unit_ids)}


## `cell` is the top-left cell of the footprint.
static func place_building(unit_ids: Array, building_type: String, cell: Vector2i) -> Dictionary:
	return {"type": PLACE_BUILDING, "units": _ids(unit_ids), "building": building_type, "x": cell.x, "y": cell.y}


static func cancel_site(building_id: int) -> Dictionary:
	return {"type": CANCEL_SITE, "building": building_id}


static func dismantle(building_id: int) -> Dictionary:
	return {"type": DISMANTLE, "building": building_id}


static func train(building_id: int, unit_type: String) -> Dictionary:
	return {"type": TRAIN, "building": building_id, "unit": unit_type}


## index -1 cancels the last queued item.
static func cancel_train(building_id: int, index: int) -> Dictionary:
	return {"type": CANCEL_TRAIN, "building": building_id, "index": index}


## `target_id` is a resource, farm or site at the rally point (0 for plain ground).
static func set_rally(building_id: int, cell: Vector2i, target_id: int = 0) -> Dictionary:
	return {"type": SET_RALLY, "building": building_id, "x": cell.x, "y": cell.y, "target": target_id}


static func clear_rally(building_id: int) -> Dictionary:
	return {"type": SET_RALLY, "building": building_id, "clear": true}


static func set_gather_focus(building_id: int, focus: String) -> Dictionary:
	return {"type": SET_GATHER_FOCUS, "building": building_id, "focus": focus}


static func debug_spawn(count: int, cell: Vector2i, hold: bool = false) -> Dictionary:
	return {"type": DEBUG_SPAWN, "count": count, "x": cell.x, "y": cell.y, "kind": "townsfolk", "hold": hold}


static func _ids(unit_ids: Array) -> Array:
	var out := []
	for v: Variant in unit_ids:
		out.append(int(v))
	return out
