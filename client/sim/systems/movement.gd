class_name Movement
extends RefCounted
## Path following and steering. No physics bodies: units follow cell-centre waypoints at their
## walk speed and a spatial hash pushes neighbours apart.
##
## Steering never pushes a walker backwards along its path (only sideways or forwards), so a
## converging group cannot freeze in a push-versus-walk equilibrium; walkers pass through each
## other when they must. Pushes never move a unit into a solid cell. A walker that makes no net
## progress for STUCK_TICKS either counts as arrived (when close to its goal) or re-paths.

## Net movement per tick below this counts as no progress (the walk step is ~0.06 tiles).
const STUCK_EPS := 0.015
## A stuck walker this close to its goal counts as arrived.
const ARRIVE_SLACK := 1.5


static func advance(w: SimWorld, u: SimUnit) -> void:
	if u.path_state != SimConst.PATH_READY:
		return
	var start := u.pos
	var remaining := w.walk_step(u.kind)
	while remaining > 0.000001 and u.path_i < u.path.size():
		var wp := Pathing.center_of(u.path[u.path_i])
		var to := wp - u.pos
		var d := to.length()
		if d <= remaining:
			if not _try_move(w, u, wp):
				break
			remaining -= d
			u.path_i += 1
		else:
			_try_move(w, u, u.pos + to * (remaining / d))
			remaining = 0.0
	if u.path_i >= u.path.size():
		u.path_state = SimConst.PATH_DONE
		u.stuck_ticks = 0
	var moved := u.pos - start
	if moved.length_squared() > 0.000001:
		u.facing = atan2(moved.x, moved.y)


## Moves to `np` if walkable, else slides along one axis. Returns true on a full move.
static func _try_move(w: SimWorld, u: SimUnit, np: Vector2) -> bool:
	if w.grid.is_walkable_pos(np):
		u.pos = np
		return true
	var nx := Vector2(np.x, u.pos.y)
	if w.grid.is_walkable_pos(nx):
		u.pos = nx
		return false
	var ny := Vector2(u.pos.x, np.y)
	if w.grid.is_walkable_pos(ny):
		u.pos = ny
	return false


## Pushes overlapping units apart, then checks walkers for lack of progress.
static func separate(w: SimWorld) -> void:
	var sep := SimConst.SEPARATION
	var sep2 := sep * sep
	var pushes: Dictionary = {}
	for u: SimUnit in w.units.values():
		var weight := _mobility(u)
		if weight <= 0.0:
			continue
		var push := Vector2.ZERO
		for oid in w.spatial.query(u.pos, sep):
			if oid == u.id:
				continue
			var o: SimUnit = w.units.get(oid)
			if o == null:
				continue
			var d := u.pos - o.pos
			var dist2 := d.length_squared()
			if dist2 >= sep2:
				continue
			if dist2 < 0.00000001:
				# Exactly overlapping: split along a direction derived from the ids.
				var a := float(u.id * 7 + oid * 13) * 2.399963
				push += Vector2(cos(a), sin(a)) * sep * 0.5
			else:
				var dist := sqrt(dist2)
				push += d / dist * (sep - dist) * 0.5
		if push == Vector2.ZERO:
			continue
		push *= weight
		var dir := _heading(u)
		if dir != Vector2.ZERO:
			var back := push.dot(dir)
			if back < 0.0:
				push -= dir * back
		pushes[u.id] = push.limit_length(SimConst.MAX_PUSH)
	for id: int in pushes:
		var u: SimUnit = w.units[id]
		var np: Vector2 = u.pos + pushes[id]
		if w.grid.is_walkable_pos(np):
			u.pos = np
		else:
			var nx := Vector2(np.x, u.pos.y)
			var ny := Vector2(u.pos.x, np.y)
			if w.grid.is_walkable_pos(nx):
				u.pos = nx
			elif w.grid.is_walkable_pos(ny):
				u.pos = ny
	for u: SimUnit in w.units.values():
		if u.path_state != SimConst.PATH_READY:
			u.stuck_ticks = 0
			continue
		if u.pos.distance_squared_to(u.prev_pos) >= STUCK_EPS * STUCK_EPS:
			u.stuck_ticks = 0
			continue
		u.stuck_ticks += 1
		if u.stuck_ticks < SimConst.STUCK_TICKS:
			continue
		u.stuck_ticks = 0
		if Pathing.rect_distance(u.pos, u.goal_rect) <= ARRIVE_SLACK:
			u.path_state = SimConst.PATH_DONE
		else:
			w.repath(u)


## Unit direction toward its next waypoint, or zero when not walking.
static func _heading(u: SimUnit) -> Vector2:
	if u.path_state != SimConst.PATH_READY or u.path_i >= u.path.size():
		return Vector2.ZERO
	var d := Pathing.center_of(u.path[u.path_i]) - u.pos
	return d.normalized() if d.length_squared() > 0.000001 else Vector2.ZERO


static func _mobility(u: SimUnit) -> float:
	if u.is_working():
		return 0.0
	if u.path_state == SimConst.PATH_READY:
		return 0.5
	return 1.0
