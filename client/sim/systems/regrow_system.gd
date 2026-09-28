class_name RegrowSystem
extends RefCounted
## Depleted bushes and trees regrow after their regrow_s (economy.json). A node waits while a
## unit stands on its cell.


static func tick(w: SimWorld) -> void:
	if w.regrowing.is_empty():
		return
	var still: Array[int] = []
	var grown: Array[SimResourceNode] = []
	for id in w.regrowing:
		var n: SimResourceNode = w.nodes.get(id)
		if n == null or not n.depleted:
			continue
		n.regrow_ticks -= 1
		if n.regrow_ticks > 0:
			still.append(id)
			continue
		if w.grid.occupant_at(n.cell) != n.id or w.unit_on_cell(n.cell):
			n.regrow_ticks = w.tick_rate
			still.append(id)
			continue
		grown.append(n)
	w.regrowing = still
	for n in grown:
		w.regrow_node(n)
