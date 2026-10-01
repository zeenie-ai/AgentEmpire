class_name WandererSystem
extends RefCounted
## Wanderers (economy.json anti_deadlock.wanderer), so a town can never get stuck: when it has
## at most `when_townsfolk_at_most` townsfolk and less than `when_food_below` Food (too little to
## train one), a free townsperson walks in from the map edge and joins; another follows every
## `every_s` seconds until the town has `until_townsfolk`. A wanderer costs nothing, walks to the
## Keep and then gathers like anyone else.
##
## Deterministic: the rescue is checked once a second of simulation time, and the n-th wanderer
## enters in line with the n-th gate of the outermost wall (the first through the south gate),
## at the first cell on the way in that the Keep can reach. Its state (SimWorld.wanderer_wait,
## wanderers_sent) is saved with the town.


static func rule(w: SimWorld) -> Dictionary:
	var v: Variant = w.econ.section("anti_deadlock").get("wanderer", {})
	return v if typeof(v) == TYPE_DICTIONARY else {}


static func tick(w: SimWorld) -> void:
	if not w.wanderers_enabled:
		return
	if w.wanderer_wait < 0:
		# No rescue under way: look once a second.
		if w.tick % w.tick_rate != 0 or not stranded(w):
			return
		w.wanderer_wait = 0
	var r := rule(w)
	if w.unit_count("townsfolk") >= int(r.get("until_townsfolk", 1)):
		w.wanderer_wait = -1
		return
	if w.wanderer_wait > 0:
		w.wanderer_wait -= 1
		return
	if spawn(w) != null:
		w.wanderer_wait = maxi(int(round(float(r.get("every_s", 30.0)) * float(w.tick_rate))), 1)
	else:
		w.wanderer_wait = w.tick_rate


## True when the town cannot help itself: too few townsfolk and too little Food to train one.
static func stranded(w: SimWorld) -> bool:
	var r := rule(w)
	if r.is_empty():
		return false
	return w.unit_count("townsfolk") <= int(r.get("when_townsfolk_at_most", 0)) \
		and w.ledger.amount("food") < int(r.get("when_food_below", 0))


## Brings the next wanderer in and sends it to the Keep. Returns the unit, or null when no cell
## on the way in can reach the Keep.
static func spawn(w: SimWorld) -> SimUnit:
	var cell := entry_cell(w, w.wanderers_sent)
	if cell == Pathing.NO_CELL:
		return null
	var u := w.add_unit("townsfolk", Pathing.center_of(cell))
	w.wanderers_sent += 1
	var k := w.keep()
	if k != null:
		JobUtil.face(u, k.center())
		var exits := w.exit_cells(k, Pathing.center_of(cell))
		if not exits.is_empty():
			MoveJob.start(w, u, exits[0], false)
	w.emit_notice("wanderer", {"unit": u.id, "cell": [cell.x, cell.y]})
	return u


## Where wanderer number `n` enters: walking in from the map edge along the n-th gate of the
## outermost wall (the south gate first), the first cell the Keep can reach.
static func entry_cell(w: SimWorld, n: int) -> Vector2i:
	var angle := PI * 0.5
	if w.walls != null and w.walls.ring_count() > 0:
		var gates: PackedFloat32Array = w.walls.ring_gates[w.walls.ring_count() - 1]
		angle = gates[posmod(n, gates.size())]
	else:
		angle += TAU * 0.381966 * float(n)
	var c := w.map_center()
	var dir := Vector2(cos(angle), sin(angle))
	var half := float(w.grid.size) * 0.5 - 0.5
	var reach := half / maxf(absf(dir.x), absf(dir.y))
	var region := w.keep_region()
	var steps := int(reach * 2.0)
	for i in steps:
		var p := c + dir * (reach - float(i) * 0.5)
		var cell := Pathing.cell_of(p)
		if w.grid.in_bounds(cell) and region[w.grid.index(cell)] == 1:
			return cell
	return Pathing.NO_CELL
