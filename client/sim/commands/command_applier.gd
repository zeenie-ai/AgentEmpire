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
		GameCommands.QUEUE_AGENT:
			_queue_agent(w, cmd)
		GameCommands.SPAWN_AGENT:
			_spawn_agent(w, cmd)
		GameCommands.DROP_AGENT:
			_drop_agent(w, cmd)
		GameCommands.PLACE_HOME:
			_place_home(w, cmd)
		GameCommands.PLACE_TOOL:
			_place_tool(w, cmd)
		GameCommands.REMOVE_TOOL:
			_remove_tool(w, cmd)
		GameCommands.COMPLETE_BUILDING:
			_complete_building(w, cmd)
		GameCommands.SET_AGENT_STATE:
			_set_agent_state(w, cmd)
		GameCommands.COURIER:
			_courier(w, cmd)
		GameCommands.WISP:
			_wisp(w, cmd)
		GameCommands.CANCEL_COURIER:
			_cancel_courier(w, cmd)
		GameCommands.REVOKE_SPEND:
			_revoke_spend(w, cmd)
		GameCommands.SET_AGE:
			_set_age(w, cmd)
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
	if String(item.get("unit", "")) == "agent":
		# The Town Hall paid for it and refunds it: TownLink retires the agent, then drops it.
		w.emit_notice("cancel_agent", {"building": b.id, "agent_id": String(item.get("agent_id", ""))})
		return
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


# --- agents -----------------------------------------------------------------------------------
# These mirror decisions the Town Hall already made (and charged for), so they never touch the
# ledger. Each is idempotent: repeating one (TownLink catching up after a reconnect) is harmless.

static func _queue_agent(w: SimWorld, cmd: Dictionary) -> void:
	var b := _building(w, cmd)
	var agent_id := String(cmd.get("agent_id", ""))
	if b == null or agent_id == "" or not w.queued_agent(agent_id).is_empty() or w.agent_unit(agent_id) != null:
		return
	b.queue.append({"unit": "agent", "agent_id": agent_id, "role": String(cmd.get("role", "")), "op": "",
		"ticks": 0, "needed": maxi(int(cmd.get("ticks", 1)), 1)})
	w.entity_changed.emit(b.id, SimWorld.CAT_BUILDING)


static func _spawn_agent(w: SimWorld, cmd: Dictionary) -> void:
	var agent_id := String(cmd.get("agent_id", ""))
	if agent_id == "" or w.agent_unit(agent_id) != null:
		return
	_unqueue_agent(w, agent_id)
	var c := Pathing.nearest_walkable(w.grid, _cell(w, cmd), 12)
	if c == Pathing.NO_CELL:
		c = _cell(w, cmd)
	w.add_agent_unit(agent_id, String(cmd.get("role", "")), Pathing.center_of(c))


static func _drop_agent(w: SimWorld, cmd: Dictionary) -> void:
	var agent_id := String(cmd.get("agent_id", ""))
	if agent_id == "":
		return
	_unqueue_agent(w, agent_id)
	var u := w.agent_unit(agent_id)
	if u != null:
		w.stop_moving(u)
		w.units.erase(u.id)
		w.entity_removed.emit(u.id, SimWorld.CAT_UNIT)
	for t in w.agent_tools(agent_id):
		w.remove_building(t.id)
	var home := w.agent_home(agent_id)
	if home != null:
		w.remove_building(home.id)
	for i in range(w.wisps.size() - 1, -1, -1):
		if String(w.wisps[i]["agent_id"]) == agent_id:
			w.wisps.remove_at(i)
	for c: SimUnit in w.units.values():
		if c.job == SimConst.JOB_COURIER and String(c.payload.get("agent_id", "")) == agent_id:
			CourierJob.finish(w, c)
	w.emit_notice("agent_dropped", {"agent_id": agent_id})


static func _unqueue_agent(w: SimWorld, agent_id: String) -> void:
	for b: SimBuilding in w.buildings.values():
		for i in range(b.queue.size() - 1, -1, -1):
			if String(b.queue[i].get("agent_id", "")) == agent_id:
				b.queue.remove_at(i)
				if b.queue.is_empty():
					b.training_blocked = false
				w.entity_changed.emit(b.id, SimWorld.CAT_BUILDING)


## Places an agent's home (with its plot). Live nodes under the home are cleared; other
## buildings in the way make the command fail with "home_blocked" (TownLink validated the spot).
static func _place_home(w: SimWorld, cmd: Dictionary) -> void:
	var agent_id := String(cmd.get("agent_id", ""))
	var type := String(cmd.get("building", ""))
	if agent_id == "" or not w.econ.is_home(type) or w.agent_home(agent_id) != null:
		return
	var cell := Vector2i(int(cmd.get("x", 0)), int(cmd.get("y", 0)))
	var r := Rect2i(cell, w.econ.building_footprint(type))
	if not w.grid.rect_in_bounds(r) or _buildings_in(w, r):
		w.emit_notice("home_blocked", {"agent_id": agent_id})
		return
	var b := w.add_building(type, cell, bool(cmd.get("complete", false)), "", agent_id)
	w.emit_notice("home_placed", {"agent_id": agent_id, "building": b.id, "type": type})
	var u := w.agent_unit(agent_id)
	if u != null:
		u.home_id = b.id
		if u.job == SimConst.JOB_IDLE or u.job == SimConst.JOB_AGENT or u.job == SimConst.JOB_MOVE:
			AgentJob.decide(w, u)


