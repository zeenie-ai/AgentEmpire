class_name SimUnit
extends RefCounted
## A walking unit: a townsperson, or an agent (kind "agent", agent_id set to the Town Hall id).

var id: int = 0
## "townsfolk" or, from Phase 3, "agent".
var kind: String = "townsfolk"
## Town Hall agent id for agent units; empty for townsfolk.
var agent_id: String = ""
## Agent units: the building id of their home once placed.
var home_id: int = 0
## Agent units: the role ("artificer", "scholar", ...), which picks the figure and the home.
var role: String = ""
## Agent units: what the Town Hall says the agent is doing ("idle", "working",
## "awaiting_approval", "blocked"), set by set_agent_state.
var activity: String = "idle"
## Agent units: the add-on type the agent is using right now ("lectern", "forge", ...) or "".
var work_tool: String = ""

## Position in tiles (x, y); tile (x, y) spans [x, x+1) x [y, y+1).
var pos: Vector2 = Vector2.ZERO
## Position at the start of the current tick, for visual interpolation.
var prev_pos: Vector2 = Vector2.ZERO
## Heading in radians (0 faces +y), for visuals.
var facing: float = 0.0

var job: String = SimConst.JOB_IDLE
var phase: String = ""
## Idle because the player said so (Stop, or a move order): no automatic gathering.
var hold: bool = false
var idle_ticks: int = 0

## Resource node or building the current job is about.
var target_id: int = 0
## Node kind being gathered ("tree", "berry_bush", "farm"), for retargeting the same kind.
var gather_kind: String = ""
## Drop-off chosen for the current trip.
var drop_id: int = 0
## Gather target to go back to after an explicit deposit order.
var resume_id: int = 0
var carry_res: String = ""
## Carried amount in thousandths of a unit.
var carry_m: int = 0

var path: Array[Vector2i] = []
var path_i: int = 0
var path_state: int = SimConst.PATH_NONE
var goal_mode: int = SimConst.GOAL_CELL
var goal_rect: Rect2i = Rect2i()
## Follow a path that only gets close (moves). Other jobs treat a partial path as unreachable.
var accept_partial: bool = false
var path_partial: bool = false
var path_retries: int = 0
var stuck_ticks: int = 0
## Targets that turned out to be unreachable during the current job.
var bad_targets: Array[int] = []
## Courier payload: {"task_id": String, "agent_id": String}.
var payload: Dictionary = {}


func cell() -> Vector2i:
	return Vector2i(floori(pos.x), floori(pos.y))


func is_idle() -> bool:
	return job == SimConst.JOB_IDLE


func is_carrying() -> bool:
	return carry_m > 0 and carry_res != ""


## Whole units carried.
func carry_amount() -> int:
	return int(carry_m / 1000.0)


func is_working() -> bool:
	return phase == "gathering" or phase == "building"


func to_dict() -> Dictionary:
	var p := []
	for c in path:
		p.append([c.x, c.y])
	return {
		"id": id, "kind": kind, "agent_id": agent_id, "home_id": home_id,
		"role": role, "activity": activity, "work_tool": work_tool,
		"pos": [pos.x, pos.y], "prev": [prev_pos.x, prev_pos.y], "facing": _f32(facing),
		"job": job, "phase": phase, "hold": hold, "idle_ticks": idle_ticks,
		"target_id": target_id, "gather_kind": gather_kind, "drop_id": drop_id,
		"resume_id": resume_id, "carry_res": carry_res, "carry_m": carry_m,
		"path": p, "path_i": path_i, "path_state": path_state, "goal_mode": goal_mode,
		"goal": [goal_rect.position.x, goal_rect.position.y, goal_rect.size.x, goal_rect.size.y],
		"accept_partial": accept_partial, "path_partial": path_partial,
		"path_retries": path_retries, "stuck_ticks": stuck_ticks,
		"bad_targets": bad_targets.duplicate(), "payload": payload.duplicate(true),
	}


## Facing (only the views read it) is saved at 32-bit precision, like positions: a 64-bit float
## does not always come back from JSON bit for bit (Godot's parser can land one bit off), and
## a 32-bit value survives that.
static func _f32(x: float) -> float:
	return PackedFloat32Array([x])[0]


static func from_dict(d: Dictionary) -> SimUnit:
	var u := SimUnit.new()
	u.id = int(d.get("id", 0))
	u.kind = String(d.get("kind", "townsfolk"))
	u.agent_id = String(d.get("agent_id", ""))
	u.home_id = int(d.get("home_id", 0))
	u.role = String(d.get("role", ""))
	u.activity = String(d.get("activity", "idle"))
	u.work_tool = String(d.get("work_tool", ""))
	var p: Array = d.get("pos", [0, 0])
	u.pos = Vector2(float(p[0]), float(p[1]))
	var pp: Array = d.get("prev", p)
	u.prev_pos = Vector2(float(pp[0]), float(pp[1]))
	u.facing = _f32(float(d.get("facing", 0.0)))
	u.job = String(d.get("job", SimConst.JOB_IDLE))
	u.phase = String(d.get("phase", ""))
	u.hold = bool(d.get("hold", false))
	u.idle_ticks = int(d.get("idle_ticks", 0))
	u.target_id = int(d.get("target_id", 0))
	u.gather_kind = String(d.get("gather_kind", ""))
	u.drop_id = int(d.get("drop_id", 0))
	u.resume_id = int(d.get("resume_id", 0))
	u.carry_res = String(d.get("carry_res", ""))
	u.carry_m = int(d.get("carry_m", 0))
	u.path.clear()
	for c: Array in d.get("path", []):
		u.path.append(Vector2i(int(c[0]), int(c[1])))
	u.path_i = int(d.get("path_i", 0))
	u.path_state = int(d.get("path_state", SimConst.PATH_NONE))
	u.goal_mode = int(d.get("goal_mode", SimConst.GOAL_CELL))
	var g: Array = d.get("goal", [0, 0, 0, 0])
	u.goal_rect = Rect2i(int(g[0]), int(g[1]), int(g[2]), int(g[3]))
	u.accept_partial = bool(d.get("accept_partial", false))
	u.path_partial = bool(d.get("path_partial", false))
	u.path_retries = int(d.get("path_retries", 0))
	u.stuck_ticks = int(d.get("stuck_ticks", 0))
	u.bad_targets.clear()
	for b: Variant in d.get("bad_targets", []):
		u.bad_targets.append(int(b))
	u.payload = (d.get("payload", {}) as Dictionary).duplicate(true)
	return u
