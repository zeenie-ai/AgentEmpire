extends GutTest
## GameCommands: queued, applied on the next tick, logged, and JSON-safe.


func test_commands_apply_on_the_next_tick() -> void:
	var w := SimFixture.empty_world()
	var u := w.add_unit("townsfolk", Vector2(60.5, 70.5))
	w.commands.push(GameCommands.move([u.id], Vector2i(50, 70)))
	assert_eq(u.job, SimConst.JOB_IDLE, "nothing happens until the world steps")
	assert_eq(w.commands.pending_count(), 1)
	w.step(1)
	assert_eq(u.job, SimConst.JOB_MOVE)
	assert_eq(w.commands.pending_count(), 0)
	assert_eq(w.commands.history.size(), 1)
	assert_eq(int(w.commands.history[0]["tick"]), 0)


func test_commands_survive_a_json_round_trip() -> void:
	var w := SimFixture.empty_world(SimFixture.big_purse())
	var u := w.add_unit("townsfolk", Vector2(60.5, 70.5))
	var cmds: Array[Dictionary] = [
		GameCommands.place_building([u.id], "cottage", Vector2i(70, 64)),
		GameCommands.train(w.keep_id, "townsfolk"),
		GameCommands.set_rally(w.keep_id, Vector2i(60, 60), 0),
		GameCommands.set_gather_focus(w.keep_id, "wood"),
	]
	for c in cmds:
		var wire: Dictionary = JSON.parse_string(JSON.stringify(c))
		w.commands.push(wire)
	w.step(1)
	var site := w.building_at(Vector2i(70, 64))
	assert_not_null(site, "numbers arriving as floats still work")
	assert_eq(u.job, SimConst.JOB_BUILD)
	assert_eq(w.keep().queue.size(), 1)
	assert_eq(w.keep().rally, {"x": 60, "y": 60, "target": 0})
	assert_eq(w.keep().gather_focus, "wood")


func test_constructors_are_plain_dictionaries() -> void:
	var all: Array[Dictionary] = [
		GameCommands.move([1, 2], Vector2i(3, 4)),
		GameCommands.gather([1], 5),
		GameCommands.build([1], 5),
		GameCommands.deposit([1], 5),
		GameCommands.stop([1]),
		GameCommands.place_building([1], "farm", Vector2i(3, 4)),
		GameCommands.cancel_site(5),
		GameCommands.dismantle(5),
		GameCommands.train(5, "townsfolk"),
		GameCommands.cancel_train(5, -1),
		GameCommands.set_rally(5, Vector2i(1, 1), 0),
		GameCommands.clear_rally(5),
		GameCommands.set_gather_focus(5, "auto"),
	]
	for c in all:
		var back: Variant = JSON.parse_string(JSON.stringify(c))
		assert_eq(typeof(back), TYPE_DICTIONARY)
		assert_eq(String(back["type"]), String(c["type"]))
		assert_eq((back as Dictionary).size(), c.size())


func test_unknown_and_invalid_commands_are_ignored() -> void:
	var w := SimFixture.empty_world()
	var notices: Array[String] = []
	w.notice.connect(func(kind: String, _d: Dictionary) -> void: notices.append(kind))
	w.commands.push({"type": "summon_dragon"})
	w.commands.push(GameCommands.move([999], Vector2i(1, 1)))
	w.commands.push({"no_type": true})
	w.step(1)
	assert_has(notices, "unknown_command")
	assert_eq(w.commands.history.size(), 2, "commands without a type are never queued")


func test_debug_spawn_needs_the_flag() -> void:
	var w := SimFixture.empty_world()
	var n := w.units.size()
	w.commands.push(GameCommands.debug_spawn(5, Vector2i(50, 50)))
	w.step(1)
	assert_eq(w.units.size(), n)
	w.allow_debug_commands = true
	w.commands.push(GameCommands.debug_spawn(5, Vector2i(50, 50)))
	w.step(1)
	assert_eq(w.units.size(), n + 5)


func test_rally_can_be_cleared() -> void:
	var w := SimFixture.empty_world()
	w.commands.push(GameCommands.set_rally(w.keep_id, Vector2i(50, 50), 0))
	w.step(1)
	assert_false(w.keep().rally.is_empty())
	w.commands.push(GameCommands.clear_rally(w.keep_id))
	w.step(1)
	assert_true(w.keep().rally.is_empty())
