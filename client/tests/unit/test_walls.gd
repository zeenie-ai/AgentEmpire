extends GutTest
## Town walls: the layout (WallLayout), which rings stand at each age, pathing through gates,
## the reservation of every ring's line, towns from before the walls, and save/load.


func _layout() -> WallLayout:
	var e := SimFixture.econ()
	return WallLayout.for_economy(e, e.map_size())


## A generated town (Age I, so the Keep Ring stands).
func _town(seed_value: int = 4127) -> SimWorld:
	return SimFixture.generated_world(seed_value, SimFixture.big_purse())


## An empty map with walls (no trees or rocks in the way).
func _walled() -> SimWorld:
	var w := SimFixture.empty_world(SimFixture.big_purse())
	w.enable_walls()
	return w


## The cell nearest the middle of the n-th piece of `kind` in `ring`.
func _piece_cell(l: WallLayout, ring: int, kind: int, n: int) -> Vector2i:
	var list := l.pieces_of(ring, kind)
	var p := list[posmod(n, list.size())]
	var best := l.cell_of(p.cells[0])
	for ci in p.cells:
		var c := l.cell_of(ci)
		if (Vector2(c) + Vector2(0.5, 0.5)).distance_to(p.center) < (Vector2(best) + Vector2(0.5, 0.5)).distance_to(p.center):
			best = c
	return best


## A walkable cell `out` tiles outside the middle of the n-th curtain of `ring`.
func _beyond(w: SimWorld, ring: int, n: int, out: float) -> Vector2i:
	var p := w.walls.pieces_of(ring, WallLayout.CURTAIN)[n]
	var c := Pathing.cell_of(p.center + p.outward * out)
	return Pathing.nearest_walkable(w.grid, c, 3)


## A top-left cell where a footprint of `size` lies inside the build zone but touches ring
## `ring`'s line (not a gate road), or NO_CELL.
func _spot_on_line(w: SimWorld, ring: int, size: Vector2i) -> Vector2i:
	for p in w.walls.pieces_of(ring, WallLayout.CURTAIN):
		for ci in p.cells:
			var c := w.walls.cell_of(ci)
			for off: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
				var r := Rect2i(c - off, size)
				var hit := w.wall_reservation_in(r)
				if w.in_build_zone(r) and not hit.is_empty() and not bool(hit["gate"]):
					return r.position
	return Pathing.NO_CELL


## Flood fill from `seeds` with every gate passage and road shut.
func _region_with_gates_shut(w: SimWorld, seeds: Array[Vector2i]) -> PackedByteArray:
	var shut: Array[Vector2i] = []
	for i in w.walls.cell_gate.size():
		if w.walls.cell_gate[i] != 0:
			var c := w.walls.cell_of(i)
			if w.grid.is_walkable(c):
				shut.append(c)
				w.grid.set_solid(Rect2i(c, Vector2i.ONE), true)
	var region := FloodFill.region(w.grid, seeds)
	for c in shut:
		w.grid.set_solid(Rect2i(c, Vector2i.ONE), false)
	return region


# --- layout ------------------------------------------------------------------------------------

func test_layout_follows_the_economy() -> void:
	var e := SimFixture.econ()
	var l := _layout()
	var gates: Array = e.section("map")["gates_per_ring"]
	assert_eq(l.ring_count(), e.ring_radii().size())
	for k in l.ring_count():
		assert_eq(l.ring_gates[k].size(), int(gates[k]), "ring %d gates" % k)
		assert_eq(l.pieces_of(k, WallLayout.GATE).size(), int(gates[k]))
		assert_eq(l.pieces_of(k, WallLayout.GATE_TOWER).size(), int(gates[k]) * 2)
		assert_gt(l.pieces_of(k, WallLayout.TOWER).size(), 0, "ring %d has wall towers" % k)
		assert_gt(l.pieces_of(k, WallLayout.CURTAIN).size(), l.pieces_of(k, WallLayout.TOWER).size())
		assert_eq((l.ring_lines[k] as Array).size(), int(gates[k]), "one stretch of wall between two gates")
		# The first gate faces south, toward the default camera.
		var g0 := l.pieces_of(k, WallLayout.GATE)[0]
		assert_almost_eq(g0.center.x, l.center.x, 0.001)
		assert_gt(g0.center.y, l.center.y)


