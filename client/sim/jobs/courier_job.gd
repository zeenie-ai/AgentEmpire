class_name CourierJob
extends RefCounted
## Phase 3 stub: townsfolk carry task scrolls, approval requests and results between the Keep
## and agent homes. The Town Hall decides what is carried (assign_task with courier
## {mode:"human", human_id}); the simulation only walks the courier to the building and raises
## a "courier_arrived" notice, which the Town Hall bridge turns into task_delivered.
## Townsfolk who are building are never pulled away (the bridge checks job before assigning).

const TO_TARGET := "to_target"


static func start(w: SimWorld, u: SimUnit, building_id: int, payload: Dictionary) -> bool:
	var b: SimBuilding = w.buildings.get(building_id)
	if b == null:
		return false
	JobUtil.begin(w, u, SimConst.JOB_COURIER, TO_TARGET)
	u.target_id = building_id
	u.payload = payload.duplicate(true)
	w.request_path(u, SimConst.GOAL_ADJACENT, b.rect())
	w.entity_changed.emit(u.id, SimWorld.CAT_UNIT)
	return true


static func tick(w: SimWorld, u: SimUnit) -> void:
	var b: SimBuilding = w.buildings.get(u.target_id)
	if b == null:
		JobUtil.go_idle(w, u, false)
		return
	if JobUtil.at_rect(u, b.rect(), false):
		w.emit_notice("courier_arrived", {"unit": u.id, "building": b.id, "payload": u.payload.duplicate(true)})
		JobUtil.go_idle(w, u, false)
		return
	if u.path_state == SimConst.PATH_FAILED:
		w.emit_notice("cant_reach", {"unit": u.id})
		JobUtil.go_idle(w, u, false)
	elif u.path_state == SimConst.PATH_DONE or u.path_state == SimConst.PATH_NONE:
		w.request_path(u, SimConst.GOAL_ADJACENT, b.rect())
