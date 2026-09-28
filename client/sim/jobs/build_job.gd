class_name BuildJob
extends RefCounted
## Walk to a construction site and help build it. With n builders the site takes
## economy.json construction.builder_time_formula seconds (build_s * 3 / (n + 2)).
## When the site completes, a farm's builder starts farming it; others look for another site
## nearby, then idle (and gather after a moment).

const TO_SITE := "to_site"
const BUILDING := "building"


static func start(w: SimWorld, u: SimUnit, site_id: int) -> bool:
	var b: SimBuilding = w.buildings.get(site_id)
	if b == null or b.complete:
		return false
	JobUtil.begin(w, u, SimConst.JOB_BUILD, TO_SITE)
	u.target_id = site_id
	_go(w, u, b)
	w.entity_changed.emit(u.id, SimWorld.CAT_UNIT)
	return true


static func _go(w: SimWorld, u: SimUnit, b: SimBuilding) -> void:
	if JobUtil.at_rect(u, b.rect(), false):
		w.stop_moving(u)
		u.path_state = SimConst.PATH_DONE
		return
	w.request_path(u, SimConst.GOAL_INSIDE if b.walkable else SimConst.GOAL_ADJACENT, b.rect())


static func tick(w: SimWorld, u: SimUnit) -> void:
	var b: SimBuilding = w.buildings.get(u.target_id)
	if b == null:
		JobUtil.go_idle(w, u, false)
		return
	if b.complete:
		_after(w, u, b)
		return
	if JobUtil.at_rect(u, b.rect(), false):
		if u.phase != BUILDING:
			w.stop_moving(u)
			u.phase = BUILDING
			u.path_retries = 0
			w.entity_changed.emit(u.id, SimWorld.CAT_UNIT)
		b.builders_tick += 1
		JobUtil.face(u, b.center())
		return
	if u.phase == BUILDING:
		u.phase = TO_SITE
		_go(w, u, b)
		return
	match u.path_state:
		SimConst.PATH_FAILED:
			w.emit_notice("cant_reach", {"unit": u.id})
			JobUtil.go_idle(w, u, false)
		SimConst.PATH_DONE, SimConst.PATH_NONE:
			u.path_retries += 1
			if u.path_retries > SimConst.MAX_PATH_RETRIES:
				w.emit_notice("cant_reach", {"unit": u.id})
				JobUtil.go_idle(w, u, false)
			else:
				_go(w, u, b)


static func _after(w: SimWorld, u: SimUnit, b: SimBuilding) -> void:
	if b.walkable and w.econ.building_is_field(b.type) and w.farm_is_free(b, u.id):
		if GatherJob.start(w, u, b.id):
			return
	var next := w.find_site_near(b.center(), w.econ.retry_radius())
	if next != null and start(w, u, next.id):
		return
	JobUtil.go_idle(w, u, false)