func test_cells_lie_on_their_ring() -> void:
	var l := _layout()
	for p in l.pieces:
		assert_gt(p.cells.size(), 0, "piece %d claims cells" % p.index)
		for ci in p.cells:
			var c := l.cell_of(ci)
			var d := (Vector2(c) + Vector2(0.5, 0.5)).distance_to(l.center)
			assert_lt(absf(d - l.radii[p.ring]), 4.6, "cell %s near ring %d" % [c, p.ring])
			assert_eq(l.piece_at(c), p.index)
			assert_eq(l.ring_at(c), p.ring)
			assert_eq(l.is_gate_cell(c), p.kind == WallLayout.GATE)


func test_gate_passages_are_two_cells_wide() -> void:
	var w := _walled()
	w.allow_debug_commands = true
	w.commands.push(GameCommands.debug_set_age(4))
	w.step(1)
	for g in w.walls.pieces_of(3, WallLayout.GATE):
		var t := Vector2(-g.outward.y, g.outward.x)
		var open := 0
		for i in range(-6, 7):
			var c := Pathing.cell_of(g.center + t * (float(i) * 0.25))
			if w.grid.is_walkable(c):
				open += 1
		assert_gte(open, 7, "gate at %.2f rad has a passage" % g.angle)


func test_layout_is_cached_and_deterministic() -> void:
	assert_same(_layout(), _layout())
	var radii: Array[float] = [11.0, 22.0]
	var gates: Array[int] = [4, 6]
	var a := WallLayout.build(96, radii, gates)
	WallLayout._cache.clear()
	var b := WallLayout.build(96, radii, gates)
	assert_eq(a.cell_piece, b.cell_piece)
	assert_eq(a.cell_ring, b.cell_ring)


# --- standing walls -----------------------------------------------------------------------------

func test_age_one_raises_the_keep_ring_only() -> void:
	var w := _town()
	assert_eq(w.age, 1)
	assert_eq(w.walls_up, 1)
	for p in w.walls.pieces:
		for ci in p.cells:
			var c := w.walls.cell_of(ci)
			if p.kind == WallLayout.GATE:
				assert_false(w.is_wall_cell(c), "gate road %s stays open" % c)
				assert_true(w.grid.is_walkable(c), "gate road %s is walkable" % c)
			elif p.ring == 0:
				assert_true(w.grid.is_solid(c), "Keep Ring piece at %s is solid" % c)
				assert_true(w.is_wall_cell(c))
			else:
				assert_false(w.is_wall_cell(c), "ring %d does not stand yet" % p.ring)


func test_walls_are_watertight_except_the_gates() -> void:
	var w := _walled()
	w.allow_debug_commands = true
	w.commands.push(GameCommands.debug_set_age(4))
	w.step(1)
	for k in w.walls_up:
		# Seeds just inside ring k; with every gate shut nothing outside it may be reached.
		var seeds: Array[Vector2i] = []
		if k == 0:
			seeds = w.keep_seeds()
		else:
			seeds.append(_beyond(w, k - 1, 2, 3.0))
		var region := _region_with_gates_shut(w, seeds)
		assert_gt(FloodFill.count(region), 20, "ring %d: the inside is open" % k)
		for n in [0, 5, 9]:
			var out := _beyond(w, k, n, 3.0)
			assert_eq(region[w.grid.index(out)], 0, "ring %d: %s outside is shut out" % [k, out])
	var open := w.keep_region()
	var far := Pathing.nearest_walkable(w.grid, Vector2i(64, 124), 6)
	assert_eq(open[w.grid.index(far)], 1, "with the gates open, the way out is free")


func test_units_walk_through_a_gate() -> void:
	var w := _walled()
	var u := w.add_unit("townsfolk", Pathing.center_of(Vector2i(70, 64)))
	var outside := _beyond(w, 0, 4, 3.0)
	w.commands.push(GameCommands.move([u.id], outside))
	var crossed := false
	for i in SimFixture.ticks(w, 45.0):
		w.step(1)
		if w.walls.is_gate_cell(u.cell()) and w.walls.ring_at(u.cell()) == 0:
			crossed = true
		if w.is_wall_cell(u.cell()):
			fail_test("walked into the wall at %s" % u.cell())
			return
	assert_true(crossed, "went through a Keep Ring gate")
	assert_lt(u.pos.distance_to(Pathing.center_of(outside)), 1.5, "arrived outside")


