class_name MoveJob
extends RefCounted
## Walk to a cell. When the cell cannot be reached the unit walks as close as it can and a
## "cant_reach" notice is raised. On arrival the unit idles; `hold_after` (player move orders)
## keeps it from wandering off to gather.

const WALK := "walk"
const WALK_HOLD := "walk_hold"


static func start(w: SimWorld, u: SimUnit, cell: Vector2i, hold_after: bool) -> void:
	JobUtil.begin(w, u, SimConst.JOB_MOVE, WALK_HOLD if hold_after else WALK)
	u.target_id = 0
	w.request_path(u, SimConst.GOAL_CELL, Rect2i(cell, Vector2i.ONE), true)
	w.entity_changed.emit(u.id, SimWorld.CAT_UNIT)


static func tick(w: SimWorld, u: SimUnit) -> void:
	match u.path_state:
		SimConst.PATH_DONE, SimConst.PATH_NONE:
			JobUtil.go_idle(w, u, u.phase == WALK_HOLD)
		SimConst.PATH_FAILED:
			w.emit_notice("cant_reach", {"unit": u.id})
			JobUtil.go_idle(w, u, u.phase == WALK_HOLD)
