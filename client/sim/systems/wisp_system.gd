class_name WispSystem
extends RefCounted
## Font Wisps: spirit couriers that carry a task scroll when no townsperson could. A wisp waits
## at the Keep for its delay (couriers.wisp_after_s counted from when the task was sent), then
## flies straight to the agent's home at SimConst.WISP_SPEED and raises "wisp_arrived", which
## TownLink turns into task_delivered.


static func spawn(w: SimWorld, task_id: String, agent_id: String, building_id: int, delay_ticks: int) -> Dictionary:
	for existing in w.wisps:
		if String(existing["task_id"]) == task_id:
			return existing
	var k := w.keep()
	var start := k.center() if k != null else w.map_center()
	var wisp := {"id": w.new_id(), "task_id": task_id, "agent_id": agent_id, "building": building_id,
		"pos": start, "prev": start, "delay": maxi(delay_ticks, 0)}
	w.wisps.append(wisp)
	w.emit_notice("wisp_spawned", {"id": int(wisp["id"]), "task_id": task_id, "agent_id": agent_id})
	return wisp


## Removes the wisps carrying `task_id` without delivering. Returns how many there were.
static func cancel(w: SimWorld, task_id: String) -> int:
	var n := 0
	for i in range(w.wisps.size() - 1, -1, -1):
		if String(w.wisps[i]["task_id"]) == task_id:
			w.wisps.remove_at(i)
			n += 1
	return n


static func tick(w: SimWorld) -> void:
	if w.wisps.is_empty():
		return
	var step := SimConst.WISP_SPEED * w.dt
	for i in range(w.wisps.size() - 1, -1, -1):
		var wisp: Dictionary = w.wisps[i]
		wisp["prev"] = wisp["pos"]
		if int(wisp["delay"]) > 0:
			wisp["delay"] = int(wisp["delay"]) - 1
			continue
		var b: SimBuilding = w.buildings.get(int(wisp["building"]))
		if b == null:
			w.wisps.remove_at(i)
			w.emit_notice("wisp_lost", {"id": int(wisp["id"]), "task_id": String(wisp["task_id"])})
			continue
		var pos: Vector2 = wisp["pos"]
		var to := b.center() - pos
		var d := to.length()
		if d <= SimConst.WISP_ARRIVE:
			w.wisps.remove_at(i)
			w.emit_notice("wisp_arrived", {"id": int(wisp["id"]), "task_id": String(wisp["task_id"]),
				"agent_id": String(wisp["agent_id"]), "building": b.id})
			continue
		wisp["pos"] = pos + to * (minf(step, d) / d)


static func to_list(w: SimWorld) -> Array:
	var out := []
	for wisp in w.wisps:
		var p: Vector2 = wisp["pos"]
		out.append({"id": int(wisp["id"]), "task_id": String(wisp["task_id"]), "agent_id": String(wisp["agent_id"]),
			"building": int(wisp["building"]), "pos": [p.x, p.y], "delay": int(wisp["delay"])})
	return out


static func from_list(w: SimWorld, list: Array) -> void:
	w.wisps.clear()
	for v: Variant in list:
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = v
		var pa: Array = d.get("pos", [0, 0])
		var p := Vector2(float(pa[0]), float(pa[1]))
		w.wisps.append({"id": int(d.get("id", 0)), "task_id": String(d.get("task_id", "")),
			"agent_id": String(d.get("agent_id", "")), "building": int(d.get("building", 0)),
			"pos": p, "prev": p, "delay": int(d.get("delay", 0))})
