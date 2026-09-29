extends GutTest
## Agents in the simulation: training at the Keep, plots, homes and add-ons built by their
## agent, home life, task couriers and Font Wisps (the commands TownLink issues).

var _notices: Array[Dictionary] = []


func _world() -> SimWorld:
	var w := SimFixture.empty_world(SimFixture.big_purse())
	_notices.clear()
	w.notice.connect(func(kind: String, data: Dictionary) -> void: _notices.append({"kind": kind, "data": data}))
	return w


func _notice(kind: String) -> Dictionary:
	for n in _notices:
		if String(n["kind"]) == kind:
			return n["data"]
	return {}


func _has(kind: String) -> bool:
	return not _notice(kind).is_empty()


## Steps until a notice of `kind` appears (or `seconds` pass). Returns its data.
func _step_until(w: SimWorld, kind: String, seconds: float) -> Dictionary:
	for i in SimFixture.ticks(w, seconds):
		w.step(1)
		if _has(kind):
			return _notice(kind)
	return {}


## A valid home cell for `type` near the Keep.
func _plot_spot(w: SimWorld, type: String = "workshop") -> Vector2i:
	var c := Vector2i(w.map_center())
	for r in range(5, 16):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var cell := c + Vector2i(dx, dy)
				if bool(Placement.check_plot(w, type, cell)["ok"]):
					return cell
	return Pathing.NO_CELL


func _exit(w: SimWorld) -> Vector2i:
	return w.exit_cells(w.keep(), w.keep().center() + Vector2(0, 4))[0]


## An agent standing by the Keep with a finished home.
func _settled(w: SimWorld, agent_id: String = "agt_1") -> SimBuilding:
	w.commands.push(GameCommands.spawn_agent(agent_id, "artificer", _exit(w)))
	var cell := _plot_spot(w)
	assert_ne(cell, Pathing.NO_CELL, "found a plot")
	w.commands.push(GameCommands.place_home(agent_id, "workshop", cell, true))
	w.step(1)
	return w.agent_home(agent_id)


func test_agent_trains_at_the_keep_and_counts_two_population() -> void:
	var w := _world()
	w.commands.push(GameCommands.queue_agent(w.keep_id, "agt_1", "artificer", 40))
	w.step(1)
	assert_eq(w.keep().queue.size(), 1)
	assert_eq(String(w.keep().queue[0]["agent_id"]), "agt_1")
	var data := _step_until(w, "agent_trained", 5.0)
	assert_eq(String(data.get("agent_id", "")), "agt_1")
	var u := w.agent_unit("agt_1")
	assert_not_null(u)
	assert_eq(u.kind, "agent")
	assert_eq(u.role, "artificer")
	assert_eq(w.pop_used(), 2, "an agent takes two population")
	assert_true(w.keep().queue.is_empty())


func test_queueing_the_same_agent_twice_is_ignored() -> void:
	var w := _world()
	w.commands.push(GameCommands.queue_agent(w.keep_id, "agt_1", "scribe", 40))
	w.commands.push(GameCommands.queue_agent(w.keep_id, "agt_1", "scribe", 40))
	w.step(1)
	assert_eq(w.keep().queue.size(), 1)


func test_cancelling_an_agent_in_training_asks_the_town_hall() -> void:
	var w := _world()
	w.commands.push(GameCommands.queue_agent(w.keep_id, "agt_1", "scholar", 40))
	w.commands.push(GameCommands.cancel_train(w.keep_id, -1))
	w.step(1)
	assert_eq(String(_notice("cancel_agent").get("agent_id", "")), "agt_1")
	assert_eq(w.keep().queue.size(), 1, "stays queued until the Town Hall refunds it")


func test_agent_walks_to_its_plot_and_builds_its_home() -> void:
	var w := _world()
	w.commands.push(GameCommands.spawn_agent("agt_1", "artificer", _exit(w)))
	var cell := _plot_spot(w)
	w.commands.push(GameCommands.place_home("agt_1", "workshop", cell))
	w.step(1)
	var home := w.agent_home("agt_1")
	assert_not_null(home)
	assert_false(home.complete)
	assert_eq(home.plot, HomeLayout.plot_rect(cell))
	var data := _step_until(w, "home_complete", 150.0)
	assert_eq(String(data.get("agent_id", "")), "agt_1")
	assert_true(home.complete)


