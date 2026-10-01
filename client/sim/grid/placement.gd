class_name Placement
extends RefCounted
## Validates a building footprint. The ghost preview calls check() whenever the hovered cell
## changes, and the place_building command checks again when it is applied.
##
## Checks, in order: known type and age, in bounds, clear of buildings, resources and rocks,
## inside the build zone, off the town walls' line (every ring's cells and gate roads are
## reserved from the start, standing or not), reachable from the Keep without cutting anything
## off (flood fill), and affordable. The result is {"ok": bool, "code": String, "reason": String}.

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
	var wall := wall_problem(w, r)
	if wall != "":
		return _fail("wall", wall)
	for plot: Rect2i in w.plots().values():
		if plot.intersects(r):
			return _fail("plot", "Inside an agent's plot")
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


## Validates an agent's plot (HomeLayout): the whole 7x7 must be clear ground inside the build
## zone, off other plots and not touching the Keep, and the home in its middle must be reachable
## without cutting anything off. Costs are the Town Hall's to check. `home_cell` is the home's
## top-left cell.
static func check_plot(w: SimWorld, home_type: String, home_cell: Vector2i) -> Dictionary:
	var econ := w.econ
	if not econ.is_home(home_type):
		return _fail("unknown", "Unknown home")
	var plot := HomeLayout.plot_rect(home_cell)
	if not w.grid.rect_in_bounds(plot):
		return _fail("bounds", "Out of bounds")
	var k := w.keep()
	if k != null and plot.intersects(k.rect().grow(1)):
		return _fail("keep", "Too close to the Keep")
	for other: Rect2i in w.plots().values():
		if other.intersects(plot):
			return _fail("plot", "Overlaps another agent's plot")
	for y in range(plot.position.y, plot.end.y):
		for x in range(plot.position.x, plot.end.x):
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
	if not w.in_build_zone(plot):
		return _fail("zone", "Outside the build zone")
	var wall := wall_problem(w, plot)
	if wall != "":
		return _fail("wall", wall)
	var home := Rect2i(home_cell, econ.building_footprint(home_type))
	var reach := reach_problem(w, home, false)
	if reach == "unreachable":
		return _fail(reach, "Can't be reached from the Keep")
	if reach == "cuts_off":
		return _fail(reach, "Would cut off part of the town")
	return {"ok": true, "code": "", "reason": ""}


## Why the town walls keep `r` free ("" when they do not): a standing wall, a gate's road, or
## the line a future ring will stand on.
static func wall_problem(w: SimWorld, r: Rect2i) -> String:
	var hit := w.wall_reservation_in(r)
	if hit.is_empty():
		return ""
	var ring_name := w.wall_name(int(hit["ring"]))
	if bool(hit["gate"]):
		return "The road through the %s's gate must stay clear" % ring_name
	if bool(hit["standing"]):
		return "Blocked by the %s" % ring_name
	return "Reserved for the %s" % ring_name


static func format_cost(cost: Dictionary) -> String:
	var parts: PackedStringArray = []
	for res: Variant in cost.keys():
		parts.append("%d %s" % [int(cost[res]), String(res).capitalize()])
	return ", ".join(parts)


static func _fail(code: String, reason: String) -> Dictionary:
	return {"ok": false, "code": code, "reason": reason}
