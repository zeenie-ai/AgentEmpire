class_name CommandCardModel
extends RefCounted
## The 5x3 command card for the current selection, as plain data. Slot i is bound to the
## InputMap action card_i (Q W E R T / A S D F G / Z X C V B by default).
##
## Each slot is {} (empty) or {"id", "label", "icon", "tooltip", "cost", "enabled", "active"}.
## Disabled slots stay clickable so the player hears why ("Need 30 Wood").

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
		"rally_building", "building":
			var b: SimBuilding = w.buildings.get(int(sel[0]))
			if b != null:
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
		out[1] = _slot("summon", "Summon", "summon",
			"Summon an agent\nNeeds the Town Hall connection (next phase).", {}, false)
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