func test_townsfolk_never_build_an_agents_site() -> void:
	var w := _world()
	w.commands.push(GameCommands.place_home("agt_1", "workshop", _plot_spot(w)))
	w.step(1)
	var home := w.agent_home("agt_1")
	var t := w.add_unit("townsfolk", Pathing.center_of(_exit(w)))
	assert_false(BuildJob.start(w, t, home.id), "townsfolk can't build a home")
	assert_null(w.find_site_near(home.center(), 30.0), "and don't look for agent sites")


func test_a_plot_reserves_its_ground() -> void:
	var w := _world()
	var home := _settled(w)
	var ring_cell := home.plot.position
	var check := Placement.check(w, "cottage", ring_cell)
	assert_false(bool(check["ok"]))
	assert_eq(String(check["code"]), "plot")
	var overlap := Placement.check_plot(w, "scriptorium", home.cell + Vector2i(3, 0))
	assert_false(bool(overlap["ok"]))
	assert_eq(String(overlap["code"]), "plot")


func test_plots_keep_clear_of_the_keep() -> void:
	var w := _world()
	var k := w.keep().rect()
	var check := Placement.check_plot(w, "workshop", k.position + Vector2i(k.size.x + 1, 0))
	assert_false(bool(check["ok"]))
	assert_eq(String(check["code"]), "keep")


func test_agent_builds_its_add_ons_after_the_home() -> void:
	var w := _world()
	var home := _settled(w)
	var fc := HomeLayout.tool_cell(home.plot, w.econ.building_footprint("forge"), [])
	w.commands.push(GameCommands.place_tool("agt_1", "tl_1", "forge", fc))
	var data := _step_until(w, "tool_complete", 90.0)
	assert_eq(String(data.get("tool_id", "")), "tl_1")
	assert_true(w.tool_building("tl_1").complete)


func test_working_agent_stands_at_the_add_on_it_uses() -> void:
	var w := _world()
	var home := _settled(w)
	var fc := HomeLayout.tool_cell(home.plot, w.econ.building_footprint("forge"), [])
	w.commands.push(GameCommands.place_tool("agt_1", "tl_1", "forge", fc, true))
	w.commands.push(GameCommands.set_agent_state("agt_1", "working", "forge"))
	w.step(SimFixture.ticks(w, 25.0))
	var u := w.agent_unit("agt_1")
	assert_true(AgentJob.at_spot(u), "arrived")
	assert_lte(Pathing.rect_distance(u.pos, w.tool_building("tl_1").rect()), 1.0, "next to the forge")
	w.commands.push(GameCommands.set_agent_state("agt_1", "awaiting_approval", ""))
	w.step(SimFixture.ticks(w, 15.0))
	assert_eq(u.cell(), HomeLayout.door_cell(home.rect()), "waits at the door for the approval")


func test_courier_fetches_the_scroll_at_the_keep_then_delivers_it() -> void:
	var w := _world()
	var home := _settled(w)
	var far := Vector2i(w.map_center()) + Vector2i(0, -9)
	var t := w.add_unit("townsfolk", Pathing.center_of(far))
	w.commands.push(GameCommands.courier(t.id, home.id, "tsk_1", "agt_1"))
	w.step(1)
	assert_eq(t.job, SimConst.JOB_COURIER)
	assert_eq(t.phase, CourierJob.TO_KEEP, "fetches the scroll first")
	var carried := false
	for i in SimFixture.ticks(w, 90.0):
		w.step(1)
		carried = carried or CourierJob.carrying_scroll(t)
		if _has("courier_arrived"):
			break
	assert_true(carried, "carried the scroll")
	var data := _notice("courier_arrived")
	assert_eq(String((data.get("payload", {}) as Dictionary).get("task_id", "")), "tsk_1")
	assert_eq(int(data.get("building", 0)), home.id)
	assert_ne(t.job, SimConst.JOB_COURIER, "went back to work")


func test_a_courier_given_another_order_drops_the_scroll() -> void:
	var w := _world()
	var home := _settled(w)
	var t := w.add_unit("townsfolk", Pathing.center_of(_exit(w)))
	w.commands.push(GameCommands.courier(t.id, home.id, "tsk_1", "agt_1"))
	w.step(3)
	w.commands.push(GameCommands.move([t.id], _exit(w) + Vector2i(0, 3)))
	w.step(1)
	var data := _notice("courier_dropped")
	assert_eq(String((data.get("payload", {}) as Dictionary).get("task_id", "")), "tsk_1")


func test_a_wisp_waits_then_flies_the_scroll_to_the_home() -> void:
	var w := _world()
	var home := _settled(w)
	w.commands.push(GameCommands.wisp(home.id, "tsk_2", "agt_1", 40))
	w.step(30)
	assert_eq(w.wisps.size(), 1)
	assert_false(_has("wisp_arrived"), "still waiting at the Keep")
	var data := _step_until(w, "wisp_arrived", 20.0)
	assert_eq(String(data.get("task_id", "")), "tsk_2")
	assert_true(w.wisps.is_empty())