func test_advancing_raises_the_next_ring() -> void:
	var w := _town()
	var line := _piece_cell(w.walls, 1, WallLayout.CURTAIN, 3)
	assert_false(w.grid.is_solid(line))
	var notices: Array[String] = []
	w.notice.connect(func(kind: String, _d: Dictionary) -> void: notices.append(kind))
	var rings: Array[int] = []
	w.walls_changed.connect(func(ring: int) -> void: rings.append(ring))
	w.commands.push(GameCommands.set_age(2))
	w.step(1)
	assert_eq(w.walls_up, 2)
	assert_true(w.grid.is_solid(line), "the Merchant Ring stands")
	assert_true(w.grid.is_solid(_piece_cell(w.walls, 1, WallLayout.TOWER, 1)), "with its towers")
	assert_has(notices, "wall_raised")
	assert_has(notices, "age_changed")
	assert_eq(rings, [1] as Array[int])
	assert_eq(w.build_radius(), w.econ.ring_radii()[2], "the build zone moves out to the Guild Ring")


func test_falling_back_lowers_the_ring() -> void:
	var w := _town()
	w.commands.push(GameCommands.set_age(3))
	w.step(1)
	assert_eq(w.walls_up, 3)
	var line := _piece_cell(w.walls, 2, WallLayout.CURTAIN, 4)
	assert_true(w.grid.is_solid(line))
	w.commands.push(GameCommands.set_age(1))
	w.step(1)
	assert_eq(w.walls_up, 1)
	assert_false(w.grid.is_solid(line), "lowered")
	assert_false(w.grid.is_solid(_piece_cell(w.walls, 1, WallLayout.CURTAIN, 4)))


func test_a_rising_wall_clears_its_line_and_moves_people_off_it() -> void:
	var w := _walled()
	var line := _piece_cell(w.walls, 1, WallLayout.CURTAIN, 6)
	var tree := w.add_node("tree", line)
	var spot := _piece_cell(w.walls, 1, WallLayout.CURTAIN, 7)
	var u := w.add_unit("townsfolk", Pathing.center_of(spot))
	w.commands.push(GameCommands.set_age(2))
	w.step(1)
	assert_false(w.nodes.has(tree.id), "the tree on the line was felled")
	assert_false(w.is_wall_cell(u.cell()), "the townsperson stepped off the wall")
	assert_true(w.grid.is_walkable(u.cell()))


func test_debug_age_needs_debug_commands() -> void:
	var w := _town()
	w.commands.push(GameCommands.debug_set_age(3))
	w.step(1)
	assert_eq(w.age, 1, "ignored in normal play")
	w.allow_debug_commands = true
	w.commands.push(GameCommands.debug_set_age(3))
	w.step(1)
	assert_eq(w.age, 3)
	assert_eq(w.walls_up, 3)


# --- reservation ---------------------------------------------------------------------------------

func test_placement_refuses_every_rings_line() -> void:
	var w := _walled()
	var standing := _piece_cell(w.walls, 0, WallLayout.CURTAIN, 2)
	var res := Placement.check(w, "cottage", standing)
	assert_eq(res["code"], "wall")
	assert_string_contains(String(res["reason"]), "Keep Ring")
	var gate := w.walls.pieces_of(0, WallLayout.GATE)[1]
	res = Placement.check(w, "cottage", Pathing.cell_of(gate.center + gate.outward * 2.6))
	assert_eq(res["code"], "wall")
	assert_string_contains(String(res["reason"]), "road")
	var future := _spot_on_line(w, 1, w.econ.building_footprint("cottage"))
	assert_ne(future, Pathing.NO_CELL, "a spot inside the zone touching the Merchant Ring's line")
	res = Placement.check(w, "cottage", future)
	assert_eq(res["code"], "wall", str(res))
	assert_string_contains(String(res["reason"]), "Reserved for the Merchant Ring")
	assert_true(Placement.check(w, "cottage", Vector2i(70, 64))["ok"], "elsewhere is fine")


func test_plots_avoid_the_walls() -> void:
	var w := _walled()
	var home_type := w.econ.role_home("artificer")
	var on_wall := _piece_cell(w.walls, 0, WallLayout.CURTAIN, 5)
	var res := Placement.check_plot(w, home_type, on_wall)
	assert_eq(res["code"], "wall", str(res))


