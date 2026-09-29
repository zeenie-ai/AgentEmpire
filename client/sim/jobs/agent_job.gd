class_name AgentJob
extends RefCounted
## What an agent's figure does on its own. The Town Hall decides the real work; this shows it:
## - with an unfinished home or add-on it builds that (BuildJob), the home first;
## - without a home it waits by the Keep until the player chooses a plot;
## - at home it goes to the add-on it is using (u.work_tool) and works there, waits at the door
##   while one of its approvals is pending, and otherwise potters about its plot now and then.
## u.activity and u.work_tool come from the set_agent_state command (TownLink mirrors the Town
## Hall there), so the figure follows the command log like everything else.

const TO_SPOT := "to_spot"
const AT_SPOT := "at_spot"

const BUSY := ["working", "awaiting_approval"]


## Called while an agent idles (IdleJob): starts whatever it should be doing, if anything.
static func decide(w: SimWorld, u: SimUnit) -> void:
	var site := w.agent_next_site(u.agent_id)
	if site != null and BuildJob.start(w, u, site.id):
		return
	var home := w.agent_home(u.agent_id)
	if home != null and home.complete:
		start(w, u)


## Home life: walk to the spot that fits the agent's state.
static func start(w: SimWorld, u: SimUnit) -> void:
	var home := w.agent_home(u.agent_id)
	if home == null or not home.complete:
		return
	JobUtil.begin(w, u, SimConst.JOB_AGENT, TO_SPOT)
	u.home_id = home.id
	var spot := spot_for(w, u, home)
	u.target_id = int(spot["target"])
	var cell: Vector2i = spot["cell"]
	if u.cell() == cell:
		w.stop_moving(u)
		u.path_state = SimConst.PATH_DONE
	else:
		w.request_path(u, SimConst.GOAL_CELL, Rect2i(cell, Vector2i.ONE), true)
	w.entity_changed.emit(u.id, SimWorld.CAT_UNIT)


static func tick(w: SimWorld, u: SimUnit) -> void:
	var home := w.agent_home(u.agent_id)
	if home == null or not home.complete or w.agent_next_site(u.agent_id) != null:
		JobUtil.go_idle(w, u, false)
		return
	match u.phase:
		TO_SPOT:
			match u.path_state:
				SimConst.PATH_DONE, SimConst.PATH_NONE, SimConst.PATH_FAILED:
					u.phase = AT_SPOT
					u.idle_ticks = 0
					_face(w, u)
					w.entity_changed.emit(u.id, SimWorld.CAT_UNIT)
		AT_SPOT:
			u.idle_ticks += 1
			_face(w, u)
			if not u.activity in BUSY and u.idle_ticks >= SimConst.AGENT_WANDER_TICKS:
				start(w, u)


## True when the agent stands where its state wants it (for the views: work animations).
static func at_spot(u: SimUnit) -> bool:
	return u.job == SimConst.JOB_AGENT and u.phase == AT_SPOT


## {"cell": Vector2i, "target": int}: where the agent goes for its current state, and the
## building it faces there (0 for none).
static func spot_for(w: SimWorld, u: SimUnit, home: SimBuilding) -> Dictionary:
	var door := HomeLayout.door_cell(home.rect())
	match u.activity:
		"working":
			var t := tool_of_type(w, u.agent_id, u.work_tool)
			if t != null:
				var best := Pathing.NO_CELL
				var best_d := INF
				for c in Pathing.free_edge_cells(w.grid, t.rect()):
					var d := Vector2(c).distance_squared_to(Vector2(door))
					if d < best_d:
						best_d = d
						best = c
				if best != Pathing.NO_CELL:
					return {"cell": best, "target": t.id}
			return {"cell": door, "target": home.id}
		"awaiting_approval":
			return {"cell": door, "target": 0}
	var ring := ring_cells(w, home.plot)
	if ring.is_empty():
		return {"cell": door, "target": 0}
	var k := posmod(u.id * 7919 + int(w.tick / SimConst.AGENT_WANDER_TICKS) * 104729, ring.size())
	return {"cell": ring[k], "target": 0}


## The agent's finished add-on of `type`, or null.
static func tool_of_type(w: SimWorld, agent_id: String, type: String) -> SimBuilding:
	if type == "":
		return null
	for t in w.agent_tools(agent_id):
		if t.type == type and t.complete:
			return t
	return null


## Walkable cells of a plot's ring (not the home, not the entrance), row by row.
static func ring_cells(w: SimWorld, plot: Rect2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(plot.position.y, plot.end.y):
		for x in range(plot.position.x, plot.end.x):
			var c := Vector2i(x, y)
			if HomeLayout.in_ring(plot, Rect2i(c, Vector2i.ONE)) and w.grid.is_walkable(c):
				out.append(c)
	return out


static func _face(w: SimWorld, u: SimUnit) -> void:
	var b: SimBuilding = w.buildings.get(u.target_id) if u.target_id != 0 else null
	if b != null:
		JobUtil.face(u, b.center())
	elif u.activity == "awaiting_approval":
		u.facing = 0.0
