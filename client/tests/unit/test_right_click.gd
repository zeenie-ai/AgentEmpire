extends GutTest
## The right-click rules table, the context builder and the resulting commands.


func _r(selection: String, target: String, carrying: bool = false) -> String:
	return RightClickRules.resolve({"selection": selection, "target": target, "carrying": carrying})


func test_table_for_townsfolk() -> void:
	assert_eq(_r("units", "ground"), "move")
	assert_eq(_r("units", "tree"), "gather")
	assert_eq(_r("units", "berry_bush"), "gather")
	assert_eq(_r("units", "farm"), "gather")
	assert_eq(_r("units", "site"), "build")
	assert_eq(_r("units", "dropoff", true), "deposit")
	assert_eq(_r("units", "dropoff", false), "move", "not carrying: just walk there")
	assert_eq(_r("units", "building"), "move")
	assert_eq(_r("units", "unit"), "move")


func test_table_for_the_keep() -> void:
	for target in ["ground", "tree", "berry_bush", "farm", "site", "dropoff", "building", "unit"]:
		assert_eq(_r("rally_building", target), "rally", target)


func test_table_for_other_selections() -> void:
	assert_eq(_r("building", "ground"), "none")
	assert_eq(_r("none", "tree"), "none")
	assert_eq(RightClickRules.resolve({}), "none")


func test_context_from_the_world() -> void:
	var w := SimFixture.empty_world(SimFixture.big_purse())
	var u := w.add_unit("townsfolk", Vector2(70.5, 70.5))
	var tree := w.add_node("tree", Vector2i(72, 70))
	var bush := w.add_node("berry_bush", Vector2i(72, 72))
	var farm := w.add_building("farm", Vector2i(74, 60), true, "")
	var farm_site := w.add_building("farm", Vector2i(74, 56), false, "")
	var house := w.add_building("cottage", Vector2i(58, 70), true, "")
	var keep := w.keep()
	var sel := [u.id]
	var ctx := func(target: Dictionary) -> Dictionary: return RightClickRules.context_for(w, sel, target)
	assert_eq(ctx.call({"kind": "ground", "cell": Vector2i(60, 60)})["target"], "ground")
	assert_eq(ctx.call({"kind": "node", "id": tree.id})["target"], "tree")
	assert_eq(ctx.call({"kind": "node", "id": bush.id})["target"], "berry_bush")
	assert_eq(ctx.call({"kind": "building", "id": farm.id})["target"], "farm")
	assert_eq(ctx.call({"kind": "building", "id": farm_site.id})["target"], "site", "an unfinished farm is a site")
	assert_eq(ctx.call({"kind": "building", "id": house.id})["target"], "building")
	assert_eq(ctx.call({"kind": "building", "id": keep.id})["target"], "dropoff")
	assert_eq(ctx.call({"kind": "building", "id": keep.id})["selection"], "units")
	assert_false(ctx.call({"kind": "building", "id": keep.id})["carrying"])
	u.carry_res = "wood"
	u.carry_m = 4000
	assert_true(ctx.call({"kind": "building", "id": keep.id})["carrying"])
	w.deplete_node(tree)
	assert_eq(ctx.call({"kind": "node", "id": tree.id})["target"], "ground", "a stump is just ground")
	assert_eq(RightClickRules.context_for(w, [keep.id], {"kind": "ground"})["selection"], "rally_building")
	assert_eq(RightClickRules.context_for(w, [house.id], {"kind": "ground"})["selection"], "building")


func test_commands_for_actions() -> void:
	var w := SimFixture.empty_world()
	var u := w.add_unit("townsfolk", Vector2(70.5, 70.5))
	var tree := w.add_node("tree", Vector2i(72, 70))
	var target := {"kind": "node", "id": tree.id, "cell": tree.cell}
	assert_eq(RightClickRules.command_for(w, [u.id], target, "gather"), GameCommands.gather([u.id], tree.id))
	assert_eq(RightClickRules.command_for(w, [u.id], {"kind": "ground", "cell": Vector2i(3, 4)}, "move"),
		GameCommands.move([u.id], Vector2i(3, 4)))
	assert_eq(RightClickRules.command_for(w, [w.keep_id], target, "rally"),
		GameCommands.set_rally(w.keep_id, tree.cell, tree.id), "rally on a resource remembers it")
	assert_eq(RightClickRules.command_for(w, [w.keep_id], {"kind": "ground", "cell": Vector2i(9, 9)}, "rally"),
		GameCommands.set_rally(w.keep_id, Vector2i(9, 9), 0))
	assert_eq(RightClickRules.command_for(w, [u.id], target, "none"), {})


func test_right_click_end_to_end() -> void:
	var w := SimFixture.empty_world()
	var u := w.add_unit("townsfolk", Vector2(70.5, 64.5))
	var bush := w.add_node("berry_bush", Vector2i(72, 64))
	var target := {"kind": "node", "id": bush.id, "cell": bush.cell}
	var action := RightClickRules.resolve(RightClickRules.context_for(w, [u.id], target))
	w.commands.push(RightClickRules.command_for(w, [u.id], target, action))
	w.step(SimFixture.ticks(w, 3.0))
	assert_eq(u.job, SimConst.JOB_GATHER)
	assert_eq(u.target_id, bush.id)
