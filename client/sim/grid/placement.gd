class_name Placement
extends RefCounted
## Validates a building footprint. The ghost preview calls check() whenever the hovered cell
## changes, and the place_building command checks again when it is applied.
##
## Checks, in order: known type and age, in bounds, clear of buildings, resources and rocks,
## inside the build zone, reachable from the Keep without cutting anything off (flood fill),
## and affordable. The result is {"ok": bool, "code": String, "reason": String}.

const NODE_LABELS := {"tree": "trees", "berry_bush": "berry bushes"}


static func check(w: SimWorld, type: String, cell: Vector2i, check_cost: bool = true) -> Dictionary:
	var econ := w.econ
	if not econ.has_building(type):
		return _fail("unknown", "Unknown building")
	var need_age := econ.building_age(type)
	if need_age > w.age:
		return _fail("age", "Requires the %s Age" % econ.age_name(need_age))
	var r := Rect2i(cell, econ.building_footprint(type))
	if not w.grid.rect_in_bounds(r):
		return _fail("bounds", "Out of bounds")
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var c := Vector2i(x, y)
			if w.grid.terrain_at(c) == SimGrid.TERRAIN_ROCK:
				return _fail("resource", "Blocked by rocks")
			var occ := w.grid.occupant_at(c)
			if occ == 0:
				continue
			if w.buildings.has(occ):
				return _fail("building", "Blocked by a building")
			var n: SimResourceNode = w.nodes.get(occ)
			if n != null and n.is_live():
				return _fail("resource", "Blocked by %s" % NODE_LABELS.get(n.kind, n.kind.replace("_", " ")))
	if not w.in_build_zone(r):
		return _fail("zone", "Outside the build zone")
	var reach := reach_problem(w, r, econ.building_is_field(type))
	if reach == "unreachable":
		return _fail(reach, "Can't be reached from the Keep")
	if reach == "cuts_off":
		return _fail(reach, "Would cut off part of the town")
	if check_cost:
		var missing := w.ledger.missing(econ.building_cost(type))
		if not missing.is_empty():
			return _fail("cost", "Need " + format_cost(missing))
	return {"ok": true, "code": "", "reason": ""}


## "" when a building on `r` stays reachable from the Keep and cuts nothing off; otherwise
## "unreachable" or "cuts_off". Walkable fields never block, so they only need a way in.
static func reach_problem(w: SimWorld, r: Rect2i, walkable: bool) -> String:
	var before := w.keep_region()
	if not FloodFill.touches(w.grid, before, r, walkable):
		return "unreachable"
	if walkable:
		return ""
	# If the free cells around the footprint form one run, any path through it can go around,
	# unless the footprint covers the Keep's own exits (the flood-fill seeds).
	var k := w.keep()
	var near_keep := k != null and r.intersects(k.rect().grow(1))
	if not near_keep and Pathing.ring_segments(w.grid, r) <= 1:
		return ""
	var seeds: Array[Vector2i] = []
	for s in w.keep_seeds():
		if not r.has_point(s):
			seeds.append(s)
	if seeds.is_empty():
		return "cuts_off"
	var after := FloodFill.region(w.grid, seeds, r)
	if not FloodFill.touches(w.grid, after, r, false):
		return "unreachable"
	for b: SimBuilding in w.buildings.values():
		if b.id == w.keep_id:
			continue
		if FloodFill.touches(w.grid, before, b.rect(), b.walkable) \
				and not FloodFill.touches(w.grid, after, b.rect(), b.walkable):
			return "cuts_off"
	for u: SimUnit in w.units.values():
		var c := u.cell()
		if not w.grid.in_bounds(c) or r.has_point(c):
			continue
		var i := w.grid.index(c)
		if before[i] == 1 and after[i] == 0:
			return "cuts_off"
	return ""


static func format_cost(cost: Dictionary) -> String:
	var parts: PackedStringArray = []
	for res: Variant in cost.keys():
		parts.append("%d %s" % [int(cost[res]), String(res).capitalize()])
	return ", ".join(parts)


static func _fail(code: String, reason: String) -> Dictionary:
	return {"ok": false, "code": code, "reason": reason}
