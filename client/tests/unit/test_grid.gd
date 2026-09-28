extends GutTest
## SimGrid, occupancy and solidity of buildings and resource nodes.


func test_astar_configuration() -> void:
	var g := SimGrid.new(128)
	assert_eq(g.astar.region, Rect2i(0, 0, 128, 128))
	assert_eq(g.astar.diagonal_mode, AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES)
	assert_eq(g.astar.default_compute_heuristic, AStarGrid2D.HEURISTIC_OCTILE)
	assert_eq(g.astar.default_estimate_heuristic, AStarGrid2D.HEURISTIC_OCTILE)


func test_bounds() -> void:
	var g := SimGrid.new(16)
	assert_true(g.in_bounds(Vector2i(0, 0)))
	assert_true(g.in_bounds(Vector2i(15, 15)))
	assert_false(g.in_bounds(Vector2i(16, 0)))
	assert_false(g.in_bounds(Vector2i(-1, 3)))
	assert_true(g.is_solid(Vector2i(-1, 3)), "outside the map counts as solid")
	assert_true(g.rect_in_bounds(Rect2i(14, 14, 2, 2)))
	assert_false(g.rect_in_bounds(Rect2i(15, 14, 2, 2)))


func test_set_solid_mirrors_astar() -> void:
	var g := SimGrid.new(32)
	var v := g.solid_version
	g.set_solid(Rect2i(10, 10, 3, 2), true)
	assert_gt(g.solid_version, v)
	for y in range(10, 12):
		for x in range(10, 13):
			assert_true(g.astar.is_point_solid(Vector2i(x, y)))
			assert_true(g.is_solid(Vector2i(x, y)))
	assert_false(g.is_solid(Vector2i(13, 10)))
	g.set_solid(Rect2i(10, 10, 3, 2), false)
	assert_false(g.astar.is_point_solid(Vector2i(11, 11)))
	assert_true(g.is_walkable(Vector2i(11, 11)))


func test_keep_sits_solid_at_the_centre() -> void:
	var w := SimFixture.empty_world()
	var k := w.keep()
	assert_not_null(k)
	assert_eq(k.size, w.econ.building_footprint("keep"))
	assert_eq(k.center(), w.map_center(), "the Keep is centred on the map")
	for y in range(k.cell.y, k.cell.y + k.size.y):
		for x in range(k.cell.x, k.cell.x + k.size.x):
			assert_true(w.grid.is_solid(Vector2i(x, y)))
			assert_eq(w.grid.occupant_at(Vector2i(x, y)), k.id)


func test_farm_is_walkable_but_occupied() -> void:
	var w := SimFixture.empty_world()
	var f := w.add_building("farm", Vector2i(70, 64), true, "")
	assert_true(f.walkable)
	assert_true(w.grid.is_walkable(Vector2i(71, 65)))
	assert_eq(w.grid.occupant_at(Vector2i(71, 65)), f.id)


func test_nodes_block_until_depleted() -> void:
	var w := SimFixture.empty_world()
	var n := w.add_node("tree", Vector2i(50, 50))
	assert_true(w.grid.is_solid(n.cell))
	assert_eq(n.amount_m, w.econ.node_amount("tree") * 1000)
	w.deplete_node(n)
	assert_false(w.grid.is_solid(n.cell), "stumps can be walked over")
	assert_has(w.regrowing, n.id)
	w.regrow_node(n)
	assert_true(w.grid.is_solid(n.cell))
	assert_eq(n.amount_m, n.max_m)


func test_nodes_regrow_after_regrow_time() -> void:
	var w := SimFixture.empty_world()
	var n := w.add_node("berry_bush", Vector2i(50, 50))
	w.deplete_node(n)
	w.step(SimFixture.ticks(w, w.econ.node_regrow_s("berry_bush")) - 5)
	assert_true(n.depleted, "still regrowing")
	w.step(10)
	assert_false(n.depleted, "regrown after regrow_s")
	assert_true(w.grid.is_solid(n.cell))


func test_building_over_a_stump_clears_it() -> void:
	var w := SimFixture.empty_world(SimFixture.big_purse())
	var n := w.add_node("tree", Vector2i(70, 64))
	w.deplete_node(n)
	var b := w.add_building("cottage", Vector2i(70, 64), false, "")
	assert_false(w.nodes.has(n.id), "the stump is gone for good")
	assert_eq(w.grid.occupant_at(Vector2i(70, 64)), b.id)


func test_units_are_pushed_out_of_new_footprints() -> void:
	var w := SimFixture.empty_world()
	var u := w.add_unit("townsfolk", Vector2(70.5, 64.5))
	w.add_building("cottage", Vector2i(70, 64), false, "")
	assert_true(w.grid.is_walkable(u.cell()), "unit moved to a free cell")


func test_spatial_hash() -> void:
	var h := SpatialHash.new(2.0)
	h.insert(1, Vector2(1, 1))
	h.insert(2, Vector2(1.4, 1.2))
	h.insert(3, Vector2(9, 9))
	var near := h.query(Vector2(1, 1), 0.6)
	assert_has(near, 1)
	assert_has(near, 2)
	assert_does_not_have(near, 3)
