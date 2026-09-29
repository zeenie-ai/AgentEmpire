class_name GameCommands
extends RefCounted
## Serializable game commands: the only way game state changes.
##
## The input layer and the Town Hall bridge (TownLink) push plain JSON-safe dictionaries built
## with the constructors below. SimWorld applies them in order at the start of its next tick
## (CommandApplier) and records each one in `history` with that tick. This log is what makes
## replays and shared team towns possible later. Numbers may come back from JSON as floats; the
## applier converts them with int().
##
## Agent commands mirror what the Town Hall already decided (and charged for): an agent queued
## at the Keep, its home and add-ons placed, its state, the couriers that carry its scrolls.

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

# Agents (TownLink, after the Town Hall agreed).
## An agent starts training at the Keep.
const QUEUE_AGENT := "queue_agent"
## An agent's figure appears without training (catching up with the Town Hall).
const SPAWN_AGENT := "spawn_agent"
## An agent and everything it built leave the town (retired, or its summoning was cancelled).
const DROP_AGENT := "drop_agent"
const PLACE_HOME := "place_home"
const PLACE_TOOL := "place_tool"
const REMOVE_TOOL := "remove_tool"
## Finishes a site at once (the Town Hall already counts it as built).
const COMPLETE_BUILDING := "complete_building"
## What the agent is doing, for its figure: activity and the add-on in use.
const SET_AGENT_STATE := "set_agent_state"
## A townsperson carries a task scroll from the Keep to an agent's home.
const COURIER := "courier"
## A Font Wisp carries a task scroll (after a delay, when no townsperson could).
const WISP := "wisp"
## Stops every courier and wisp carrying the task (it was delivered or cancelled).
const CANCEL_COURIER := "cancel_courier"
## The Town Hall refused a spend the ledger mirror had accepted: undo what it paid for.
const REVOKE_SPEND := "revoke_spend"
const SET_AGE := "set_age"

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


static func queue_agent(building_id: int, agent_id: String, role: String, ticks: int) -> Dictionary:
	return {"type": QUEUE_AGENT, "building": building_id, "agent_id": agent_id, "role": role, "ticks": ticks}


static func spawn_agent(agent_id: String, role: String, cell: Vector2i) -> Dictionary:
	return {"type": SPAWN_AGENT, "agent_id": agent_id, "role": role, "x": cell.x, "y": cell.y}


static func drop_agent(agent_id: String) -> Dictionary:
	return {"type": DROP_AGENT, "agent_id": agent_id}


## `cell` is the top-left cell of the home (the plot is HomeLayout.plot_rect(cell)).
static func place_home(agent_id: String, home_type: String, cell: Vector2i, complete: bool = false) -> Dictionary:
	return {"type": PLACE_HOME, "agent_id": agent_id, "building": home_type, "x": cell.x, "y": cell.y, "complete": complete}


static func place_tool(agent_id: String, tool_id: String, tool_type: String, cell: Vector2i, complete: bool = false) -> Dictionary:
	return {"type": PLACE_TOOL, "agent_id": agent_id, "tool_id": tool_id, "building": tool_type,
		"x": cell.x, "y": cell.y, "complete": complete}


static func remove_tool(tool_id: String) -> Dictionary:
	return {"type": REMOVE_TOOL, "tool_id": tool_id}


static func complete_building(building_id: int) -> Dictionary:
	return {"type": COMPLETE_BUILDING, "building": building_id}


static func set_agent_state(agent_id: String, activity: String, tool: String) -> Dictionary:
	return {"type": SET_AGENT_STATE, "agent_id": agent_id, "activity": activity, "tool": tool}


static func courier(unit_id: int, building_id: int, task_id: String, agent_id: String) -> Dictionary:
	return {"type": COURIER, "unit": unit_id, "building": building_id, "task_id": task_id, "agent_id": agent_id}


static func wisp(building_id: int, task_id: String, agent_id: String, delay_ticks: int) -> Dictionary:
	return {"type": WISP, "building": building_id, "task_id": task_id, "agent_id": agent_id, "delay": delay_ticks}


static func cancel_courier(task_id: String) -> Dictionary:
	return {"type": CANCEL_COURIER, "task_id": task_id}


static func revoke_spend(op_id: String) -> Dictionary:
	return {"type": REVOKE_SPEND, "op": op_id}


static func set_age(age: int) -> Dictionary:
	return {"type": SET_AGE, "age": age}


static func _ids(unit_ids: Array) -> Array:
	var out := []
	for v: Variant in unit_ids:
		out.append(int(v))
	return out
