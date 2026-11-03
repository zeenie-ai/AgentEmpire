extends GutTest
## ResourceFieldView draws trees, bushes, stumps, rocks and the backdrop in chunks of
## GrassField.CHUNK tiles: every node keeps a live and a depleted slot of its own in its chunk's
## MultiMeshes, and refresh() shows the look for its state there. (A headless run cannot read
## instance transforms back, so the transforms refresh() writes are checked through
## shown_transforms(), which it uses.)

var w: SimWorld
var view: ResourceFieldView


func before_each() -> void:
	w = SimFixture.generated_world(1234)
	view = ResourceFieldView.new()
	add_child_autofree(view)
	view.build(w)


## MultiMesh -> the name of the MultiMeshInstance3D that draws it ("<Layer>_<x>_<y>").
func _layer_names() -> Dictionary:
	var names := {}
	for c in view.get_children():
		var mmi := c as MultiMeshInstance3D
		names[mmi.multimesh] = String(mmi.name)
	return names


func _resource_nodes() -> Array[SimResourceNode]:
	var out: Array[SimResourceNode] = []
	for n: SimResourceNode in w.nodes.values():
		if n.kind == "tree" or n.kind == "berry_bush":
			out.append(n)
	return out


func test_every_node_has_its_own_slots_in_its_chunk() -> void:
	var names := _layer_names()
	var used := {}
	var owned := {}
	var nodes := _resource_nodes()
	assert_gt(nodes.size(), 100, "a generated map has a forest")
	for n in nodes:
		var s: Array = view._slots[n.id]
		var c := ResourceFieldView.chunk_of(n.cell)
		var tag := "_%d_%d" % [c.x, c.y]
		var live_layer := ("Bush" if n.kind == "berry_bush" else ("Conifer" if (n.variant & 1) == 0 else "Broadleaf")) + tag
		var dead_layer := ("Bare" if n.kind == "berry_bush" else "Stump") + tag
		var live: MultiMesh = s[0]
		var dead: MultiMesh = s[2]
		if String(names.get(live, "")) != live_layer or String(names.get(dead, "")) != dead_layer:
			fail_test("node %d at %s is drawn by %s and %s, not %s and %s" % [n.id, n.cell, names.get(live, "?"), names.get(dead, "?"), live_layer, dead_layer])
			return
		for k: String in ["%d:%d" % [live.get_instance_id(), int(s[1])], "%d:%d" % [dead.get_instance_id(), int(s[3])]]:
			if used.has(k):
				fail_test("node %d shares a slot with node %d" % [n.id, int(used[k])])
				return
			used[k] = n.id
		owned[live] = int(owned.get(live, 0)) + 1
		owned[dead] = int(owned.get(dead, 0)) + 1
	for mm: MultiMesh in owned:
		assert_eq(int(owned[mm]), mm.instance_count, "%s: one instance per node" % names[mm])


func test_the_map_and_the_backdrop_are_split_into_chunks() -> void:
	var layers := {}
	for layer: String in _layer_names().values():
		var parts := layer.split("_")
		assert_eq(parts.size(), 3, layer)
		layers[parts[0]] = int(layers.get(parts[0], 0)) + 1
	var tree_chunks := {}
	for n in _resource_nodes():
		if n.kind == "tree":
			tree_chunks[ResourceFieldView.chunk_of(n.cell)] = true
	assert_gt(tree_chunks.size(), 1, "the forest spans several chunks")
	assert_eq(int(layers.get("Stump", 0)), tree_chunks.size(), "one stump layer per chunk with trees")
	var per_side := ceili(float(w.grid.size) / GrassField.CHUNK)
	assert_gt(int(layers.get("BackdropConifer", 0)), per_side * 4, "the backdrop rings the map in chunks")


func test_refresh_shows_the_look_for_the_node_state() -> void:
	var n := _resource_nodes()[0]
	var t: Transform3D = view._transforms[n.id]
	var hidden := ResourceFieldView.hidden_at(t)
	var live: Array[Transform3D] = [t, hidden]
	var depleted: Array[Transform3D] = [hidden, t]
	var gone: Array[Transform3D] = [hidden, hidden]
	assert_eq(ResourceFieldView.shown_transforms(n, t), live, "live")
	n.depleted = true
	assert_eq(ResourceFieldView.shown_transforms(n, t), depleted, "depleted")
	view.refresh(n.id)
	w.nodes.erase(n.id)
	assert_eq(ResourceFieldView.shown_transforms(null, t), gone, "gone")
	view.refresh(n.id)


func test_a_hidden_instance_stays_under_its_own_spot() -> void:
	for n in _resource_nodes():
		var t: Transform3D = view._transforms[n.id]
		var hidden := ResourceFieldView.hidden_at(t)
		var cell := Vector2i(floori(hidden.origin.x), floori(hidden.origin.z))
		if cell != n.cell or hidden.origin.y >= 0.0 or hidden.basis.get_scale().x > 0.001:
			fail_test("node %d at %s hides at %s" % [n.id, n.cell, hidden.origin])
			return
	pass_test("every hidden instance is a speck under its node, inside the node's chunk")
