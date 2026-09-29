class_name CommandCardModel
extends RefCounted
## The 5x3 command card for the current selection, as plain data. Slot i is bound to the
## InputMap action card_i (Q W E R T / A S D F G / Z X C V B by default).
##
## Each slot is {} (empty) or {"id", "label", "icon", "tooltip", "cost", "enabled", "active"}.
## Disabled slots stay clickable so the player hears why ("Need 30 Wood").
##
## Agents (their figure, home or add-ons) get their own card: send a task, review, answer
## approvals, choose a plot, add add-ons, resume or cancel work, retire. It reads the Town
## Hall's state from Realm; everything it offers goes through TownLink.

const SLOTS := 15


static func slots(w: SimWorld, sel: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in SLOTS:
		out.append({})
	if w == null or sel.is_empty():
		return out
	match RightClickRules.selection_kind(w, sel):
		"units":
			_townsfolk(w, sel, out)
		"agent":
			var u: SimUnit = w.units.get(int(sel[0]))
			if u != null:
				_agent(w, u.agent_id, out)
		"rally_building", "building":
			var b: SimBuilding = w.buildings.get(int(sel[0]))
			if b == null:
				pass
			elif b.owner_agent_id != "" and b.tool_id != "":
				_tool(w, b, out)
			elif b.owner_agent_id != "":
				_agent(w, b.owner_agent_id, out)
			else:
				_building(w, b, out)
	return out


static func _townsfolk(w: SimWorld, sel: Array, out: Array[Dictionary]) -> void:
	var i := 0
	for t in w.econ.buildable_by("townsfolk"):
		if i >= 5:
			break
		var cost := w.econ.building_cost(t)
		var ok := w.ledger.can_afford(cost) and w.econ.building_age(t) <= w.age
		out[i] = _slot("build:" + t, w.econ.building_name(t), t,
			"%s\n%s" % [w.econ.building_name(t), w.econ.building_plain(t)], cost, ok)
		i += 1
	var carrying := false
	for id: Variant in sel:
		var u: SimUnit = w.units.get(int(id))
		if u != null and u.is_carrying():
			carrying = true
	out[5] = _slot("stop", "Stop", "stop", "Stop\nWait here instead of looking for work.", {}, true)
	out[6] = _slot("return", "Return", "return", "Return goods\nTake what they carry to the nearest drop-off.", {}, carrying)
	out[7] = _slot("auto_gather", "Gather", "gather", "Gather\nFood or Wood, whichever the town needs (or the Keep's focus).", {}, true)


static func _building(w: SimWorld, b: SimBuilding, out: Array[Dictionary]) -> void:
	if not b.complete:
		out[14] = _slot("cancel_site", "Cancel", "cancel", "Cancel construction\nRefunds everything.", {}, true)
		return
	if SimWorld.TRAINERS.has(b.type):
		for unit: String in SimWorld.TRAINERS[b.type]:
			var cost := w.econ.unit_cost(unit)
			var ok := w.ledger.can_afford(cost) and b.queue.size() < w.econ.training_queue_max()
			out[0] = _slot("train:" + unit, "Townsperson", unit,
				"Train a townsperson (%d s)\nGathers Food and Wood, builds houses, carries scrolls." % int(w.econ.unit_train_s(unit)), cost, ok)
		out[1] = _summon_slot(w)
		out[3] = _slot("rally", "Rally", "rally", "Set rally point\nNew townsfolk walk there; a resource means start gathering it. Right-click also works.", {}, true)
		var focus := b.gather_focus
		out[5] = _slot("focus:auto", "Auto", "focus_auto", "Gather Focus: auto\nIdle townsfolk gather whichever of Food or Wood is lower.", {}, true, focus == "auto")
		var k := 6
		for res in w.econ.gatherable_resources():
			if k > 9:
				break
			out[k] = _slot("focus:" + res, res.capitalize(), "focus_" + res,
				"Gather Focus: %s\nIdle townsfolk gather %s first." % [res.capitalize(), res.capitalize()], {}, true, focus == res)
			k += 1
		if not b.queue.is_empty():
			out[14] = _slot("cancel_train", "Cancel", "cancel", "Cancel the last queued unit\nRefunds in full.", {}, true)
		return
	if w.econ.building_built_by(b.type) == "townsfolk":
		var pct := int(round(w.econ.refund_fraction("dismantle") * 100.0))
		out[14] = _slot("dismantle", "Dismantle", "dismantle", "Dismantle\nRefunds %d%% of the cost." % pct, {}, true)


static func _slot(id: String, label: String, icon: String, tooltip: String, cost: Dictionary,
		enabled: bool, active: bool = false) -> Dictionary:
	return {"id": id, "label": label, "icon": icon, "tooltip": tooltip, "cost": cost,
		"enabled": enabled, "active": active}


static func _live() -> bool:
	var game := _game()
	return game != null and game.link != null and game.link.is_live()


static func _game() -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	return loop.root.get_node_or_null("Game") if loop != null else null


static func _realm() -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	return loop.root.get_node_or_null("Realm") if loop != null else null


static func _summon_slot(w: SimWorld) -> Dictionary:
	var realm := _realm()
	if not _live() or realm == null:
		return _slot("summon", "Summon", "summon",
			"Summon an agent\nStart the Town Hall to summon Claude Code, Codex or pi agents.", {}, false)
	var count: int = realm.agent_count()
	var limit := w.econ.agent_limit(realm.current_age())
	var tip := "Summon an agent (W)\nChoose its harness, role, oath and add-ons. It trains here, then builds its home."
	if count == 0:
		tip += "\nFont's Grace: your first agent, its home and its required add-ons are free."
	if count >= limit:
		return _slot("summon", "Summon", "summon", tip + "\nThis age allows %d agents." % limit, {}, false)
	return _slot("summon", "Summon", "summon", tip, {}, true, count == 0)


## The card for an agent (its figure or its home).
static func _agent(w: SimWorld, agent_id: String, out: Array[Dictionary]) -> void:
	var realm := _realm()
	if realm == null:
		return
	var live := _live()
	var a: Dictionary = realm.agent(agent_id)
	var who := J.gs(a, "name", "The agent")
	var lifecycle := J.gs(a, "lifecycle")
	var home := w.agent_home(agent_id)
	var settled := home != null and home.complete
	var tasks: Array = realm.tasks_of(agent_id)
	var in_review := false
	var resumable := ""
	var cancelable := ""
	for t: Dictionary in tasks:
		var st := J.gs(t, "state")
		if st == "awaiting_review" or st == "accepting":
			in_review = true
		elif (st == "paused" or st == "failed") and resumable == "":
			resumable = J.gs(t, "id")
		elif st in ["running", "preparing", "awaiting_approval", "queued", "in_transit"] and cancelable == "":
			cancelable = J.gs(t, "id")
	var queue_max := w.econ.home_task_queue(realm.current_age())
	var waiting := 0
	for t: Dictionary in tasks:
		if J.gs(t, "state") in ["queued", "in_transit"]:
			waiting += 1
	var task_ok := live and settled and lifecycle == "active" and waiting < queue_max
	var task_tip := "Send %s a task (Q)\nWrite the quest; a townsperson carries the scroll from the Keep." % who
	if not settled:
		task_tip += "\n%s needs a finished home first." % who
	elif lifecycle != "active":
		task_tip += "\n%s is still setting up (home, required add-ons, work folder)." % who
	elif waiting >= queue_max:
		task_tip += "\nThe home holds %d waiting task(s) in this age." % queue_max
	out[0] = _slot("task", "Task", "task", task_tip, {}, task_ok)
	out[1] = _slot("review", "Review", "review",
		"Review the result (W)\nRead the changes, then accept, send back or abandon." if in_review else "Review\nNothing waits for review.",
		{}, live and in_review, in_review)
	var approvals: Array = realm.approvals_for(agent_id)
	out[2] = _slot("approvals", "Answer" if approvals.is_empty() else "Answer %d" % approvals.size(), "bell",
		"Answer %s's approvals (E)\n%d waiting." % [who, approvals.size()] if not approvals.is_empty() else "Approvals\nNothing to answer.",
		{}, live and not approvals.is_empty(), not approvals.is_empty())
	if home == null and lifecycle != "training":
		out[4] = _slot("place_home", "Plot", "plot",
			"Choose a plot for %s's %s (T)\nA 7x7 plot: the home in the middle, add-ons around it." % [who, w.econ.building_name(w.econ.role_home(J.gs(a, "role")))],
			{}, live and lifecycle != "retired", true)
	var have: Array[String] = []
	for t: Dictionary in realm.tools_of(agent_id):
		have.append(J.gs(t, "type"))
	var age: int = realm.current_age()
	var slots_left := w.econ.tool_slots(age) - have.size()
	var i := 5
	for type in w.econ.tool_types():
		if i > 9:
			break
		if type in have or type == "waygate":
			continue
		var def := w.econ.tool_def(type)
		var cost := w.econ.building_cost(type)
		var tip := "%s\n%s" % [w.econ.building_name(type), String(def.get("plain", ""))]
		var ok := live and settled
		if int(def.get("age", 1)) > age:
			tip += "\nRequires the %s Age." % w.econ.age_name(int(def.get("age", 1)))
			ok = false
		for req in w.econ.tool_requires(type):
			if not req in have:
				tip += "\nNeeds a %s first." % w.econ.building_name(req)
				ok = false
		if slots_left <= 0:
			tip += "\nThe plot holds %d add-ons in this age." % w.econ.tool_slots(age)
			ok = false
		if ok and not w.ledger.can_afford(cost):
			ok = false
		out[i] = _slot("add_tool:" + type, w.econ.building_name(type), type, tip, cost, ok)
		i += 1
	if resumable != "":
		out[10] = _slot("resume:" + resumable, "Resume", "resume", "Resume the paused or failed task (Z)", {}, live)
	if cancelable != "":
		out[11] = _slot("cancel_task:" + cancelable, "Cancel", "cancel", "Cancel the current task (X)\nNo reward; the work so far is kept for you to discard.", {}, live)
	if lifecycle == "training":
		out[14] = _slot("cancel_summon", "Cancel", "cancel", "Cancel the summoning\nRefunds in full.", {}, live)
	elif lifecycle != "retired":
		out[14] = _slot("retire", "Retire", "retire", "Retire %s (B)\nAfter the current task. Their home and add-ons go with them." % who, {}, live)


## An add-on: dismantle it (the Town Hall refunds half).
static func _tool(w: SimWorld, b: SimBuilding, out: Array[Dictionary]) -> void:
	var pct := int(round(w.econ.refund_fraction("dismantle") * 100.0))
	out[14] = _slot("detach:" + b.tool_id, "Dismantle", "dismantle",
		"Dismantle the %s\nRefunds %d%% of the cost. Add-ons that need it must go first." % [w.econ.building_name(b.type), pct], {}, _live())
