class_name JobUtil
extends RefCounted
## Shared helpers for unit jobs. Jobs are stateless behaviours: all job state lives on the
## SimUnit (job, phase, target_id, ...) so it serializes with the unit.


## Switches a unit to a new job, releasing claims (farms) and any path of the old one.
static func begin(w: SimWorld, u: SimUnit, job: String, phase: String) -> void:
	drop_scroll(w, u)
	release_claims(w, u)
	w.stop_moving(u)
	u.job = job
	u.phase = phase
	u.hold = false
	u.idle_ticks = 0
	u.path_retries = 0
	u.drop_id = 0
	u.resume_id = 0
	u.payload = {}


static func release_claims(w: SimWorld, u: SimUnit) -> void:
	if u.target_id == 0:
		return
	var b: SimBuilding = w.buildings.get(u.target_id)
	if b != null and b.farmer_id == u.id:
		b.farmer_id = 0


## A courier leaving its job with the scroll still in hand drops it; TownLink sends a wisp.
static func drop_scroll(w: SimWorld, u: SimUnit) -> void:
	if u.job != SimConst.JOB_COURIER or u.payload.is_empty():
		return
	w.emit_notice("courier_dropped", {"unit": u.id, "payload": u.payload.duplicate(true)})
	u.payload = {}


static func go_idle(w: SimWorld, u: SimUnit, hold: bool) -> void:
	drop_scroll(w, u)
	release_claims(w, u)
	w.stop_moving(u)
	u.job = SimConst.JOB_IDLE
	u.phase = ""
	u.hold = hold
	u.idle_ticks = 0
	u.target_id = 0
	u.drop_id = 0
	u.resume_id = 0
	u.gather_kind = ""
	u.path_retries = 0
	w.entity_changed.emit(u.id, SimWorld.CAT_UNIT)


## Clears what a unit learned during its last job (unreachable targets). Called when the
## player gives a new order.
static func forget(u: SimUnit) -> void:
	u.bad_targets.clear()


static func mark_bad(u: SimUnit, id: int) -> void:
	if id == 0 or id in u.bad_targets:
		return
	u.bad_targets.append(id)
	while u.bad_targets.size() > SimConst.MAX_BAD_TARGETS:
		u.bad_targets.pop_front()


static func at_rect(u: SimUnit, r: Rect2i, inside: bool) -> bool:
	return Pathing.rect_distance(u.pos, r) <= (SimConst.INSIDE_EPS if inside else SimConst.REACH)


static func face(u: SimUnit, p: Vector2) -> void:
	var d := p - u.pos
	if d.length_squared() > 0.0001:
		u.facing = atan2(d.x, d.y)
