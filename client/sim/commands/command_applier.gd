class_name CommandApplier
extends RefCounted
## Applies one GameCommands command to a SimWorld. Invalid commands are dropped, with a notice
## when the player should hear about it (not enough resources, blocked placement, ...).


static func apply(w: SimWorld, cmd: Dictionary) -> void:
	match String(cmd.get("type", "")):
		GameCommands.MOVE:
			_move(w, cmd)
		GameCommands.GATHER:
			_gather(w, cmd)
		GameCommands.BUILD:
			_build(w, cmd)
		GameCommands.DEPOSIT:
			_deposit(w, cmd)
		GameCommands.STOP:
			_stop(w, cmd)
		GameCommands.AUTO_GATHER:
			_auto_gather(w, cmd)
		GameCommands.PLACE_BUILDING:
			_place(w, cmd)
		GameCommands.CANCEL_SITE:
			_cancel_site(w, cmd)
		GameCommands.DISMANTLE:
			_dismantle(w, cmd)
		GameCommands.TRAIN:
			_train(w, cmd)
		GameCommands.CANCEL_TRAIN:
			_cancel_train(w, cmd)
		GameCommands.SET_RALLY:
			_set_rally(w, cmd)
		GameCommands.SET_GATHER_FOCUS:
			_set_focus(w, cmd)
		GameCommands.DEBUG_SPAWN:
			_debug_spawn(w, cmd)
		_:
			w.emit_notice("unknown_command", {"type": String(cmd.get("type", ""))})


## Player-controllable units named by the command (townsfolk; agents follow the Town Hall).
static func _units(w: SimWorld, cmd: Dictionary) -> Array[SimUnit]:
	var out: Array[SimUnit] = []
	var seen := {}
	for v: Variant in cmd.get("units", []):
		var id := int(v)
		if seen.has(id):
			continue
		seen[id] = true
		var u: SimUnit = w.units.get(id)
		if u != null and u.kind == "townsfolk":
			out.append(u)
	return out


static func _cell(w: SimWorld, cmd: Dictionary) -> Vector2i:
	var c := Vector2i(int(cmd.get("x", 0)), int(cmd.get("y", 0)))
	return c.clamp(Vector2i.ZERO, Vector2i(w.grid.size - 1, w.grid.size - 1))


static func _building(w: SimWorld, cmd: Dictionary) -> SimBuilding:
	return w.buildings.get(int(cmd.get("building", 0)))


static func _move(w: SimWorld, cmd: Dictionary) -> void:
	var us := _units(w, cmd)
	if us.is_empty():
		return
	var target := _cell(w, cmd)
	if us.size() == 1:
		JobUtil.forget(us[0])
		MoveJob.start(w, us[0], target, true)
		return
	# Spread the group over distinct cells around the target; the cells nearest the target go
	# to the closest units.
	var cells := Pathing.formation_cells(w.grid, target, us.size())
	var remaining: Array[SimUnit] = []
	remaining.assign(us)
	for c in cells:
		if remaining.is_empty():
			break
		var best_i := 0
		var best_d := INF
		var cc := Pathing.center_of(c)
		for i in remaining.size():
			var d := remaining[i].pos.distance_squared_to(cc)
			if d < best_d:
				best_d = d
				best_i = i
		var u: SimUnit = remaining[best_i]
		remaining.remove_at(best_i)
		JobUtil.forget(u)
		MoveJob.start(w, u, c, true)
	for u in remaining:
		JobUtil.forget(u)
		MoveJob.start(w, u, target, true)


static func _gather(w: SimWorld, cmd: Dictionary) -> void:
	var target := int(cmd.get("target", 0))
	for u in _units(w, cmd):
		JobUtil.forget(u)
		GatherJob.start(w, u, target)


static func _build(w: SimWorld, cmd: Dictionary) -> void:
	var b := _building(w, cmd)
	if b == null or b.complete:
		return
	for u in _units(w, cmd):
		JobUtil.forget(u)
		BuildJob.start(w, u, b.id)


static func _deposit(w: SimWorld, cmd: Dictionary) -> void:
	var b := _building(w, cmd)
	if b == null:
		return
	for u in _units(w, cmd):
		JobUtil.forget(u)
		if not DepositJob.start(w, u, b.id):
			var cells := Pathing.free_edge_cells(w.grid, b.rect())
			MoveJob.start(w, u, cells[0] if not cells.is_empty() else Vector2i(b.center()), true)


static func _stop(w: SimWorld, cmd: Dictionary) -> void:
	for u in _units(w, cmd):
		JobUtil.forget(u)
		JobUtil.go_idle(w, u, true)


static func _auto_gather(w: SimWorld, cmd: Dictionary) -> void:
	for u in _units(w, cmd):
		JobUtil.forget(u)
		if not GatherJob.auto_assign(w, u):
			JobUtil.go_idle(w, u, false)
			w.emit_notice("no_work", {"unit": u.id})


