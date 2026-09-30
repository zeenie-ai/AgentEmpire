class_name GatherJob
extends RefCounted
## The gather loop: walk to the node, gather at its rate until carrying a full load, take it to
## the nearest drop-off (Keep or Storehouse), deposit, repeat. When the node runs out, try
## another node of the same kind within gather.same_kind_retry_radius_tiles, otherwise go idle.
## Farms are fields: endless, one gatherer each, worked from inside.

const TO_NODE := "to_node"
const GATHERING := "gathering"
const TO_DROP := "to_drop"


## Gather kind of target `id` ("tree", "berry_bush", "farm", ...), or "" if it is not one.
static func target_kind(w: SimWorld, id: int) -> String:
	var n: SimResourceNode = w.nodes.get(id)
	if n != null:
		return n.kind
	var b: SimBuilding = w.buildings.get(id)
	if b != null and b.walkable and w.econ.building_is_field(b.type):
		return b.type
	return ""


static func capacity_m(w: SimWorld) -> int:
	return w.econ.carry_capacity(w.age) * 1000


static func start(w: SimWorld, u: SimUnit, target_id: int) -> bool:
	var kind := target_kind(w, target_id)
	if kind == "":
		return false
	var n: SimResourceNode = w.nodes.get(target_id)
	if n != null and n.depleted:
		return false
	var b: SimBuilding = w.buildings.get(target_id)
	if b != null:
		if not b.complete:
			return BuildJob.start(w, u, target_id)
		if not w.farm_is_free(b, u.id):
			var alt := w.find_free_farm(b.center(), w.econ.retry_radius(), u.id)
			if alt == null:
				w.emit_notice("farm_busy", {"unit": u.id, "building": b.id})
				return false
			b = alt
			target_id = alt.id
	var res := w.econ.node_resource(kind)
	JobUtil.begin(w, u, SimConst.JOB_GATHER, TO_NODE)
	if u.carry_res != res:
		u.carry_m = 0
		u.carry_res = ""
	u.target_id = target_id
	u.gather_kind = kind
	if b != null:
		b.farmer_id = u.id
	if u.carry_m >= capacity_m(w):
		u.phase = TO_DROP
		_go_drop(w, u)
	else:
		_go_node(w, u)
	w.entity_changed.emit(u.id, SimWorld.CAT_UNIT)
	return true


## Picks work for an idle townsperson. Returns true when a gather job started.
static func auto_assign(w: SimWorld, u: SimUnit) -> bool:
	for res in preferred_resources(w):
		var id := nearest_source(w, u, res, w.econ.search_radius())
		if id != 0 and start(w, u, id):
			return true
	return false


## Gatherable resources in the order idle townsfolk should consider them: the Keep's focus
## first, otherwise the lowest balance first. Full stores go last.
static func preferred_resources(w: SimWorld) -> Array[String]:
	var all := w.econ.gatherable_resources()
	var out: Array[String] = []
	var focus := w.gather_focus()
	if focus in all:
		out.append(focus)
		for r in all:
			if r != focus:
				out.append(r)
		return out
	var t := w.ledger.treasury()
	var storehouses := w.storehouse_count()
	out.assign(all)
	out.sort_custom(func(a: String, b: String) -> bool:
		var fa := _is_full(w, a, t, storehouses)
		var fb := _is_full(w, b, t, storehouses)
		if fa != fb:
			return not fa
		var aa := int(t.get(a, 0))
		var bb := int(t.get(b, 0))
		if aa != bb:
			return aa < bb
		return all.find(a) < all.find(b))
	return out


static func _is_full(w: SimWorld, res: String, t: Dictionary, storehouses: int) -> bool:
	var cap := w.ledger.storage_cap(res, storehouses)
	return cap >= 0 and int(t.get(res, 0)) >= cap


