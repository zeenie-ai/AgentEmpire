class_name DepositJob
extends RefCounted
## Explicit "take this load to that drop-off" order (right-click a Keep or Storehouse while
## carrying). Afterwards the unit goes back to what it was gathering, if it still can.

const TO_DROP := "to_drop"


static func start(w: SimWorld, u: SimUnit, building_id: int) -> bool:
	var d: SimBuilding = w.buildings.get(building_id)
	if not u.is_carrying() or not w.accepts(d, u.carry_res):
		return false
	var resume := u.target_id if u.job == SimConst.JOB_GATHER else 0
	JobUtil.begin(w, u, SimConst.JOB_DEPOSIT, TO_DROP)
	u.resume_id = resume
	u.drop_id = building_id
	u.target_id = 0
	if JobUtil.at_rect(u, d.rect(), false):
		u.path_state = SimConst.PATH_DONE
	else:
		w.request_path(u, SimConst.GOAL_ADJACENT, d.rect())
	w.entity_changed.emit(u.id, SimWorld.CAT_UNIT)
	return true


static func tick(w: SimWorld, u: SimUnit) -> void:
	var d: SimBuilding = w.buildings.get(u.drop_id)
	if not w.accepts(d, u.carry_res):
		_finish(w, u)
		return
	if JobUtil.at_rect(u, d.rect(), false):
		w.stop_moving(u)
		w.deposit_carry(u, d)
		_finish(w, u)
		return
	match u.path_state:
		SimConst.PATH_FAILED:
			w.emit_notice("cant_reach", {"unit": u.id})
			JobUtil.go_idle(w, u, false)
		SimConst.PATH_DONE, SimConst.PATH_NONE:
			u.path_retries += 1
			if u.path_retries > SimConst.MAX_PATH_RETRIES:
				JobUtil.go_idle(w, u, false)
			else:
				w.request_path(u, SimConst.GOAL_ADJACENT, d.rect())


static func _finish(w: SimWorld, u: SimUnit) -> void:
	var resume := u.resume_id
	u.resume_id = 0
	if resume != 0 and GatherJob.start(w, u, resume):
		return
	JobUtil.go_idle(w, u, false)