func test_generated_maps_keep_the_lines_clear() -> void:
	for seed_value in [5, 9, 4127]:
		var w := _town(seed_value)
		for n: SimResourceNode in w.nodes.values():
			assert_lt(w.wall_ring_at(n.cell), 0, "seed %d: no %s on a wall's line at %s" % [seed_value, n.kind, n.cell])
		for c in w.rocks:
			assert_lt(w.wall_ring_at(c), 0, "seed %d: no rock on a wall's line at %s" % [seed_value, c])


# --- legacy towns and saves ---------------------------------------------------------------------

func test_a_building_on_the_line_leaves_a_gap() -> void:
	var w := _walled()
	# Placed directly, as a town from before the walls had it (placement would refuse it).
	var spot := _piece_cell(w.walls, 1, WallLayout.CURTAIN, 8)
	var b := w.add_building("cottage", spot, true, "")
	w.commands.push(GameCommands.set_age(2))
	w.step(1)
	var gap := w.walls.piece_at(spot)
	assert_false(w.piece_stands(gap), "the piece under the cottage is left out")
	for ci in w.walls.pieces[gap].cells:
		var c := w.walls.cell_of(ci)
		if not b.rect().has_point(c):
			assert_false(w.grid.is_solid(c), "the rest of that piece stays open at %s" % c)
	assert_true(w.grid.is_solid(_piece_cell(w.walls, 1, WallLayout.CURTAIN, 2)), "the rest of the ring stands")
	# Once the cottage goes, the gap closes.
	w.remove_building(b.id)
	assert_true(w.piece_stands(gap))
	for ci in w.walls.pieces[gap].cells:
		assert_true(w.grid.is_solid(w.walls.cell_of(ci)))


func test_round_trip_keeps_the_walls() -> void:
	var w := _town(1234)
	w.commands.push(GameCommands.set_age(2))
	w.step(SimFixture.ticks(w, 3.0))
	var json := JSON.stringify(w.to_dict(), "", true, true)
	var ledger := LocalLedger.new(w.econ, {}, 1)
	ledger.load_dict(JSON.parse_string(JSON.stringify(w.ledger.to_dict())))
	var w2 := SimWorld.from_dict(JSON.parse_string(json), w.econ, ledger)
	w2.path_service.deterministic = true
	assert_eq(JSON.stringify(w2.to_dict(), "", true, true), json, "loads exactly as saved")
	assert_eq(w2.walls_up, 2)
	assert_eq(w2.grid.solid, w.grid.solid, "the same cells are solid")


func test_sandbox_maps_have_no_walls_until_asked() -> void:
	var w := SimFixture.empty_world()
	assert_null(w.walls)
	assert_eq(w.wall_ring_at(Vector2i(64, 75)), -1)
	var w2 := SimWorld.from_dict(w.to_dict(), w.econ, SimFixture.ledger(w.econ))
	assert_null(w2.walls, "a sandbox stays a sandbox")


func test_towns_from_before_the_walls_get_them() -> void:
	var w := SimFixture.empty_world()
	var l := _layout()
	# A cottage, a tree and a townsperson on the Keep Ring's line, as an old town could have.
	var spot := _piece_cell(l, 0, WallLayout.CURTAIN, 6)
	w.add_building("cottage", spot, true, "")
	var tree := w.add_node("tree", _piece_cell(l, 0, WallLayout.TOWER, 1))
	var u := w.add_unit("townsfolk", Pathing.center_of(_piece_cell(l, 0, WallLayout.CURTAIN, 1)))
	var d := w.to_dict()
	d["schema_version"] = 2
	d.erase("walls")
	d.erase("wanderer")
	var w2 := SimWorld.from_dict(JSON.parse_string(JSON.stringify(d)), w.econ, SimFixture.ledger(w.econ))
	assert_not_null(w2.walls, "an old town gets its walls")
	assert_true(w2.wanderers_enabled)
	assert_eq(w2.walls_up, 1)
	assert_false(w2.nodes.has(tree.id), "the tree on the line is cleared")
	assert_false(w2.is_wall_cell(w2.units[u.id].cell()), "the townsperson stands clear")
	assert_false(w2.piece_stands(w2.walls.piece_at(spot)), "the cottage leaves a gap")
