extends GutTest
## Pathfinding: A* on the grid, edge cells of solid targets, partial paths meaning "can't reach",
## re-pathing, group moves and the PathService budget.


func _cell_goal(c: Vector2i) -> Rect2i:
	return Rect2i(c, Vector2i.ONE)


func test_straight_path() -> void:
	var g := SimGrid.new(32)
	var r := Pathing.find_path(g, Vector2i(2, 2), SimConst.GOAL_CELL, _cell_goal(Vector2i(10, 2)))
	assert_true(r["reached"])
	var p: Array[Vector2i] = r["path"]
	assert_eq(p[0], Vector2i(2, 2))
	assert_eq(p[p.size() - 1], Vector2i(10, 2))
	assert_eq(p.size(), 9)


func test_diagonals_never_cut_corners() -> void:
	var g := SimGrid.new(16)
	g.set_solid(Rect2i(5, 4, 1, 1), true)
	var r := Pathing.find_path(g, Vector2i(4, 4), SimConst.GOAL_CELL, _cell_goal(Vector2i(5, 5)))
	assert_true(r["reached"])
	assert_eq(r["path"], [Vector2i(4, 4), Vector2i(4, 5), Vector2i(5, 5)] as Array[Vector2i],
		"a diagonal past a solid corner is not allowed")


func test_path_goes_around_a_wall() -> void:
	var g := SimGrid.new(32)
	g.set_solid(Rect2i(10, 0, 1, 24), true)
	var r := Pathing.find_path(g, Vector2i(2, 10), SimConst.GOAL_CELL, _cell_goal(Vector2i(20, 10)))
	assert_true(r["reached"])
	var p: Array[Vector2i] = r["path"]
	var passed_gap := false
	for c in p:
		assert_true(g.is_walkable(c), "every step is walkable")
		if c.x == 10:
			passed_gap = c.y >= 24
	assert_true(passed_gap, "crosses the wall through the gap")


func test_unreachable_goal_gives_a_partial_path() -> void:
	var g := SimGrid.new(32)
	g.set_solid(Rect2i(10, 0, 1, 32), true)
	var r := Pathing.find_path(g, Vector2i(2, 10), SimConst.GOAL_CELL, _cell_goal(Vector2i(20, 10)))
	assert_false(r["reached"], "a partial path means can't reach")
	var p: Array[Vector2i] = r["path"]
	assert_gt(p.size(), 0)
	assert_eq(p[p.size() - 1].x, 9, "the partial path stops at the wall")


func test_solid_target_paths_to_a_free_edge_cell() -> void:
	var g := SimGrid.new(32)
	g.set_solid(Rect2i(15, 15, 1, 1), true)
	var r := Pathing.find_path(g, Vector2i(2, 2), SimConst.GOAL_ADJACENT, Rect2i(15, 15, 1, 1))
	assert_true(r["reached"])
	var p: Array[Vector2i] = r["path"]
	var last := p[p.size() - 1]
	assert_true(g.is_walkable(last))
	assert_eq(maxi(absi(last.x - 15), absi(last.y - 15)), 1, "ends next to the target")
	# A solid cell goal in GOAL_CELL mode also ends next to it.
	var r2 := Pathing.find_path(g, Vector2i(2, 2), SimConst.GOAL_CELL, _cell_goal(Vector2i(15, 15)))
	assert_true(r2["reached"])


func test_enclosed_target_is_unreachable() -> void:
	var g := SimGrid.new(32)
	g.set_solid(Rect2i(14, 14, 3, 3), true)
	var r := Pathing.find_path(g, Vector2i(2, 2), SimConst.GOAL_ADJACENT, Rect2i(15, 15, 1, 1))
	assert_false(r["reached"])


func test_gather_on_unreachable_node_gives_up() -> void:
	var w := SimFixture.empty_world()
	var tree := w.add_node("tree", Vector2i(75, 75))
	for c in Pathing.ring_cells(Rect2i(74, 74, 3, 3)):
		w.add_rock(c)
	var u := w.add_unit("townsfolk", Vector2(70.5, 64.5))
	w.commands.push(GameCommands.gather([u.id], tree.id))
	w.step(40)
	assert_ne(u.job, SimConst.JOB_GATHER, "can't reach: the gatherer gives up")
	assert_has(u.bad_targets, tree.id)


