class_name CourierJob
extends RefCounted
## Townsfolk carry task scrolls from the Keep to an agent's home. The Town Hall keeps a task
## "in transit" until its scroll arrives: TownLink turns "courier_arrived" into task_delivered.
##
## The courier first fetches the scroll at the Keep (unless it is standing there already), then
## walks to the home, then goes back to the node or farm it was gathering from, if any.
## A courier who is given another order drops the scroll ("courier_dropped", raised by JobUtil)
## and one who cannot get there raises "courier_failed"; TownLink sends a Font Wisp instead.

const TO_KEEP := "to_keep"
const TO_HOME := "to_home"


static func start(w: SimWorld, u: SimUnit, building_id: int, payload: Dictionary) -> bool:
	var b: SimBuilding = w.buildings.get(building_id)
	if b == null or u.kind != "townsfolk":
		return false
	var resume := u.target_id if u.job == SimConst.JOB_GATHER else 0
	JobUtil.begin(w, u, SimConst.JOB_COURIER, TO_KEEP)
	u.resume_id = resume
	u.target_id = building_id
	u.payload = payload.duplicate(true)
	var k := w.keep()
	if k == null or Pathing.rect_distance(u.pos, k.rect()) <= SimConst.COURIER_PICKUP_RANGE:
		_to_home(w, u, b)
	else:
		w.request_path(u, SimConst.GOAL_ADJACENT, k.rect())
	w.entity_changed.emit(u.id, SimWorld.CAT_UNIT)
	return true


## True while the unit carries the scroll (for the views).
static func carrying_scroll(u: SimUnit) -> bool:
	return u.job == SimConst.JOB_COURIER and u.phase == TO_HOME


static func tick(w: SimWorld, u: SimUnit) -> void:
	var b: SimBuilding = w.buildings.get(u.target_id)
	if b == null:
		_fail(w, u)
		return
	if u.phase == TO_KEEP:
		var k := w.keep()
		if k == null or JobUtil.at_rect(u, k.rect(), false):
			_to_home(w, u, b)
			w.entity_changed.emit(u.id, SimWorld.CAT_UNIT)
			return
		_follow(w, u, k.rect())
		return
	if JobUtil.at_rect(u, b.rect(), false):
		w.emit_notice("courier_arrived", {"unit": u.id, "building": b.id, "payload": u.payload.duplicate(true)})
		finish(w, u)
		return
	_follow(w, u, b.rect())


## Ends the delivery without a notice and sends the unit back to its work.
static func finish(w: SimWorld, u: SimUnit) -> void:
	var resume := u.resume_id
	u.payload = {}
	if resume != 0 and GatherJob.target_kind(w, resume) != "" and GatherJob.start(w, u, resume):
		return
	JobUtil.go_idle(w, u, false)


static func _to_home(w: SimWorld, u: SimUnit, b: SimBuilding) -> void:
	u.phase = TO_HOME
	u.path_retries = 0
	w.request_path(u, SimConst.GOAL_ADJACENT, b.rect())


static func _follow(w: SimWorld, u: SimUnit, r: Rect2i) -> void:
	match u.path_state:
		SimConst.PATH_FAILED:
			_fail(w, u)
		SimConst.PATH_DONE, SimConst.PATH_NONE:
			u.path_retries += 1
			if u.path_retries > SimConst.MAX_PATH_RETRIES:
				_fail(w, u)
			else:
				w.request_path(u, SimConst.GOAL_ADJACENT, r)


static func _fail(w: SimWorld, u: SimUnit) -> void:
	w.emit_notice("courier_failed", {"unit": u.id, "payload": u.payload.duplicate(true)})
	finish(w, u)