## Nearest node or free field producing `res` within `radius` of the unit; 0 if none.
static func nearest_source(w: SimWorld, u: SimUnit, res: String, radius: float) -> int:
	var node_kinds: Array[String] = []
	var field_kinds: Array[String] = []
	for k in w.econ.node_kinds():
		if w.econ.node_resource(k) != res:
			continue
		if w.econ.building_is_field(k) and w.econ.has_building(k):
			field_kinds.append(k)
		else:
			node_kinds.append(k)
	var best_id := 0
	var best_d := INF
	if not node_kinds.is_empty():
		var n := w.find_nearest_node(u.pos, node_kinds, radius, u.bad_targets)
		if n != null:
			best_id = n.id
			best_d = n.center().distance_to(u.pos)
	if not field_kinds.is_empty():
		var f := w.find_free_farm(u.pos, radius, u.id, u.bad_targets)
		if f != null and f.type in field_kinds and Pathing.rect_distance(u.pos, f.rect()) < best_d:
			best_id = f.id
	return best_id


static func tick(w: SimWorld, u: SimUnit) -> void:
	match u.phase:
		TO_NODE:
			_tick_to_node(w, u)
		GATHERING:
			_tick_gathering(w, u)
		TO_DROP:
			_tick_to_drop(w, u)
		_:
			u.phase = TO_NODE
			_go_node(w, u)


static func _is_field(w: SimWorld, u: SimUnit) -> bool:
	return w.buildings.has(u.target_id)


static func _valid(w: SimWorld, u: SimUnit) -> bool:
	var n: SimResourceNode = w.nodes.get(u.target_id)
	if n != null:
		return not n.depleted
	var b: SimBuilding = w.buildings.get(u.target_id)
	return b != null and b.complete and b.walkable and w.farm_is_free(b, u.id)


static func _rect(w: SimWorld, u: SimUnit) -> Rect2i:
	var n: SimResourceNode = w.nodes.get(u.target_id)
	if n != null:
		return n.rect()
	var b: SimBuilding = w.buildings.get(u.target_id)
	return b.rect() if b != null else Rect2i()


static func _at_target(w: SimWorld, u: SimUnit) -> bool:
	return JobUtil.at_rect(u, _rect(w, u), _is_field(w, u))


static func _go_node(w: SimWorld, u: SimUnit) -> void:
	if _at_target(w, u):
		w.stop_moving(u)
		u.path_state = SimConst.PATH_DONE
		return
	if _is_field(w, u):
		w.request_path(u, SimConst.GOAL_INSIDE, _rect(w, u))
	else:
		w.request_path(u, SimConst.GOAL_ADJACENT, _rect(w, u))


static func _go_drop(w: SimWorld, u: SimUnit) -> void:
	var d := w.nearest_dropoff(u.pos, u.carry_res)
	if d == null:
		w.emit_notice("no_dropoff", {"unit": u.id, "res": u.carry_res})
		JobUtil.go_idle(w, u, false)
		return
	u.drop_id = d.id
	if JobUtil.at_rect(u, d.rect(), false):
		w.stop_moving(u)
		u.path_state = SimConst.PATH_DONE
		return
	w.request_path(u, SimConst.GOAL_ADJACENT, d.rect())


static func _tick_to_node(w: SimWorld, u: SimUnit) -> void:
	if not _valid(w, u):
		_retarget(w, u)
		return
	if _at_target(w, u):
		w.stop_moving(u)
		u.phase = GATHERING
		u.path_retries = 0
		w.entity_changed.emit(u.id, SimWorld.CAT_UNIT)
		return
	match u.path_state:
		SimConst.PATH_FAILED:
			JobUtil.mark_bad(u, u.target_id)
			_retarget(w, u)
		SimConst.PATH_DONE, SimConst.PATH_NONE:
			u.path_retries += 1
			if u.path_retries > SimConst.MAX_PATH_RETRIES:
				JobUtil.mark_bad(u, u.target_id)
				_retarget(w, u)
			else:
				_go_node(w, u)


