extends GutTest
## Construction: build_s * 3 / (n + 2) with n builders, refunds, population and storage effects.


func test_formula_comes_from_economy() -> void:
	var e := SimFixture.econ()
	for type in ["cottage", "farm", "storehouse"]:
		var bs := e.building_build_s(type)
		for n in [1, 2, 3, 5, 8]:
			assert_almost_eq(ConstructionMath.duration_s(e, bs, n), bs * 3.0 / (n + 2.0), 0.0001,
				"%s with %d builders" % [type, n])
	assert_eq(ConstructionMath.duration_s(e, 25.0, 0), INF, "no builders, no progress")
	assert_almost_eq(ConstructionMath.duration_s(e, 25.0, 1), 25.0, 0.0001, "one builder takes build_s")


## Places a site at `cell` with `n` builders already standing next to it; returns ticks to finish.
func _build_ticks(type: String, n: int) -> Dictionary:
	var w := SimFixture.empty_world(SimFixture.big_purse())
	var cell := Vector2i(70, 64)
	var r := Rect2i(cell, w.econ.building_footprint(type))
	var ids: Array[int] = []
	var ring := Pathing.ring_cells(r)
	for i in n:
		ids.append(w.add_unit("townsfolk", Pathing.center_of(ring[i * 2])).id)
	w.commands.push(GameCommands.place_building(ids, type, cell))
	var ticks := 0
	var site: SimBuilding = null
	while ticks < 5000:
		w.step(1)
		ticks += 1
		if site == null:
			site = w.building_at(cell)
		if site != null and site.complete:
			break
	return {"w": w, "ticks": ticks, "site": site}


func _assert_build_time(type: String, n: int) -> void:
	var res := _build_ticks(type, n)
	var w: SimWorld = res["w"]
	var expected := w.econ.building_build_s(type) * 3.0 / (n + 2.0) * w.tick_rate
	assert_true((res["site"] as SimBuilding).complete)
	assert_between(float(res["ticks"]), expected, expected + 4.0,
		"%s with %d builders: %d ticks, formula %.1f" % [type, n, res["ticks"], expected])


func test_one_builder_takes_build_s() -> void:
	_assert_build_time("cottage", 1)


func test_more_builders_follow_the_formula() -> void:
	_assert_build_time("cottage", 2)
	_assert_build_time("cottage", 3)
	_assert_build_time("storehouse", 4)
	_assert_build_time("farm", 2)


func test_site_without_builders_does_not_progress() -> void:
	var w := SimFixture.empty_world(SimFixture.big_purse())
	w.commands.push(GameCommands.place_building([], "cottage", Vector2i(70, 64)))
	w.step(400)
	var b := w.building_at(Vector2i(70, 64))
	assert_not_null(b)
	assert_eq(b.work, 0)
	assert_false(b.complete)


func test_site_rises_gradually() -> void:
	var res := _build_ticks("cottage", 1)
	var w: SimWorld = res["w"]
	# Build a second one and look halfway.
	var u: SimUnit = w.units.values()[0]
	w.commands.push(GameCommands.place_building([u.id], "cottage", Vector2i(70, 58)))
	w.step(1)
	var site := w.building_at(Vector2i(70, 58))
	w.step(SimFixture.ticks(w, w.econ.building_build_s("cottage") * 0.5))
	assert_between(site.progress(), 0.3, 0.6, "halfway, allowing for the walk")


func test_cancel_refunds_everything() -> void:
	var w := SimFixture.empty_world({"food": 0, "wood": 200, "stone": 0, "gold": 0})
	w.commands.push(GameCommands.place_building([], "storehouse", Vector2i(70, 64)))
	w.step(1)
	var b := w.building_at(Vector2i(70, 64))
	assert_eq(w.ledger.amount("wood"), 200 - int(w.econ.building_cost("storehouse")["wood"]))
	w.commands.push(GameCommands.cancel_site(b.id))
	w.commands.push(GameCommands.cancel_site(b.id))
	w.step(1)
	assert_false(w.buildings.has(b.id))
	assert_eq(w.ledger.amount("wood"), 200, "full refund, and only once")
	assert_true(w.grid.is_walkable(Vector2i(70, 64)), "footprint freed")


func test_dismantle_refunds_half() -> void:
	var res := _build_ticks("cottage", 2)
	var w: SimWorld = res["w"]
	var b: SimBuilding = res["site"]
	var wood := w.ledger.amount("wood")
	var cost := int(w.econ.building_cost("cottage")["wood"])
	w.commands.push(GameCommands.dismantle(b.id))
	w.commands.push(GameCommands.dismantle(b.id))
	w.step(1)
	assert_false(w.buildings.has(b.id))
	assert_eq(w.ledger.amount("wood"), wood + int(floor(cost * w.econ.refund_fraction("dismantle"))))


func test_keep_cannot_be_dismantled() -> void:
	var w := SimFixture.empty_world()
	w.commands.push(GameCommands.dismantle(w.keep_id))
	w.step(1)
	assert_not_null(w.keep())


func test_cottage_raises_the_population_cap() -> void:
	var res := _build_ticks("cottage", 2)
	var w: SimWorld = res["w"]
	assert_eq(w.pop_cap(), w.econ.building_pop("keep") + w.econ.building_pop("cottage"))


func test_population_cap_is_limited_by_age() -> void:
	var w := SimFixture.empty_world()
	for i in 10:
		w.add_building("cottage", Vector2i(44 + (i % 5) * 3, 44 + (i / 5) * 3), true, "")
	assert_eq(w.pop_cap(), w.econ.pop_limit(1))


func test_storehouse_is_a_dropoff_and_adds_storage() -> void:
	var res := _build_ticks("storehouse", 3)
	var w: SimWorld = res["w"]
	var b: SimBuilding = res["site"]
	assert_eq(w.storehouse_count(), 1)
	assert_true(w.accepts(b, "wood"))
	assert_eq(w.nearest_dropoff(b.center() + Vector2(3, 0), "wood"), b, "closer than the Keep")
	assert_eq(w.ledger.storage_cap("wood", w.storehouse_count()), w.econ.storage_cap("wood", 1, 1))


func test_farm_builder_starts_farming() -> void:
	var res := _build_ticks("farm", 1)
	var w: SimWorld = res["w"]
	var farm: SimBuilding = res["site"]
	w.step(2)
	var u: SimUnit = w.units.values()[0]
	assert_eq(u.job, SimConst.JOB_GATHER)
	assert_eq(u.target_id, farm.id)
