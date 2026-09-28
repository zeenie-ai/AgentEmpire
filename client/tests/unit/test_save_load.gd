extends GutTest
## JSON save/load round trip of the simulation (the snapshot Phase 3's save_town sends).


func _json(d: Dictionary) -> String:
	return JSON.stringify(d, "", true, true)


func _free_cottage_spot(w: SimWorld) -> Vector2i:
	var c := Vector2i(w.map_center())
	for r in range(4, 14):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var cell := c + Vector2i(dx, dy)
				if Placement.check(w, "cottage", cell)["ok"]:
					return cell
	return Pathing.NO_CELL


## A generated town with some activity: gathering, a build and training in progress.
func _busy_world() -> SimWorld:
	var w := SimFixture.generated_world(1234)
	var ids: Array = w.units.keys()
	w.commands.push(GameCommands.train(w.keep_id, "townsfolk"))
	w.commands.push(GameCommands.train(w.keep_id, "townsfolk"))
	w.step(SimFixture.ticks(w, 12.0))
	var spot := _free_cottage_spot(w)
	assert_ne(spot, Pathing.NO_CELL, "found a building spot")
	w.commands.push(GameCommands.place_building([ids[0]], "cottage", spot))
	w.step(SimFixture.ticks(w, 6.0))
	return w


func _load(w: SimWorld, json: String) -> SimWorld:
	var ledger := LocalLedger.new(w.econ, {}, 1)
	ledger.load_dict(JSON.parse_string(JSON.stringify(w.ledger.to_dict())))
	var parsed: Dictionary = JSON.parse_string(json)
	var w2 := SimWorld.from_dict(parsed, w.econ, ledger)
	if w2 != null:
		w2.path_service.deterministic = true
	return w2


func test_round_trip_is_exact() -> void:
	var w := _busy_world()
	var json := _json(w.to_dict())
	var w2 := _load(w, json)
	assert_not_null(w2)
	assert_eq(_json(w2.to_dict()), json, "to_dict after loading equals the saved snapshot")
	assert_eq(w2.units.size(), w.units.size())
	assert_eq(w2.buildings.size(), w.buildings.size())
	assert_eq(w2.nodes.size(), w.nodes.size())
	assert_eq(w2.keep().queue.size(), w.keep().queue.size())
	for y in w.grid.size:
		for x in w.grid.size:
			var c := Vector2i(x, y)
			if w.grid.is_solid(c) != w2.grid.is_solid(c):
				fail_test("solidity differs at %s" % c)
				return
	pass_test("grids match")


func test_loaded_world_keeps_stepping_identically() -> void:
	var w := _busy_world()
	var w2 := _load(w, _json(w.to_dict()))
	var n := SimFixture.ticks(w, 30.0)
	w.step(n)
	w2.step(n)
	assert_eq(_json(w2.to_dict()), _json(w.to_dict()), "same commands, same result")
	assert_eq(w2.ledger.treasury(), w.ledger.treasury())


func test_snapshot_is_plain_json() -> void:
	var w := _busy_world()
	var d := w.to_dict()
	assert_true(_only_json_types(d), "no Vector2/Rect2/Object values in the snapshot")
	assert_eq(int(d["schema_version"]), SimConst.SCHEMA_VERSION)
	var size := _json(d).length()
	gut.p("snapshot size: %d bytes" % size)
	assert_lt(size, 1024 * 1024, "fits in one protocol frame (1 MiB)")


func test_newer_schema_is_rejected() -> void:
	var w := SimFixture.empty_world()
	var d := w.to_dict()
	d["schema_version"] = SimConst.SCHEMA_VERSION + 1
	assert_null(SimWorld.from_dict(d, w.econ, SimFixture.ledger(w.econ)))


func _only_json_types(v: Variant) -> bool:
	match typeof(v):
		TYPE_DICTIONARY:
			for k: Variant in (v as Dictionary).keys():
				if typeof(k) != TYPE_STRING or not _only_json_types(v[k]):
					return false
			return true
		TYPE_ARRAY:
			for e: Variant in v:
				if not _only_json_types(e):
					return false
			return true
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return true
	return false
