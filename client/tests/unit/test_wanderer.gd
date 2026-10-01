extends GutTest
## Wanderers (economy.json anti_deadlock.wanderer): a town with no townsfolk and too little Food
## to train one gets free townsfolk who walk in from the map edge.


func _rule() -> Dictionary:
	return SimFixture.econ().section("anti_deadlock")["wanderer"]


## A walled town with no townsfolk and `food` Food, wanderers on.
func _stranded(food: int) -> SimWorld:
	var w := SimFixture.empty_world({"food": food, "wood": 0, "stone": 0, "gold": 0})
	w.enable_walls()
	w.wanderers_enabled = true
	return w


func _notices(w: SimWorld, kind: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	w.notice.connect(func(k: String, d: Dictionary) -> void:
		if k == kind:
			out.append(d))
	return out


func test_a_wanderer_walks_in_and_joins() -> void:
	var w := _stranded(10)
	var seen := _notices(w, "wanderer")
	w.step(SimFixture.ticks(w, 1.5))
	assert_eq(w.unit_count("townsfolk"), 1, "one wanderer came")
	assert_eq(seen.size(), 1)
	var u: SimUnit = w.units.values()[0]
	var edge := mini(mini(u.cell().x, u.cell().y), mini(w.grid.size - 1 - u.cell().x, w.grid.size - 1 - u.cell().y))
	assert_lt(edge, 3, "it enters at the map edge (%s)" % u.cell())
	assert_gt(u.pos.y, w.map_center().y, "the first one comes up the south road")
	assert_eq(u.job, SimConst.JOB_MOVE, "and heads for the Keep")
	w.step(SimFixture.ticks(w, 70.0))
	var k := w.keep()
	assert_lt(Pathing.rect_distance(u.pos, k.rect()), 12.0, "it reached the Keep")


func test_more_follow_until_the_town_has_enough() -> void:
	var r := _rule()
	var w := _stranded(0)
	var every := float(r["every_s"])
	var until := int(r["until_townsfolk"])
	w.step(SimFixture.ticks(w, 1.5))
	assert_eq(w.unit_count("townsfolk"), 1)
	w.step(SimFixture.ticks(w, every - 3.0))
	assert_eq(w.unit_count("townsfolk"), 1, "the next waits %d s" % int(every))
	w.step(SimFixture.ticks(w, 4.0))
	assert_eq(w.unit_count("townsfolk"), mini(2, until))
	w.step(SimFixture.ticks(w, every * 3.0))
	assert_eq(w.unit_count("townsfolk"), until, "no more than %d" % until)
	assert_eq(w.wanderer_wait, -1, "the rescue is over")
	assert_eq(w.wanderers_sent, until)


func test_no_wanderer_while_the_town_can_help_itself() -> void:
	var r := _rule()
	var fed := _stranded(int(r["when_food_below"]))
	fed.step(SimFixture.ticks(fed, 5.0))
	assert_eq(fed.unit_count("townsfolk"), 0, "enough Food to train one")
	var staffed := _stranded(0)
	staffed.add_unit("townsfolk", Pathing.center_of(Vector2i(70, 64)))
	staffed.step(SimFixture.ticks(staffed, 5.0))
	assert_eq(staffed.unit_count("townsfolk"), 1, "someone is still there")


func test_off_on_sandbox_maps() -> void:
	var w := SimFixture.empty_world({"food": 0, "wood": 0, "stone": 0, "gold": 0})
	w.step(SimFixture.ticks(w, 5.0))
	assert_eq(w.unit_count("townsfolk"), 0)


func test_new_towns_have_wanderers() -> void:
	var w := SimFixture.generated_world(77)
	assert_true(w.wanderers_enabled)


func test_saved_mid_rescue_steps_identically() -> void:
	var w := _stranded(0)
	w.step(SimFixture.ticks(w, 8.0))
	assert_eq(w.unit_count("townsfolk"), 1)
	var json := JSON.stringify(w.to_dict(), "", true, true)
	var ledger := LocalLedger.new(w.econ, {}, 1)
	ledger.load_dict(JSON.parse_string(JSON.stringify(w.ledger.to_dict())))
	var w2 := SimWorld.from_dict(JSON.parse_string(json), w.econ, ledger)
	w2.path_service.deterministic = true
	assert_eq(JSON.stringify(w2.to_dict(), "", true, true), json)
	assert_eq(w2.wanderer_wait, w.wanderer_wait)
	var n := SimFixture.ticks(w, 40.0)
	w.step(n)
	w2.step(n)
	assert_eq(w2.unit_count("townsfolk"), w.unit_count("townsfolk"))
	assert_eq(JSON.stringify(w2.to_dict(), "", true, true), JSON.stringify(w.to_dict(), "", true, true))


func test_entry_points_are_reachable() -> void:
	var w := SimFixture.generated_world(4127)
	var region := w.keep_region()
	for n in 8:
		var c := WandererSystem.entry_cell(w, n)
		assert_ne(c, Pathing.NO_CELL)
		assert_eq(region[w.grid.index(c)], 1, "entry %d at %s reaches the Keep" % [n, c])