static func _place_tool(w: SimWorld, cmd: Dictionary) -> void:
	var agent_id := String(cmd.get("agent_id", ""))
	var tool_id := String(cmd.get("tool_id", ""))
	var type := String(cmd.get("building", ""))
	if agent_id == "" or tool_id == "" or not w.econ.is_tool(type) or w.tool_building(tool_id) != null:
		return
	var cell := Vector2i(int(cmd.get("x", 0)), int(cmd.get("y", 0)))
	var r := Rect2i(cell, w.econ.building_footprint(type))
	if not w.grid.rect_in_bounds(r) or _buildings_in(w, r):
		w.emit_notice("tool_blocked", {"agent_id": agent_id, "tool_id": tool_id})
		return
	var b := w.add_building(type, cell, bool(cmd.get("complete", false)), "", agent_id, tool_id)
	w.emit_notice("tool_placed", {"agent_id": agent_id, "tool_id": tool_id, "building": b.id, "type": type})
	var u := w.agent_unit(agent_id)
	if u != null and (u.job == SimConst.JOB_IDLE or u.job == SimConst.JOB_AGENT):
		AgentJob.decide(w, u)


static func _remove_tool(w: SimWorld, cmd: Dictionary) -> void:
	var b := w.tool_building(String(cmd.get("tool_id", "")))
	if b != null:
		w.remove_building(b.id)


static func _complete_building(w: SimWorld, cmd: Dictionary) -> void:
	var b := _building(w, cmd)
	if b != null and not b.complete:
		w.complete_building(b)


static func _set_agent_state(w: SimWorld, cmd: Dictionary) -> void:
	var u := w.agent_unit(String(cmd.get("agent_id", "")))
	if u == null:
		return
	var activity := String(cmd.get("activity", "idle"))
	var tool := String(cmd.get("tool", ""))
	if activity == u.activity and tool == u.work_tool:
		return
	u.activity = activity
	u.work_tool = tool
	if u.job == SimConst.JOB_AGENT:
		AgentJob.start(w, u)
	w.entity_changed.emit(u.id, SimWorld.CAT_UNIT)


static func _courier(w: SimWorld, cmd: Dictionary) -> void:
	var u: SimUnit = w.units.get(int(cmd.get("unit", 0)))
	var b := _building(w, cmd)
	var payload := {"task_id": String(cmd.get("task_id", "")), "agent_id": String(cmd.get("agent_id", ""))}
	if u == null or b == null or not CourierJob.start(w, u, b.id, payload):
		w.emit_notice("courier_failed", {"unit": int(cmd.get("unit", 0)), "payload": payload})


static func _wisp(w: SimWorld, cmd: Dictionary) -> void:
	var b := _building(w, cmd)
	if b == null:
		return
	WispSystem.spawn(w, String(cmd.get("task_id", "")), String(cmd.get("agent_id", "")), b.id, int(cmd.get("delay", 0)))


static func _cancel_courier(w: SimWorld, cmd: Dictionary) -> void:
	var task_id := String(cmd.get("task_id", ""))
	if task_id == "":
		return
	for u: SimUnit in w.units.values():
		if u.job == SimConst.JOB_COURIER and String(u.payload.get("task_id", "")) == task_id:
			CourierJob.finish(w, u)
	WispSystem.cancel(w, task_id)


## Undoes a site or a queued unit whose spend the Town Hall refused (no refund: nothing was
## charged there).
static func _revoke_spend(w: SimWorld, cmd: Dictionary) -> void:
	var op := String(cmd.get("op", ""))
	if op == "":
		return
	for b: SimBuilding in w.buildings.values():
		if b.spend_op == op:
			var type := b.type
			w.remove_building(b.id)
			w.emit_notice("spend_revoked", {"type": type})
			return
		for i in b.queue.size():
			if String(b.queue[i].get("op", "")) == op:
				var unit := String(b.queue[i].get("unit", ""))
				b.queue.remove_at(i)
				if b.queue.is_empty():
					b.training_blocked = false
				w.entity_changed.emit(b.id, SimWorld.CAT_BUILDING)
				w.emit_notice("spend_revoked", {"type": unit})
				return


static func _set_age(w: SimWorld, cmd: Dictionary) -> void:
	var age := maxi(int(cmd.get("age", 1)), 1)
	if age == w.age:
		return
	w.age = age
	w.ledger.set_age(age)
	w.emit_notice("age_changed", {"age": age})


static func _buildings_in(w: SimWorld, r: Rect2i) -> bool:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var occ := w.grid.occupant_at(Vector2i(x, y))
			if occ != 0 and w.buildings.has(occ):
				return true
	return false
