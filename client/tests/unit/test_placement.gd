extends GutTest
## Placement validity: bounds, occupancy, build zone, reachability from the Keep, cost.

var w: SimWorld


func before_each() -> void:
	w = SimFixture.empty_world(SimFixture.big_purse())


func _code(type: String, cell: Vector2i) -> String:
	return String(Placement.check(w, type, cell)["code"])


func test_valid_spot() -> void:
	var res := Placement.check(w, "cottage", Vector2i(70, 64))
	assert_true(res["ok"], str(res))


func test_out_of_bounds() -> void:
	assert_eq(_code("cottage", Vector2i(-1, 5)), "bounds")
	assert_eq(_code("cottage", Vector2i(w.grid.size - 1, 10)), "bounds")


func test_blocked_by_a_building() -> void:
	var k := w.keep()
	assert_eq(_code("cottage", k.cell + Vector2i(1, 1)), "building")
	w.add_building("farm", Vector2i(70, 60), true, "")
	assert_eq(_code("cottage", Vector2i(71, 61)), "building", "farms are walkable but still occupy their cells")


func test_blocked_by_resources_and_rocks() -> void:
	w.add_node("tree", Vector2i(75, 64))
	assert_eq(_code("cottage", Vector2i(74, 63)), "resource")
	w.add_node("berry_bush", Vector2i(75, 70))
	assert_eq(_code("cottage", Vector2i(75, 70)), "resource")
	w.add_rock(Vector2i(60, 75))
	assert_eq(_code("cottage", Vector2i(59, 74)), "resource")


func test_depleted_nodes_do_not_block() -> void:
	var n := w.add_node("tree", Vector2i(75, 64))
	w.deplete_node(n)
	assert_true(Placement.check(w, "cottage", Vector2i(74, 63))["ok"])


func test_build_zone_radius() -> void:
	var r := float(w.build_radius())
	var c := w.map_center()
	# A cottage whose far cells sit just inside the radius is fine; one ring further is not.
	var inside := Vector2i(int(c.x + r) - 2, int(c.y) - 1)
	assert_true(Placement.check(w, "cottage", inside)["ok"], "inside the zone")
	assert_eq(_code("cottage", inside + Vector2i(1, 0)), "zone")
	assert_eq(_code("cottage", Vector2i(int(c.x + r) + 2, int(c.y))), "zone")


func test_unaffordable() -> void:
	var poor := SimFixture.empty_world({"food": 0, "wood": 0, "stone": 0, "gold": 0})
	var res := Placement.check(poor, "cottage", Vector2i(70, 64))
	assert_eq(res["code"], "cost")
	assert_string_contains(String(res["reason"]), "Wood")
	assert_true(Placement.check(poor, "cottage", Vector2i(70, 64), false)["ok"], "cost can be skipped")


func test_enclosed_pocket_is_unreachable() -> void:
	for c in Pathing.ring_cells(Rect2i(74, 74, 5, 5)):
		w.add_rock(c)
	assert_eq(_code("cottage", Vector2i(75, 75)), "unreachable")
	assert_eq(_code("farm", Vector2i(75, 75)), "unreachable")


## A rock ring around (74..78, 74..78) with a gap in its top side at x = 76 .. 76 + width - 1.
func _pocket_with_gap(width: int = 2) -> void:
	for c in Pathing.ring_cells(Rect2i(74, 74, 5, 5)):
		if not (c.y == 73 and c.x >= 76 and c.x < 76 + width):
			w.add_rock(c)


func test_closing_off_an_empty_pocket_is_allowed() -> void:
	_pocket_with_gap()
	assert_true(Placement.check(w, "cottage", Vector2i(76, 72))["ok"])


func test_cutting_off_a_unit_is_not_allowed() -> void:
	_pocket_with_gap()
	w.add_unit("townsfolk", Vector2(76.5, 76.5))
	assert_eq(_code("cottage", Vector2i(76, 72)), "cuts_off")


func test_a_farm_never_cuts_anything_off() -> void:
	_pocket_with_gap(3)
	w.add_unit("townsfolk", Vector2(76.5, 76.5))
	assert_true(Placement.check(w, "farm", Vector2i(76, 71))["ok"], "farms are walkable")


func test_cutting_off_a_building_is_not_allowed() -> void:
	_pocket_with_gap()
	w.add_building("cottage", Vector2i(76, 76), true, "")
	assert_eq(_code("cottage", Vector2i(76, 72)), "cuts_off")


func test_sealing_the_keep_is_not_allowed() -> void:
	# Leave the Keep a single two-cell exit on its south side, then try to block it.
	var k := w.keep().rect()
	for c in Pathing.ring_cells(k):
		if not (c.y == k.end.y and (c.x == k.position.x + 1 or c.x == k.position.x + 2)):
			w.add_rock(c)
	w.add_unit("townsfolk", Vector2(40.5, 40.5))
	assert_ne(_code("cottage", Vector2i(k.position.x + 1, k.end.y)), "", "blocking the last exit is refused")


func test_place_command_rechecks_and_pays() -> void:
	var wood := w.ledger.amount("wood")
	w.commands.push(GameCommands.place_building([], "cottage", Vector2i(70, 64)))
	w.commands.push(GameCommands.place_building([], "cottage", Vector2i(70, 64)))
	var notices: Array[String] = []
	w.notice.connect(func(kind: String, _d: Dictionary) -> void: notices.append(kind))
	w.step(1)
	assert_eq(w.ledger.amount("wood"), wood - int(w.econ.building_cost("cottage")["wood"]), "paid once")
	assert_has(notices, "placement_invalid", "the second one overlaps the first")
	var b := w.building_at(Vector2i(70, 64))
	assert_not_null(b)
	assert_false(b.complete)
