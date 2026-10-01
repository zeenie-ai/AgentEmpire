extends GutTest
## Seeded map generation.


func test_same_seed_same_map() -> void:
	var a := SimFixture.generated_world(77)
	var b := SimFixture.generated_world(77)
	assert_eq(JSON.stringify(a.to_dict(), "", true), JSON.stringify(b.to_dict(), "", true))


func test_different_seeds_differ() -> void:
	var a := SimFixture.generated_world(77)
	var b := SimFixture.generated_world(78)
	assert_ne(JSON.stringify(a.to_dict()["nodes"]), JSON.stringify(b.to_dict()["nodes"]))


func test_keep_at_the_centre_with_starting_townsfolk() -> void:
	var w := SimFixture.generated_world(5)
	assert_eq(w.keep().center(), w.map_center())
	assert_eq(w.unit_count("townsfolk"), w.econ.start_townsfolk())
	for u: SimUnit in w.units.values():
		assert_true(w.grid.is_walkable(u.cell()))


func test_resources_and_clearing() -> void:
	var w := SimFixture.generated_world(9)
	var c := w.map_center()
	var trees := 0
	var bushes := 0
	var near_trees := 0
	var near_bushes := 0
	for n: SimResourceNode in w.nodes.values():
		var d := n.center().distance_to(c)
		if n.kind == "tree":
			trees += 1
			assert_gte(d, MapGenerator.TREE_CLEAR_RADIUS, "the Keep's clearing stays open")
			if d <= 20.0:
				near_trees += 1
		elif n.kind == "berry_bush":
			bushes += 1
			if d <= 12.0:
				near_bushes += 1
		assert_eq(n.amount_m, w.econ.node_amount(n.kind) * 1000, "amounts come from economy.json")
	gut.p("seed 9: %d trees, %d berry bushes, %d rocks" % [trees, bushes, w.rocks.size()])
	assert_gt(trees, 800)
	assert_gt(bushes, 40)
	assert_gt(near_trees, 20, "wood within a short walk")
	assert_gt(near_bushes, 5, "berries near the Keep")
	assert_gt(w.rocks.size(), 10)


func test_nearby_resources_are_reachable() -> void:
	var w := SimFixture.generated_world(11)
	var region := w.keep_region()
	var c := w.map_center()
	var reachable := {"tree": 0, "berry_bush": 0}
	for n: SimResourceNode in w.nodes.values():
		if n.center().distance_to(c) > 20.0:
			continue
		if FloodFill.touches(w.grid, region, n.rect(), false):
			reachable[n.kind] = int(reachable[n.kind]) + 1
	assert_gt(int(reachable["tree"]), 10)
	assert_gt(int(reachable["berry_bush"]), 5)


func test_the_town_comes_alive() -> void:
	var w := SimFixture.generated_world(21)
	var food := w.ledger.amount("food")
	var wood := w.ledger.amount("wood")
	w.step(SimFixture.ticks(w, 90.0))
	var working := 0
	for u: SimUnit in w.units.values():
		if u.job == SimConst.JOB_GATHER:
			working += 1
	assert_eq(working, w.units.size(), "idle townsfolk found work on their own")
	assert_gt(w.ledger.amount("food") + w.ledger.amount("wood"), food + wood)


func test_room_for_agent_homes_in_the_first_age() -> void:
	# Agents' 7 x 7 plots must fit between the Keep Ring and the edge of the first age's build
	# zone; forests, strays and rocks once left room for a single home.
	for seed_value: int in [4127, 9]:
		var w := SimFixture.generated_world(seed_value)
		var plots := _plots_that_fit(w, "workshop")
		gut.p("seed %d: %d agent plots fit at once" % [seed_value, plots])
		assert_gte(plots, 4, "seed %d: room for at least four agent homes at once" % seed_value)


## How many plots for `home_type` fit at once in the build zone (greedy, without overlaps).
func _plots_that_fit(w: SimWorld, home_type: String) -> int:
	var taken: Array[Rect2i] = []
	var c := Vector2i(w.map_center())
	var r := w.build_radius() + 1
	for y in range(c.y - r, c.y + r):
		for x in range(c.x - r, c.x + r):
			var cell := Vector2i(x, y)
			if not bool(Placement.check_plot(w, home_type, cell)["ok"]):
				continue
			var plot := Rect2i(cell, Vector2i(HomeLayout.PLOT, HomeLayout.PLOT))
			var free := true
			for t: Rect2i in taken:
				if t.intersects(plot):
					free = false
					break
			if free:
				taken.append(plot)
	return taken.size()
