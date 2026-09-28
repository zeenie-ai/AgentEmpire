extends GutTest
## Keep training queue: queue limit, pay when queued, full refunds, pause at the population cap,
## rally points.

var w: SimWorld
var keep: SimBuilding
var notices: Array[String] = []


func before_each() -> void:
	w = SimFixture.empty_world({"food": 1000, "wood": 1000, "stone": 0, "gold": 0})
	keep = w.keep()
	notices = []
	w.notice.connect(func(kind: String, _d: Dictionary) -> void: notices.append(kind))


func _cost() -> int:
	return int(w.econ.unit_cost("townsfolk")["food"])


func test_queue_holds_the_maximum_and_pays_when_queued() -> void:
	var qmax := w.econ.training_queue_max()
	for i in qmax + 1:
		w.commands.push(GameCommands.train(keep.id, "townsfolk"))
	w.step(1)
	assert_eq(keep.queue.size(), qmax)
	assert_eq(w.ledger.amount("food"), 1000 - _cost() * qmax, "paid for each queued item only")
	assert_has(notices, "queue_full")


func test_cannot_queue_without_food() -> void:
	var poor := SimFixture.empty_world({"food": _cost() - 1, "wood": 0, "stone": 0, "gold": 0})
	var got: Array[String] = []
	poor.notice.connect(func(kind: String, _d: Dictionary) -> void: got.append(kind))
	poor.commands.push(GameCommands.train(poor.keep_id, "townsfolk"))
	poor.step(1)
	assert_eq(poor.keep().queue.size(), 0)
	assert_eq(poor.ledger.amount("food"), _cost() - 1)
	assert_has(got, "not_enough")


func test_cancel_refunds_in_full() -> void:
	for i in 3:
		w.commands.push(GameCommands.train(keep.id, "townsfolk"))
	w.step(10)
	assert_eq(w.ledger.amount("food"), 1000 - 3 * _cost())
	w.commands.push(GameCommands.cancel_train(keep.id, 0))
	w.step(1)
	assert_eq(keep.queue.size(), 2)
	assert_eq(w.ledger.amount("food"), 1000 - 2 * _cost(), "the item in progress refunds in full")
	w.commands.push(GameCommands.cancel_train(keep.id, -1))
	w.commands.push(GameCommands.cancel_train(keep.id, -1))
	w.step(1)
	assert_eq(keep.queue.size(), 0)
	assert_eq(w.ledger.amount("food"), 1000)
	w.commands.push(GameCommands.cancel_train(keep.id, -1))
	w.step(1)
	assert_eq(w.ledger.amount("food"), 1000, "nothing left to refund")


func test_training_completes_and_spawns_outside() -> void:
	var before := w.units.size()
	w.commands.push(GameCommands.train(keep.id, "townsfolk"))
	w.step(1)
	assert_between(keep.head_progress(), 0.0, 0.05)
	w.step(w.econ.unit_train_ticks("townsfolk"))
	assert_eq(w.units.size(), before + 1)
	assert_eq(keep.queue.size(), 0)
	assert_has(notices, "trained")
	var u: SimUnit = w.units.values()[w.units.size() - 1]
	assert_true(w.grid.is_walkable(u.cell()))
	assert_lt(Pathing.rect_distance(u.pos, keep.rect()), 1.0, "appears next to the Keep")


func test_training_takes_train_s() -> void:
	w.commands.push(GameCommands.train(keep.id, "townsfolk"))
	var needed := w.econ.unit_train_ticks("townsfolk")
	assert_eq(needed, int(round(w.econ.unit_train_s("townsfolk") * w.tick_rate)))
	w.step(needed - 1)
	assert_eq(keep.queue.size(), 1, "not done one tick early")
	w.step(1)
	assert_eq(keep.queue.size(), 0, "done after exactly train_s")


func test_pauses_at_the_population_cap() -> void:
	var cap := w.pop_cap()
	for i in cap:
		w.add_unit("townsfolk", Vector2(40.5 + (i % 5), 40.5 + int(i / 5)))
	w.commands.push(GameCommands.stop(w.units.keys()))
	w.commands.push(GameCommands.train(keep.id, "townsfolk"))
	w.step(w.econ.unit_train_ticks("townsfolk") * 2)
	assert_eq(keep.queue.size(), 1)
	assert_eq(int(keep.queue[0]["ticks"]), 0, "no progress while capped")
	assert_true(keep.training_blocked)
	assert_eq(notices.count("need_houses"), 1, "one notice, not one per tick")
	# A cottage makes room.
	w.add_building("cottage", Vector2i(70, 64), true, "")
	w.step(w.econ.unit_train_ticks("townsfolk") + 1)
	assert_eq(keep.queue.size(), 0)
	assert_false(keep.training_blocked)
	assert_eq(w.pop_used(), cap + 1)


func test_rally_point_on_a_resource_starts_gathering() -> void:
	var tree := w.add_node("tree", Vector2i(keep.rect().end.x + 5, keep.cell.y))
	w.commands.push(GameCommands.set_rally(keep.id, tree.cell, tree.id))
	w.commands.push(GameCommands.train(keep.id, "townsfolk"))
	w.step(w.econ.unit_train_ticks("townsfolk") + 2)
	var u: SimUnit = w.units.values()[w.units.size() - 1]
	assert_eq(u.job, SimConst.JOB_GATHER)
	assert_eq(u.target_id, tree.id)


func test_rally_point_on_ground_walks_there() -> void:
	var spot := Vector2i(keep.cell.x - 8, keep.cell.y + 9)
	w.commands.push(GameCommands.set_rally(keep.id, spot, 0))
	w.commands.push(GameCommands.train(keep.id, "townsfolk"))
	w.step(w.econ.unit_train_ticks("townsfolk") + 1)
	var u: SimUnit = w.units.values()[w.units.size() - 1]
	assert_eq(u.job, SimConst.JOB_MOVE)
	w.step(SimFixture.ticks(w, 15.0))
	assert_lt(u.pos.distance_to(Pathing.center_of(spot)), 1.5)


func test_new_units_spawn_toward_the_rally_point() -> void:
	var spot := Vector2i(keep.cell.x - 10, keep.cell.y)
	w.commands.push(GameCommands.set_rally(keep.id, spot, 0))
	w.commands.push(GameCommands.train(keep.id, "townsfolk"))
	w.step(w.econ.unit_train_ticks("townsfolk") + 1)
	var u: SimUnit = w.units.values()[w.units.size() - 1]
	assert_lt(u.pos.x, float(keep.cell.x), "left side of the Keep, facing the rally point")