func test_cancel_courier_stops_couriers_and_wisps() -> void:
	var w := _world()
	var home := _settled(w)
	var t := w.add_unit("townsfolk", Pathing.center_of(_exit(w)))
	w.commands.push(GameCommands.courier(t.id, home.id, "tsk_1", "agt_1"))
	w.commands.push(GameCommands.wisp(home.id, "tsk_1", "agt_1", 100))
	w.step(2)
	w.commands.push(GameCommands.cancel_courier("tsk_1"))
	w.step(1)
	assert_ne(t.job, SimConst.JOB_COURIER)
	assert_true(w.wisps.is_empty())
	assert_false(_has("courier_dropped"), "a cancelled delivery is not a dropped scroll")


func test_drop_agent_removes_the_agent_and_all_it_built() -> void:
	var w := _world()
	var home := _settled(w)
	var fc := HomeLayout.tool_cell(home.plot, Vector2i.ONE, [])
	w.commands.push(GameCommands.place_tool("agt_1", "tl_1", "lectern", fc, true))
	w.step(1)
	w.commands.push(GameCommands.drop_agent("agt_1"))
	w.step(1)
	assert_null(w.agent_unit("agt_1"))
	assert_null(w.agent_home("agt_1"))
	assert_null(w.tool_building("tl_1"))
	assert_true(w.plots().is_empty())


func test_revoke_spend_undoes_a_refused_site() -> void:
	var w := _world()
	var t := w.add_unit("townsfolk", Pathing.center_of(_exit(w)))
	var spot := Vector2i(w.map_center()) + Vector2i(6, 6)
	w.commands.push(GameCommands.place_building([t.id], "cottage", spot))
	w.step(1)
	var site: SimBuilding = w.building_at(spot)
	assert_not_null(site)
	w.commands.push(GameCommands.revoke_spend(site.spend_op))
	w.step(1)
	assert_null(w.building_at(spot))
	assert_eq(String(_notice("spend_revoked").get("type", "")), "cottage")


func test_agents_and_wisps_survive_a_save() -> void:
	var w := _world()
	var home := _settled(w)
	w.commands.push(GameCommands.place_tool("agt_1", "tl_1", "lectern", HomeLayout.tool_cell(home.plot, Vector2i.ONE, [])))
	w.commands.push(GameCommands.queue_agent(w.keep_id, "agt_2", "scribe", 600))
	w.commands.push(GameCommands.wisp(home.id, "tsk_9", "agt_1", 500))
	w.commands.push(GameCommands.set_agent_state("agt_1", "working", "lectern"))
	w.step(5)
	var json := JSON.stringify(w.to_dict(), "", true, true)
	var w2 := SimWorld.from_dict(JSON.parse_string(json), w.econ, SimFixture.ledger(w.econ))
	assert_eq(JSON.stringify(w2.to_dict(), "", true, true), json, "exact round trip")
	assert_eq(w2.agent_home("agt_1").plot, home.plot)
	assert_eq(w2.tool_building("tl_1").owner_agent_id, "agt_1")
	assert_eq(w2.wisps.size(), 1)
	assert_eq(w2.agent_unit("agt_1").work_tool, "lectern")
	assert_eq(String(w2.queued_agent("agt_2").get("role", "")), "scribe")


func test_tool_cells_fill_corners_first_and_keep_the_entrance_free() -> void:
	var plot := Rect2i(10, 10, 7, 7)
	var taken: Array[Rect2i] = []
	var first := HomeLayout.tool_cell(plot, Vector2i.ONE, taken)
	assert_eq(first, Vector2i(10, 10), "top-left corner first")
	taken.append(Rect2i(first, Vector2i.ONE))
	assert_eq(HomeLayout.tool_cell(plot, Vector2i(2, 2), taken), Vector2i(15, 10), "next corner fits a Waygate")
	var entrance := HomeLayout.entrance_cells(plot)
	var cells: Array[Rect2i] = []
	while true:
		var c := HomeLayout.tool_cell(plot, Vector2i.ONE, cells)
		if c == Pathing.NO_CELL:
			break
		cells.append(Rect2i(c, Vector2i.ONE))
		assert_false(c in entrance, "never on the entrance")
		assert_true(HomeLayout.in_ring(plot, Rect2i(c, Vector2i.ONE)))
	assert_gt(cells.size(), 8, "room for every add-on an age allows")