func test_move_to_unreachable_walks_as_close_as_it_can() -> void:
	var w := SimFixture.empty_world()
	for c in Pathing.ring_cells(Rect2i(76, 76, 3, 3)):
		w.add_rock(c)
	var u := w.add_unit("townsfolk", Vector2(70.5, 70.5))
	var notices: Array[String] = []
	w.notice.connect(func(kind: String, _d: Dictionary) -> void: notices.append(kind))
	w.commands.push(GameCommands.move([u.id], Vector2i(77, 77)))
	w.step(SimFixture.ticks(w, 20.0))
	assert_has(notices, "cant_reach")
	assert_lt(u.pos.distance_to(Vector2(77.5, 77.5)), 3.5, "ended next to the enclosure")
	assert_true(u.is_idle())


func test_units_repath_when_their_route_is_blocked() -> void:
	var w := SimFixture.empty_world()
	var u := w.add_unit("townsfolk", Vector2(46.5, 44.5))
	w.commands.push(GameCommands.move([u.id], Vector2i(46, 56)))
	w.step(3)
	assert_eq(u.path_state, SimConst.PATH_READY)
	var crosses := false
	for i in range(u.path_i, u.path.size()):
		if u.path[i] == Vector2i(46, 50):
			crosses = true
	assert_true(crosses, "the straight route crosses row 50")
	# A wall appears across the route (a building, as a construction site would).
	w.add_building("storehouse", Vector2i(45, 50), false, "")
	w.add_building("storehouse", Vector2i(47, 50), false, "")
	assert_eq(u.path_state, SimConst.PATH_PENDING, "the unit asked for a new path")
	w.step(SimFixture.ticks(w, 20.0))
	assert_eq(u.cell(), Vector2i(46, 56), "arrived around the new wall")


func test_group_move_spreads_over_distinct_cells() -> void:
	var w := SimFixture.empty_world()
	var ids: Array[int] = []
	for i in 6:
		ids.append(w.add_unit("townsfolk", Vector2(44.5 + i * 0.3, 64.5)).id)
	w.commands.push(GameCommands.move(ids, Vector2i(40, 80)))
	w.step(1)
	var goals := {}
	for id in ids:
		goals[w.units[id].goal_rect.position] = true
	assert_eq(goals.size(), 6, "each unit got its own target cell")
	w.step(SimFixture.ticks(w, 20.0))
	var cells := {}
	for id in ids:
		var u: SimUnit = w.units[id]
		assert_true(u.is_idle())
		assert_lt(u.pos.distance_to(Vector2(40.5, 80.5)), 3.0)
		cells[u.cell()] = true
	assert_gt(cells.size(), 3, "the group did not pile onto one cell")


func test_path_service_serves_within_its_budget() -> void:
	var w := SimFixture.empty_world()
	w.path_service.max_per_tick = 2
	var ids: Array[int] = []
	for i in 5:
		ids.append(w.add_unit("townsfolk", Vector2(50.5 + i, 50.5)).id)
	for id in ids:
		w.commands.push(GameCommands.move([id], Vector2i(40, 40 + id)))
	w.step(1)
	assert_eq(w.path_service.last_tick_served, 2)
	assert_eq(w.path_service.pending(), 3)
	w.step(1)
	assert_eq(w.path_service.pending(), 1)
	w.step(1)
	assert_eq(w.path_service.pending(), 0)


func test_time_budget_still_serves_one_per_tick() -> void:
	var w := SimFixture.empty_world()
	w.path_service.deterministic = false
	w.path_service.budget_usec = 0
	var u1 := w.add_unit("townsfolk", Vector2(50.5, 50.5))
	var u2 := w.add_unit("townsfolk", Vector2(52.5, 50.5))
	w.commands.push(GameCommands.move([u1.id], Vector2i(40, 40)))
	w.commands.push(GameCommands.move([u2.id], Vector2i(40, 42)))
	w.step(1)
	assert_gte(w.path_service.last_tick_served, 1)
	w.step(2)
	assert_eq(w.path_service.pending(), 0)


func test_formation_cells_are_distinct_and_walkable() -> void:
	var g := SimGrid.new(32)
	g.set_solid(Rect2i(10, 10, 2, 2), true)
	var cells := Pathing.formation_cells(g, Vector2i(10, 10), 12)
	assert_eq(cells.size(), 12)
	var seen := {}
	for c in cells:
		assert_true(g.is_walkable(c))
		seen[c] = true
	assert_eq(seen.size(), 12)


func test_ring_segments() -> void:
	var g := SimGrid.new(16)
	var r := Rect2i(5, 5, 2, 2)
	assert_eq(Pathing.ring_segments(g, r), 1)
	g.set_solid(Rect2i(4, 4, 4, 1), true)
	assert_eq(Pathing.ring_segments(g, r), 1, "one wall side keeps the ring connected")
	g.set_solid(Rect2i(4, 7, 4, 1), true)
	assert_eq(Pathing.ring_segments(g, r), 2, "walls above and below split it")
