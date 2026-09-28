class_name ConstructionSystem
extends RefCounted
## Advances construction sites by the builders counted this tick (BuildJob increments
## builders_tick for every builder standing at the site).


static func tick(w: SimWorld) -> void:
	for b: SimBuilding in w.buildings.values():
		if b.complete:
			continue
		var n := b.builders_tick
		b.builders_tick = 0
		if n <= 0:
			continue
		b.work += w.work_per_tick(b.type, n)
		if b.work >= SimConst.WORK_SCALE:
			w.complete_building(b)
