extends GutTest
## Gathering: yields over 120 simulated seconds match economy.json rates, retargeting, idle
## auto-gathering, Gather Focus, farms and storage caps.

const TOLERANCE := 0.10


## A node right of the Keep and a townsperson touching both, so no walking is involved.
func _adjacent_setup(kind: String) -> Dictionary:
	var w := SimFixture.empty_world()
	var k := w.keep().rect()
	var node := w.add_node(kind, Vector2i(k.end.x, k.position.y + 2))
	var u := w.add_unit("townsfolk", Pathing.center_of(Vector2i(k.end.x, k.position.y + 1)))
	return {"w": w, "target": node.id, "unit": u}


func _gathered(w: SimWorld, u: SimUnit, res: String, seconds: float) -> float:
	var before := w.ledger.amount(res)
	w.step(SimFixture.ticks(w, seconds))
	var carried := u.carry_m / 1000.0 if u.carry_res == res else 0.0
	return float(w.ledger.amount(res) - before) + carried


func _assert_rate(w: SimWorld, u: SimUnit, kind: String) -> void:
	var res := w.econ.node_resource(kind)
	var got := _gathered(w, u, res, 120.0)
	var expected := w.econ.node_rate(kind) * 120.0
	assert_between(got, expected * (1.0 - TOLERANCE), expected * (1.0 + TOLERANCE),
		"%s: %.1f %s in 120 s, expected %.1f" % [kind, got, res, expected])
	gut.p("%s yield over 120 s: %.2f (economy.json rate gives %.1f)" % [kind, got, expected])


func test_berry_yield_matches_rate() -> void:
	var s := _adjacent_setup("berry_bush")
	var w: SimWorld = s["w"]
	w.commands.push(GameCommands.gather([s["unit"].id], s["target"]))
	_assert_rate(w, s["unit"], "berry_bush")


func test_tree_yield_matches_rate() -> void:
	var s := _adjacent_setup("tree")
	var w: SimWorld = s["w"]
	w.commands.push(GameCommands.gather([s["unit"].id], s["target"]))
	_assert_rate(w, s["unit"], "tree")


func test_farm_yield_matches_rate() -> void:
	var w := SimFixture.empty_world()
	var k := w.keep().rect()
	var farm := w.add_building("farm", Vector2i(k.end.x, k.position.y), true, "")
	var u := w.add_unit("townsfolk", Pathing.center_of(Vector2i(k.end.x, k.position.y + 1)))
	w.commands.push(GameCommands.gather([u.id], farm.id))
	_assert_rate(w, u, "farm")
	assert_eq(farm.farmer_id, u.id)


func test_trips_carry_a_full_load() -> void:
	var s := _adjacent_setup("berry_bush")
	var w: SimWorld = s["w"]
	var u: SimUnit = s["unit"]
	var deposits: Array[int] = []
	w.notice.connect(func(kind: String, d: Dictionary) -> void:
		if kind == "deposited":
			deposits.append(int(d["amount"])))
	w.commands.push(GameCommands.gather([u.id], s["target"]))
	w.step(SimFixture.ticks(w, 60.0))
	assert_gt(deposits.size(), 0)
	for amt in deposits:
		assert_eq(amt, w.econ.carry_capacity(w.age))


func test_walking_gatherer_still_delivers() -> void:
	var w := SimFixture.empty_world()
	var k := w.keep().rect()
	var tree := w.add_node("tree", Vector2i(k.end.x + 6, k.position.y))
	var u := w.add_unit("townsfolk", Pathing.center_of(Vector2i(k.end.x, k.position.y)))
	w.commands.push(GameCommands.gather([u.id], tree.id))
	var got := _gathered(w, u, "wood", 120.0)
	var ideal := w.econ.node_rate("tree") * 120.0
	assert_between(got, ideal * 0.5, ideal, "walking costs time but the loop keeps going")


func test_moves_to_a_nearby_node_of_the_same_kind() -> void:
	var s := _adjacent_setup("tree")
	var w: SimWorld = s["w"]
	var u: SimUnit = s["unit"]
	var first: SimResourceNode = w.nodes[s["target"]]
	first.amount_m = 3000
	var second := w.add_node("tree", first.cell + Vector2i(3, 2))
	w.add_node("berry_bush", first.cell + Vector2i(1, 1))
	w.commands.push(GameCommands.gather([u.id], first.id))
	w.step(SimFixture.ticks(w, 12.0))
	assert_true(first.depleted)
	assert_eq(u.job, SimConst.JOB_GATHER)
	assert_eq(u.target_id, second.id, "retargeted the other tree, not the bush")


func test_goes_idle_when_nothing_of_that_kind_is_near() -> void:
	var s := _adjacent_setup("tree")
	var w: SimWorld = s["w"]
	var u: SimUnit = s["unit"]
	var first: SimResourceNode = w.nodes[s["target"]]
	first.amount_m = 3000
	var far_cell := first.cell + Vector2i(int(w.econ.retry_radius()) + 6, 0)
	w.add_node("tree", far_cell)
	w.commands.push(GameCommands.gather([u.id], first.id))
	w.step(SimFixture.ticks(w, 10.0))
	assert_true(first.depleted)
	assert_eq(w.ledger.amount("wood"), w.econ.start_resources()["wood"] + 3, "delivered what it had")
	var went_idle := false
	for i in SimFixture.ticks(w, 3.0):
		w.step(1)
		if u.is_idle():
			went_idle = true
			break
	assert_true(went_idle, "no other tree within the retry radius: idle")