static func _place(w: SimWorld, cmd: Dictionary) -> void:
	var type := String(cmd.get("building", ""))
	if not type in w.econ.buildable_by("townsfolk"):
		w.emit_notice("placement_invalid", {"code": "unknown", "reason": "Townsfolk can't build that"})
		return
	var cell := Vector2i(int(cmd.get("x", 0)), int(cmd.get("y", 0)))
	var check := Placement.check(w, type, cell, true)
	if not bool(check.get("ok", false)):
		w.emit_notice("placement_invalid", check)
		return
	var cost := w.econ.building_cost(type)
	var op := w.next_op_id("build")
	if not w.ledger.spend(op, "build:%s" % type, cost, ""):
		w.emit_notice("not_enough", {"cost": cost, "missing": w.ledger.missing(cost)})
		return
	var b := w.add_building(type, cell, false, op)
	w.emit_notice("site_placed", {"building": b.id, "type": type})
	for u in _units(w, cmd):
		JobUtil.forget(u)
		BuildJob.start(w, u, b.id)


static func _cancel_site(w: SimWorld, cmd: Dictionary) -> void:
	var b := _building(w, cmd)
	if b == null or b.complete:
		return
	var refund := w.ledger.refund(w.next_op_id("refund"), b.spend_op, w.econ.refund_fraction("cancel"))
	var type := b.type
	w.remove_building(b.id)
	w.emit_notice("site_cancelled", {"type": type, "refund": refund})


static func _dismantle(w: SimWorld, cmd: Dictionary) -> void:
	var b := _building(w, cmd)
	if b == null or not b.complete or b.id == w.keep_id:
		return
	if w.econ.building_built_by(b.type) != "townsfolk":
		return
	var refund := w.ledger.refund(w.next_op_id("refund"), b.spend_op, w.econ.refund_fraction("dismantle"))
	var type := b.type
	w.remove_building(b.id)
	w.emit_notice("dismantled", {"type": type, "refund": refund})


static func _train(w: SimWorld, cmd: Dictionary) -> void:
	var b := _building(w, cmd)
	var unit := String(cmd.get("unit", "townsfolk"))
	if b == null or not b.complete or not unit in SimWorld.TRAINERS.get(b.type, []):
		return
	var def := w.econ.unit_def(unit)
	if def.is_empty():
		return
	if int(def.get("age", 1)) > w.age:
		w.emit_notice("age_required", {"unit": unit, "age": int(def.get("age", 1))})
		return
	if b.queue.size() >= w.econ.training_queue_max():
		w.emit_notice("queue_full", {"building": b.id, "max": w.econ.training_queue_max()})
		return
	var cost := w.econ.unit_cost(unit)
	var op := w.next_op_id("train")
	if not w.ledger.spend(op, "train:%s" % unit, cost, str(b.id)):
		w.emit_notice("not_enough", {"cost": cost, "missing": w.ledger.missing(cost)})
		return
	b.queue.append({"unit": unit, "op": op, "ticks": 0, "needed": w.econ.unit_train_ticks(unit)})
	w.entity_changed.emit(b.id, SimWorld.CAT_BUILDING)


static func _cancel_train(w: SimWorld, cmd: Dictionary) -> void:
	var b := _building(w, cmd)
	if b == null or b.queue.is_empty():
		return
	var idx := int(cmd.get("index", -1))
	if idx < 0:
		idx = b.queue.size() - 1
	if idx >= b.queue.size():
		return
	var item: Dictionary = b.queue[idx]
	b.queue.remove_at(idx)
	var refund := w.ledger.refund(w.next_op_id("refund"), String(item.get("op", "")), w.econ.refund_fraction("cancel"))
	if b.queue.is_empty():
		b.training_blocked = false
	w.entity_changed.emit(b.id, SimWorld.CAT_BUILDING)
	w.emit_notice("train_cancelled", {"building": b.id, "refund": refund})


static func _set_rally(w: SimWorld, cmd: Dictionary) -> void:
	var b := _building(w, cmd)
	if b == null or not SimWorld.TRAINERS.has(b.type):
		return
	if bool(cmd.get("clear", false)):
		b.rally = {}
	else:
		var c := _cell(w, cmd)
		b.rally = {"x": c.x, "y": c.y, "target": int(cmd.get("target", 0))}
	w.entity_changed.emit(b.id, SimWorld.CAT_BUILDING)


static func _set_focus(w: SimWorld, cmd: Dictionary) -> void:
	var b := _building(w, cmd)
	var focus := String(cmd.get("focus", "auto"))
	if b == null or b.id != w.keep_id:
		return
	if focus != "auto" and not focus in w.econ.gatherable_resources():
		return
	b.gather_focus = focus
	w.entity_changed.emit(b.id, SimWorld.CAT_BUILDING)


static func _debug_spawn(w: SimWorld, cmd: Dictionary) -> void:
	if not w.allow_debug_commands:
		return
	var count := clampi(int(cmd.get("count", 0)), 0, 500)
	var hold := bool(cmd.get("hold", false))
	for c in Pathing.formation_cells(w.grid, _cell(w, cmd), count):
		var u := w.add_unit(String(cmd.get("kind", "townsfolk")), Pathing.center_of(c))
		u.hold = hold
