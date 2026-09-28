class_name Selection
extends RefCounted
## What the player has selected, plus control groups 1-9. Selection is view state, not game
## state, so it never goes through GameCommands.

signal changed()

var ids: Array[int] = []
## group number -> Array of entity ids
var groups: Dictionary = {}


func set_ids(new_ids: Array) -> void:
	var clean: Array[int] = []
	for v: Variant in new_ids:
		var id := int(v)
		if not id in clean:
			clean.append(id)
	if clean == ids:
		return
	ids = clean
	changed.emit()


func clear() -> void:
	set_ids([])


func has(id: int) -> bool:
	return id in ids


func toggle(id: int) -> void:
	var next: Array = ids.duplicate()
	if id in next:
		next.erase(id)
	else:
		next.append(id)
	set_ids(next)


func add(more: Array) -> void:
	var next: Array = ids.duplicate()
	next.append_array(more)
	set_ids(next)


func is_empty() -> bool:
	return ids.is_empty()


## Drops ids that no longer exist in `world`.
func prune(world: SimWorld) -> void:
	var keep: Array[int] = []
	for id in ids:
		if world.get_entity(id) != null:
			keep.append(id)
	if keep.size() != ids.size():
		set_ids(keep)


func assign_group(n: int) -> void:
	groups[n] = ids.duplicate()


## Selects control group `n` (only members that still exist). Returns the selection.
func recall_group(n: int, world: SimWorld) -> Array[int]:
	var members: Array[int] = []
	for v: Variant in groups.get(n, []):
		if world.get_entity(int(v)) != null:
			members.append(int(v))
	set_ids(members)
	return members


func units(world: SimWorld) -> Array[int]:
	var out: Array[int] = []
	for id in ids:
		var u: SimUnit = world.units.get(id)
		if u != null:
			out.append(id)
	return out


func single_building(world: SimWorld) -> SimBuilding:
	if ids.size() != 1:
		return null
	return world.buildings.get(ids[0])