static func _tick_gathering(w: SimWorld, u: SimUnit) -> void:
	if not _valid(w, u):
		if u.carry_m > 0:
			u.phase = TO_DROP
			_go_drop(w, u)
		else:
			_retarget(w, u)
		return
	var r := _rect(w, u)
	if not JobUtil.at_rect(u, r, _is_field(w, u)):
		u.phase = TO_NODE
		_go_node(w, u)
		return
	var cap := capacity_m(w)
	var take := mini(w.gather_rate_m(u.gather_kind), cap - u.carry_m)
	var n: SimResourceNode = w.nodes.get(u.target_id)
	if n != null:
		take = mini(take, n.amount_m)
	if take > 0:
		u.carry_m += take
		u.carry_res = w.econ.node_resource(u.gather_kind)
		if n != null:
			n.amount_m -= take
			if n.amount_m <= 0:
				w.deplete_node(n)
	if n != null:
		JobUtil.face(u, n.center())
	if u.carry_m >= cap:
		u.phase = TO_DROP
		_go_drop(w, u)
		w.entity_changed.emit(u.id, SimWorld.CAT_UNIT)


static func _tick_to_drop(w: SimWorld, u: SimUnit) -> void:
	if not u.is_carrying():
		_after_drop(w, u)
		return
	var d: SimBuilding = w.buildings.get(u.drop_id)
	if not w.accepts(d, u.carry_res):
		_go_drop(w, u)
		return
	if JobUtil.at_rect(u, d.rect(), false):
		w.stop_moving(u)
		w.deposit_carry(u, d)
		u.path_retries = 0
		_after_drop(w, u)
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
				_go_drop(w, u)


static func _after_drop(w: SimWorld, u: SimUnit) -> void:
	# Gathering into a full store is wasted work: go and gather what the town lacks instead.
	var res := w.econ.node_resource(u.gather_kind)
	if res != "" and _is_full(w, res, w.ledger.treasury(), w.storehouse_count()):
		var other := preferred_resources(w)
		if not other.is_empty() and other[0] != res and not _is_full(w, other[0], w.ledger.treasury(), w.storehouse_count()):
			JobUtil.release_claims(w, u)
			if auto_assign(w, u):
				return
	if _valid(w, u):
		u.phase = TO_NODE
		_go_node(w, u)
	else:
		_retarget(w, u)


## The target is gone or unreachable: find another of the same kind nearby, or wrap up.
static func _retarget(w: SimWorld, u: SimUnit) -> void:
	var origin := u.pos
	var n: SimResourceNode = w.nodes.get(u.target_id)
	if n != null:
		origin = n.center()
	var b: SimBuilding = w.buildings.get(u.target_id)
	if b != null:
		origin = b.center()
	var next_id := 0
	if u.gather_kind != "":
		if w.econ.building_is_field(u.gather_kind):
			var f := w.find_free_farm(origin, w.econ.retry_radius(), u.id, u.bad_targets)
			if f != null:
				next_id = f.id
		else:
			var nn := w.find_nearest_node(origin, [u.gather_kind], w.econ.retry_radius(), u.bad_targets)
			if nn != null:
				next_id = nn.id
	JobUtil.release_claims(w, u)
	if next_id != 0:
		u.target_id = next_id
		var nb: SimBuilding = w.buildings.get(next_id)
		if nb != null:
			nb.farmer_id = u.id
		u.path_retries = 0
		if u.carry_m >= capacity_m(w):
			u.phase = TO_DROP
			_go_drop(w, u)
		else:
			u.phase = TO_NODE
			_go_node(w, u)
		w.entity_changed.emit(u.id, SimWorld.CAT_UNIT)
		return
	u.target_id = 0
	if u.is_carrying():
		u.phase = TO_DROP
		_go_drop(w, u)
		return
	JobUtil.go_idle(w, u, false)