func test_idle_townsfolk_gather_the_lower_resource() -> void:
	var w := SimFixture.empty_world({"food": 40, "wood": 300, "stone": 0, "gold": 0})
	var k := w.keep().rect()
	var bush := w.add_node("berry_bush", Vector2i(k.end.x + 3, k.position.y))
	var tree := w.add_node("tree", Vector2i(k.position.x - 4, k.position.y))
	var u := w.add_unit("townsfolk", Pathing.center_of(Vector2i(k.position.x + 1, k.end.y)))
	w.step(SimFixture.ticks(w, SimConst.AUTO_GATHER_DELAY_S + 0.5))
	assert_eq(u.job, SimConst.JOB_GATHER)
	assert_eq(u.target_id, bush.id, "food is lower")
	assert_ne(u.target_id, tree.id)


func test_idle_townsfolk_pick_wood_when_wood_is_lower() -> void:
	var w := SimFixture.empty_world({"food": 300, "wood": 40, "stone": 0, "gold": 0})
	var k := w.keep().rect()
	w.add_node("berry_bush", Vector2i(k.end.x + 3, k.position.y))
	var tree := w.add_node("tree", Vector2i(k.position.x - 4, k.position.y))
	var u := w.add_unit("townsfolk", Pathing.center_of(Vector2i(k.position.x + 1, k.end.y)))
	w.step(SimFixture.ticks(w, SimConst.AUTO_GATHER_DELAY_S + 0.5))
	assert_eq(u.target_id, tree.id)


func test_gather_focus_overrides_the_lower_resource() -> void:
	var w := SimFixture.empty_world({"food": 40, "wood": 300, "stone": 0, "gold": 0})
	var k := w.keep()
	w.add_node("berry_bush", Vector2i(k.rect().end.x + 3, k.cell.y))
	var tree := w.add_node("tree", Vector2i(k.cell.x - 4, k.cell.y))
	var u := w.add_unit("townsfolk", Pathing.center_of(Vector2i(k.cell.x + 1, k.rect().end.y)))
	w.commands.push(GameCommands.set_gather_focus(k.id, "wood"))
	w.step(SimFixture.ticks(w, SimConst.AUTO_GATHER_DELAY_S + 0.5))
	assert_eq(k.gather_focus, "wood")
	assert_eq(u.target_id, tree.id)


func test_stopped_townsfolk_stay_idle() -> void:
	var w := SimFixture.empty_world()
	var k := w.keep().rect()
	w.add_node("berry_bush", Vector2i(k.end.x + 2, k.position.y))
	var u := w.add_unit("townsfolk", Pathing.center_of(Vector2i(k.position.x + 1, k.end.y)))
	w.commands.push(GameCommands.stop([u.id]))
	w.step(SimFixture.ticks(w, 10.0))
	assert_true(u.is_idle())
	assert_true(u.hold)


func test_one_gatherer_per_farm() -> void:
	var w := SimFixture.empty_world()
	var k := w.keep().rect()
	var farm := w.add_building("farm", Vector2i(k.end.x, k.position.y), true, "")
	var a := w.add_unit("townsfolk", Pathing.center_of(Vector2i(k.end.x, k.position.y + 1)))
	var b := w.add_unit("townsfolk", Pathing.center_of(Vector2i(k.end.x + 1, k.position.y + 1)))
	var notices: Array[String] = []
	w.notice.connect(func(kind: String, _d: Dictionary) -> void: notices.append(kind))
	w.commands.push(GameCommands.gather([a.id, b.id], farm.id))
	w.step(2)
	assert_eq(farm.farmer_id, a.id)
	assert_eq(a.job, SimConst.JOB_GATHER)
	assert_ne(b.target_id, farm.id)
	assert_has(notices, "farm_busy")


func test_full_storage_discards_the_excess() -> void:
	var cap := SimFixture.econ().storage_cap("food", 1, 0)
	var w := SimFixture.empty_world({"food": cap - 4, "wood": 0, "stone": 0, "gold": 0})
	var k := w.keep().rect()
	var bush := w.add_node("berry_bush", Vector2i(k.end.x, k.position.y + 2))
	var u := w.add_unit("townsfolk", Pathing.center_of(Vector2i(k.end.x, k.position.y + 1)))
	var notices: Array[String] = []
	w.notice.connect(func(kind: String, _d: Dictionary) -> void: notices.append(kind))
	w.commands.push(GameCommands.gather([u.id], bush.id))
	w.step(SimFixture.ticks(w, 30.0))
	assert_eq(w.ledger.amount("food"), cap, "gathering never passes the cap")
	assert_has(notices, "storage_full")


func test_explicit_deposit_then_resume() -> void:
	var w := SimFixture.empty_world()
	var k := w.keep()
	var tree := w.add_node("tree", Vector2i(k.rect().end.x + 4, k.cell.y))
	var u := w.add_unit("townsfolk", Pathing.center_of(Vector2i(k.rect().end.x + 3, k.cell.y)))
	w.commands.push(GameCommands.gather([u.id], tree.id))
	w.step(SimFixture.ticks(w, 8.0))
	assert_true(u.is_carrying())
	var carried := u.carry_amount()
	var wood := w.ledger.amount("wood")
	w.commands.push(GameCommands.deposit([u.id], k.id))
	w.step(SimFixture.ticks(w, 8.0))
	assert_gte(w.ledger.amount("wood"), wood + carried)
	assert_eq(u.job, SimConst.JOB_GATHER, "went back to the tree")
	assert_eq(u.target_id, tree.id)
