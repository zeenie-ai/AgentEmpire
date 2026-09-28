class_name Picking
extends RefCounted
## Screen-to-world picking without physics bodies: units by distance between the cursor and
## their projected position, buildings by ray-box tests, trees and bushes by marching along the
## camera ray, and finally the ground cell.
##
## Results are {"kind": "unit"|"building"|"node"|"ground", "id": int, "cell": Vector2i}.

const UNIT_PICK_PX := 22.0
const NODE_HEIGHTS := {"tree": 2.2, "berry_bush": 0.6}


static func pick(world: SimWorld, view: WorldView, cam: Camera3D, screen: Vector2) -> Dictionary:
	var ground_hit: Variant = _ground(cam, screen)
	var ground_cell := Pathing.NO_CELL
	if ground_hit != null:
		var g: Vector3 = ground_hit
		ground_cell = Vector2i(floori(g.x), floori(g.z))
	# Units first: they are small and stand in front of everything else.
	var best_id := 0
	var best_d := UNIT_PICK_PX
	for id: int in view.unit_views:
		var p := view.unit_visual_position(id) + Vector3(0, 0.45, 0)
		if cam.is_position_behind(p):
			continue
		var d := cam.unproject_position(p).distance_to(screen)
		if d < best_d:
			best_d = d
			best_id = id
	if best_id != 0:
		return {"kind": "unit", "id": best_id, "cell": world.units[best_id].cell()}
	var from := cam.project_ray_origin(screen)
	var dir := cam.project_ray_normal(screen)
	# Buildings: nearest ray hit against footprint x height boxes.
	var hit_b := 0
	var hit_b_dist := INF
	for b: SimBuilding in world.buildings.values():
		var h := ModelLibrary.building_height(b.type) * (b.progress() if not b.complete else 1.0)
		var box := AABB(Vector3(b.cell.x, 0.0, b.cell.y), Vector3(b.size.x, maxf(h, 0.3), b.size.y))
		var hit: Variant = box.intersects_ray(from, dir)
		if hit != null:
			var d := from.distance_to(hit)
			if d < hit_b_dist:
				hit_b_dist = d
				hit_b = b.id
	# Trees and bushes: march along the ray through the height band they occupy.
	var hit_n := 0
	var hit_n_dist := INF
	if absf(dir.y) > 0.0001:
		var t0 := (2.4 - from.y) / dir.y
		var t1 := -from.y / dir.y
		if t1 > 0.0:
			var t := maxf(t0, 0.0)
			while t <= t1:
				var p := from + dir * t
				var n := world.node_at(Vector2i(floori(p.x), floori(p.z)))
				if n != null and n.is_live() and p.y <= float(NODE_HEIGHTS.get(n.kind, 1.0)):
					hit_n = n.id
					hit_n_dist = t
					break
				t += 0.2
	if hit_b != 0 and hit_b_dist <= hit_n_dist:
		return {"kind": "building", "id": hit_b, "cell": ground_cell if ground_cell != Pathing.NO_CELL else world.buildings[hit_b].cell}
	if hit_n != 0:
		return {"kind": "node", "id": hit_n, "cell": world.nodes[hit_n].cell}
	if ground_cell == Pathing.NO_CELL:
		return {"kind": "none", "id": 0, "cell": Pathing.NO_CELL}
	var gb := world.building_at(ground_cell)
	if gb != null:
		return {"kind": "building", "id": gb.id, "cell": ground_cell}
	var gn := world.node_at(ground_cell)
	if gn != null and gn.is_live():
		return {"kind": "node", "id": gn.id, "cell": ground_cell}
	var clamped := ground_cell.clamp(Vector2i.ZERO, Vector2i(world.grid.size - 1, world.grid.size - 1))
	return {"kind": "ground", "id": 0, "cell": clamped}


static func _ground(cam: Camera3D, screen: Vector2) -> Variant:
	var from := cam.project_ray_origin(screen)
	var dir := cam.project_ray_normal(screen)
	if absf(dir.y) < 0.0001:
		return null
	var t := -from.y / dir.y
	return from + dir * t if t > 0.0 else null


## Units whose projected position lies inside `rect` (screen space).
static func units_in_rect(world: SimWorld, view: WorldView, cam: Camera3D, rect: Rect2) -> Array[int]:
	var out: Array[int] = []
	for id: int in view.unit_views:
		var u: SimUnit = world.units.get(id)
		if u == null or u.kind != "townsfolk":
			continue
		var p := view.unit_visual_position(id) + Vector3(0, 0.35, 0)
		if cam.is_position_behind(p):
			continue
		if rect.has_point(cam.unproject_position(p)):
			out.append(id)
	return out


## Entities of the same kind as `sample` that are visible on screen.
static func same_kind_on_screen(world: SimWorld, view: WorldView, cam: Camera3D, sample: int) -> Array[int]:
	var screen := cam.get_viewport().get_visible_rect()
	var out: Array[int] = []
	var su: SimUnit = world.units.get(sample)
	if su != null:
		for id: int in view.unit_views:
			var u: SimUnit = world.units.get(id)
			if u != null and u.kind == su.kind:
				var p := view.unit_visual_position(id)
				if not cam.is_position_behind(p) and screen.has_point(cam.unproject_position(p)):
					out.append(id)
		return out
	var sb: SimBuilding = world.buildings.get(sample)
	if sb != null:
		for b: SimBuilding in world.buildings.values():
			if b.type == sb.type:
				var p := Vector3(b.center().x, 0.5, b.center().y)
				if not cam.is_position_behind(p) and screen.has_point(cam.unproject_position(p)):
					out.append(b.id)
	return out
