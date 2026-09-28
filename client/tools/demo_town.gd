class_name DemoTown
extends RefCounted
## A busy demo town for screenshots and stress tests. Built only through GameCommands (the
## debug_spawn command needs SimWorld.allow_debug_commands).


## Adds townsfolk, places a few buildings and training, then runs the simulation for `seconds`.
static func build(w: SimWorld, extra_townsfolk: int = 12, seconds: float = 70.0) -> Dictionary:
	w.allow_debug_commands = true
	var k := w.keep()
	w.commands.push(GameCommands.debug_spawn(extra_townsfolk, k.cell + Vector2i(1, 7)))
	w.step(1)
	var ids: Array = w.units.keys()
	var c := Vector2i(k.center())
	var placed := {}
	var plan := [
		["cottage", c + Vector2i(5, 4), 3],
		["cottage", c + Vector2i(-7, 4), 2],
		["farm", c + Vector2i(6, -5), 2],
		["storehouse", c + Vector2i(-6, -6), 2],
		["cottage", c + Vector2i(1, 8), 1],
	]
	var used := 0
	for p: Array in plan:
		var type: String = p[0]
		var spot := find_spot(w, type, p[1], 6)
		if spot == Pathing.NO_CELL:
			continue
		var builders: Array = ids.slice(used, used + int(p[2]))
		used += int(p[2])
		w.commands.push(GameCommands.place_building(builders, type, spot))
		w.step(1)
		placed[type + str(placed.size())] = spot
	# The rest gather on their own; queue some training with a rally point at the nearest grove.
	var tree := w.find_nearest_node(k.center(), ["tree"], 30.0)
	if tree != null:
		w.commands.push(GameCommands.set_rally(k.id, tree.cell, tree.id))
	for i in 3:
		w.commands.push(GameCommands.train(k.id, "townsfolk"))
	w.step(int(seconds * w.tick_rate))
	return placed


## First valid spot for `type` searching outward from `near` up to `radius` rings.
static func find_spot(w: SimWorld, type: String, near: Vector2i, radius: int) -> Vector2i:
	for r in range(0, radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var cell := near + Vector2i(dx, dy)
				if Placement.check(w, type, cell)["ok"]:
					return cell
	return Pathing.NO_CELL


## Absolute path of the repository's out/ folder (next to client/).
static func out_dir(args: PackedStringArray) -> String:
	for a in args:
		if a.begins_with("--out="):
			return a.substr(6)
	return ProjectSettings.globalize_path("res://").path_join("../out").simplify_path()
