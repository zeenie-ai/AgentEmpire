class_name TrainingSystem
extends RefCounted
## Advances the head of each training queue. Training pauses while the new unit would not fit
## under the population cap, with a single "need_houses" notice when it first pauses.


static func tick(w: SimWorld) -> void:
	for b: SimBuilding in w.buildings.values():
		if b.queue.is_empty() or not b.complete:
			if b.training_blocked:
				b.training_blocked = false
				w.entity_changed.emit(b.id, SimWorld.CAT_BUILDING)
			continue
		var item: Dictionary = b.queue[0]
		var pop := w.econ.unit_pop(String(item.get("unit", "townsfolk")))
		if w.pop_used() + pop > w.pop_cap():
			if not b.training_blocked:
				b.training_blocked = true
				w.emit_notice("need_houses", {"building": b.id})
				w.entity_changed.emit(b.id, SimWorld.CAT_BUILDING)
			continue
		if b.training_blocked:
			b.training_blocked = false
			w.entity_changed.emit(b.id, SimWorld.CAT_BUILDING)
		item["ticks"] = int(item.get("ticks", 0)) + 1
		if int(item["ticks"]) >= int(item.get("needed", 1)):
			b.queue.pop_front()
			w.finish_training(b, item)
