class_name ModelLibrary
extends RefCounted
## The boundary between game code and art. Views ask for models and meshes by key; today every
## key is built procedurally from primitives in the handoff palette. To use a real model
## (a Kenney kit piece, a Blender GLB from art_src/), add its scene to OVERRIDES: no view
## changes are needed.
##
## Conventions for every model: origin at the centre of its footprint on the ground (y = 0),
## +Y up, 1 unit = 1 tile, front facing +Z. Building models carry meta "height" (for the
## construction rise) and may contain a node named "Font" (the Keep's spinning ring).

## key -> scene path, e.g. "building/cottage": "res://art/models/cottage.glb".
const OVERRIDES := {}

const HEIGHTS := {"keep": 6.3, "cottage": 1.85, "farm": 0.4, "storehouse": 1.85}

static var _meshes: Dictionary = {}


## A fresh model node for `key`: "building/<type>", "unit/<kind>".
static func instance(key: String, variant: int = 0) -> Node3D:
	if OVERRIDES.has(key):
		var scene := load(String(OVERRIDES[key])) as PackedScene
		if scene != null:
			return scene.instantiate() as Node3D
	var root := Node3D.new()
	root.name = key.get_slice("/", 1).capitalize().replace(" ", "")
	var parts := key.split("/")
	match parts[0]:
		"building":
			var type := parts[1] if parts.size() > 1 else ""
			root.set_meta("height", building_height(type))
			_add(root, "Body", mesh("building/" + type))
			if type == "keep":
				var font := MeshInstance3D.new()
				font.name = "Font"
				var torus := TorusMesh.new()
				torus.inner_radius = 0.58
				torus.outer_radius = 0.7
				torus.rings = 32
				torus.ring_segments = 8
				font.mesh = torus
				font.material_override = ArtMaterials.gold()
				font.position = Vector3(0, 7.2, 0)
				font.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				root.add_child(font)
		"unit":
			var body := Node3D.new()
			body.name = "Body"
			root.add_child(body)
			_add(body, "Mesh", mesh("unit/townsfolk/%d" % (variant % Palette.TUNICS.size())))
			var wood := _add(body, "CarryWood", mesh("carry/wood"))
			var food := _add(body, "CarryFood", mesh("carry/food"))
			wood.visible = false
			food.visible = false
	return root


static func building_height(type: String) -> float:
	return float(HEIGHTS.get(type, 2.0))


static func _add(parent: Node3D, node_name: String, m: Mesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = m
	parent.add_child(mi)
	return mi


## A cached mesh for `key`. Also used directly by MultiMesh views (trees, bushes, rings).
static func mesh(key: String) -> Mesh:
	if _meshes.has(key):
		return _meshes[key]
	var m: Mesh = _build(key)
	_meshes[key] = m
	return m


static func _build(key: String) -> Mesh:
	var parts := key.split("/")
	match key:
		"building/keep":
			return _keep()
		"building/cottage":
			return _cottage()
		"building/farm":
			return _farm()
		"building/storehouse":
			return _storehouse()
		"node/tree_conifer":
			return _conifer()
		"node/tree_broadleaf":
			return _broadleaf()
		"node/berry_bush":
			return _bush(true)
		"node/bush_bare":
			return _bush(false)
		"node/stump":
			return _stump()
		"decor/rock":
			return _rock()
		"decor/stake":
			return _stake(false)
		"decor/stake_flag":
			return _stake(true)
		"fx/ring":
			var f := MeshFactory.new()
			f.ring_flat(Vector3.ZERO, 0.84, 1.0, 40, Color.WHITE)
			return f.commit(ArtMaterials.ring())
		"carry/wood":
			return _carry_wood()
		"carry/food":
			return _carry_food()
	if parts.size() == 3 and parts[0] == "unit":
		return _townsfolk(int(parts[2]))
	if parts.size() == 4 and parts[0] == "scaffold":
		return _scaffold(Vector2i(int(parts[1]), int(parts[2])), float(parts[3]) / 100.0)
	if parts.size() == 3 and parts[0] == "plot":
		return _plot(Vector2i(int(parts[1]), int(parts[2])))
	push_warning("ModelLibrary: unknown mesh key %s" % key)
	var f := MeshFactory.new()
	f.box(Vector3(0, 0.5, 0), Vector3.ONE, Color.MAGENTA)
	return f.commit(ArtMaterials.base())


# --- buildings ----------------------------------------------------------------------------

static func _keep() -> ArrayMesh:
	var f := MeshFactory.new()
	var s := Palette.STONE
	f.box(Vector3(0, 0.12, 0), Vector3(3.9, 0.24, 3.9), Palette.STONE_DARK)
	f.box(Vector3(0, 1.24, 0), Vector3(2.7, 2.0, 2.7), s, s.lightened(0.05))
	for i in 4:
		var t := -1.05 + 0.7 * float(i)
		for p: Vector3 in [Vector3(t, 2.39, 1.25), Vector3(t, 2.39, -1.25), Vector3(1.25, 2.39, t), Vector3(-1.25, 2.39, t)]:
			f.box(p, Vector3(0.26, 0.3, 0.26), s)
	f.cylinder(Vector3(0, 0.24, 0), 0.86, 0.78, 4.1, 10, s, true, false, s.darkened(0.1))
	f.cone(Vector3(0, 4.34, 0), 1.06, 1.9, 10, Palette.SLATE)
	for cx in [-1.45, 1.45]:
		for cz in [-1.45, 1.45]:
			f.cylinder(Vector3(cx, 0.24, cz), 0.47, 0.42, 2.7, 8, s)
			f.cone(Vector3(cx, 2.94, cz), 0.6, 1.15, 8, Palette.SLATE)
	f.box(Vector3(0, 0.74, 1.37), Vector3(0.72, 1.0, 0.08), Palette.INK)
	f.box(Vector3(0, 1.3, 1.38), Vector3(0.9, 0.12, 0.1), Palette.WOOD_DARK)
	f.box(Vector3(0, 6.55, 0), Vector3(0.05, 0.7, 0.05), Palette.WOOD_DARK)
	f.flag(Vector3(0.03, 6.88, 0), 0.5, 0.32, Palette.GOLD_DEEP)
	f.end_surface(ArtMaterials.base())
	for a in 4:
		var d := Vector3(cos(a * PI * 0.5 + PI * 0.25), 0, sin(a * PI * 0.5 + PI * 0.25))
		f.box(Vector3(0, 3.4, 0) + d * 0.8, Vector3(0.18, 0.3, 0.18), Color.WHITE)
	for x in [-0.8, 0.8]:
		f.box(Vector3(x, 1.7, 1.37), Vector3(0.22, 0.34, 0.05), Color.WHITE)
	return f.commit(ArtMaterials.glow())


static func _cottage() -> ArrayMesh:
	var f := MeshFactory.new()
	f.box(Vector3(0, 0.06, 0), Vector3(1.7, 0.12, 1.6), Palette.STONE_DARK)
	f.box(Vector3(0, 0.6, 0), Vector3(1.45, 0.96, 1.3), Palette.HOUSE_WALL)
	for x in [-0.72, 0.72]:
		for z in [-0.64, 0.64]:
			f.box(Vector3(x, 0.6, z), Vector3(0.09, 0.96, 0.09), Palette.WOOD_DARK)
	f.box(Vector3(0, 1.03, 0.66), Vector3(1.48, 0.07, 0.05), Palette.WOOD_DARK)
	f.box(Vector3(0, 1.03, -0.66), Vector3(1.48, 0.07, 0.05), Palette.WOOD_DARK)
	f.gable(Vector3(0, 1.07, 0), 0.9, 0.8, 0.74, Palette.TERRACOTTA, true, Palette.HOUSE_WALL.darkened(0.08))
	f.box(Vector3(0.45, 1.62, -0.3), Vector3(0.2, 0.6, 0.2), Palette.STONE, Palette.STONE_DARK)
	f.box(Vector3(-0.28, 0.42, 0.66), Vector3(0.3, 0.6, 0.05), Palette.WOOD_DARK)
	f.end_surface(ArtMaterials.base())
	f.box(Vector3(0.36, 0.7, 0.66), Vector3(0.26, 0.22, 0.05), Color.WHITE)
	f.box(Vector3(0.73, 0.7, 0.0), Vector3(0.05, 0.22, 0.26), Color.WHITE)
	f.box(Vector3(-0.73, 0.7, 0.0), Vector3(0.05, 0.22, 0.26), Color.WHITE)
	return f.commit(ArtMaterials.glow())


static func _farm() -> ArrayMesh:
	var f := MeshFactory.new()
	f.box(Vector3(0, 0.035, 0), Vector3(2.92, 0.07, 2.92), Palette.SOIL)
	for i in 6:
		var z := -1.2 + 0.48 * float(i)
		f.box(Vector3(0, 0.09, z), Vector3(2.6, 0.06, 0.22), Palette.SOIL_LIGHT)
		for j in 6:
			var x := -1.05 + 0.42 * float(j)
			f.cone(Vector3(x, 0.12, z), 0.08, 0.24, 5, Palette.CROP if (i + j) % 3 != 0 else Palette.CROP.darkened(0.15), false)
	for cx in [-1.42, 1.42]:
		for cz in [-1.42, 1.42]:
			f.box(Vector3(cx, 0.2, cz), Vector3(0.07, 0.4, 0.07), Palette.WOOD)
	return f.commit(ArtMaterials.base())


static func _storehouse() -> ArrayMesh:
	var f := MeshFactory.new()
	f.box(Vector3(0, 0.06, 0), Vector3(1.8, 0.12, 1.7), Palette.STONE_DARK)
	f.box(Vector3(0, 0.42, 0), Vector3(1.55, 0.6, 1.35), Palette.STONE)
	f.box(Vector3(0, 0.97, 0), Vector3(1.55, 0.5, 1.35), Palette.WOOD)
	for x in [-0.76, 0.76]:
		f.box(Vector3(x, 0.97, 0.66), Vector3(0.08, 0.5, 0.06), Palette.WOOD_DARK)
	f.gable(Vector3(0, 1.22, 0), 0.86, 0.8, 0.62, Palette.WOOD_DARK, false, Palette.WOOD)
	f.box(Vector3(0, 0.48, 0.68), Vector3(0.62, 0.72, 0.04), Palette.INK)
	f.box(Vector3(0.74, 0.28, 0.78), Vector3(0.32, 0.32, 0.32), Palette.WOOD_LIGHT, Palette.WOOD)
	f.box(Vector3(0.74, 0.58, 0.78), Vector3(0.26, 0.26, 0.26), Palette.WOOD, Palette.WOOD_LIGHT)
	f.cylinder(Vector3(-0.74, 0.12, 0.8), 0.14, 0.14, 0.36, 8, Palette.WOOD_DARK, true, false, Palette.WOOD_LIGHT)
	f.end_surface(ArtMaterials.base())
	f.box(Vector3(0.78, 0.97, -0.2), Vector3(0.05, 0.2, 0.24), Color.WHITE)
	return f.commit(ArtMaterials.glow())


## Scaffold posts and rails for a construction site of `size` tiles, `height` tall.
static func _scaffold(size: Vector2i, height: float) -> ArrayMesh:
	var f := MeshFactory.new()
	var hx := float(size.x) * 0.5 - 0.12
	var hz := float(size.y) * 0.5 - 0.12
	var h := maxf(height, 0.6)
	for cx in [-hx, hx]:
		for cz in [-hz, hz]:
			f.box(Vector3(cx, h * 0.5, cz), Vector3(0.07, h, 0.07), Palette.WOOD_LIGHT)
	for y in [h * 0.35, h * 0.7]:
		f.box(Vector3(0, y, hz), Vector3(hx * 2.0, 0.05, 0.05), Palette.WOOD)
		f.box(Vector3(0, y, -hz), Vector3(hx * 2.0, 0.05, 0.05), Palette.WOOD)
		f.box(Vector3(hx, y, 0), Vector3(0.05, 0.05, hz * 2.0), Palette.WOOD)
		f.box(Vector3(-hx, y, 0), Vector3(0.05, 0.05, hz * 2.0), Palette.WOOD)
	return f.commit(ArtMaterials.base())


## Bare earth under a construction site.
static func _plot(size: Vector2i) -> ArrayMesh:
	var f := MeshFactory.new()
	f.box(Vector3(0, 0.015, 0), Vector3(float(size.x) - 0.06, 0.03, float(size.y) - 0.06), Palette.SOIL_LIGHT)
	return f.commit(ArtMaterials.base())


# --- nature --------------------------------------------------------------------------------

static func _conifer() -> ArrayMesh:
	var f := MeshFactory.new()
	f.cylinder(Vector3.ZERO, 0.09, 0.07, 0.5, 6, Palette.TRUNK)
	f.cone(Vector3(0, 0.34, 0), 0.52, 0.95, 7, Palette.LEAF_DARK)
	f.cone(Vector3(0, 0.8, 0), 0.4, 0.8, 7, Palette.LEAF)
	f.cone(Vector3(0, 1.2, 0), 0.26, 0.7, 7, Palette.LEAF_LIGHT)
	return f.commit(ArtMaterials.base())


static func _broadleaf() -> ArrayMesh:
	var f := MeshFactory.new()
	f.cylinder(Vector3.ZERO, 0.1, 0.08, 0.62, 6, Palette.TRUNK)
	f.sphere(Vector3(0, 1.02, 0), 0.52, 4, 7, Palette.LEAF)
	f.sphere(Vector3(0.2, 1.3, 0.1), 0.34, 4, 6, Palette.LEAF_LIGHT)
	f.sphere(Vector3(-0.22, 0.9, -0.12), 0.3, 4, 6, Palette.LEAF_DARK)
	return f.commit(ArtMaterials.base())


static func _bush(berries: bool) -> ArrayMesh:
	var f := MeshFactory.new()
	var leaf := Palette.BUSH if berries else Palette.BUSH.lerp(Palette.SOIL, 0.35)
	var k := 1.0 if berries else 0.8
	f.sphere(Vector3(0, 0.22, 0), 0.3 * k, 4, 7, leaf, Vector3(1, 0.85, 1))
	f.sphere(Vector3(0.2, 0.17, 0.12), 0.22 * k, 3, 6, leaf.lightened(0.08))
	f.sphere(Vector3(-0.18, 0.16, -0.1), 0.2 * k, 3, 6, leaf.darkened(0.08))
	if berries:
		var spots: Array[Vector3] = [Vector3(0.15, 0.36, 0.2), Vector3(-0.1, 0.4, 0.18), Vector3(0.28, 0.22, 0.22),
			Vector3(-0.26, 0.26, 0.05), Vector3(0.05, 0.44, -0.12), Vector3(0.22, 0.3, -0.16), Vector3(-0.12, 0.28, -0.24)]
		for p in spots:
			f.box(p, Vector3(0.08, 0.08, 0.08), Palette.BERRY)
	return f.commit(ArtMaterials.base())


static func _stump() -> ArrayMesh:
	var f := MeshFactory.new()
	f.cylinder(Vector3.ZERO, 0.13, 0.11, 0.16, 6, Palette.TRUNK, true, false, Palette.WOOD_LIGHT)
	return f.commit(ArtMaterials.base())


static func _rock() -> ArrayMesh:
	var f := MeshFactory.new()
	f.sphere(Vector3(0, 0.12, 0), 0.42, 3, 6, Palette.ROCK, Vector3(1.0, 0.7, 0.85))
	f.sphere(Vector3(0.3, 0.06, 0.22), 0.2, 3, 5, Palette.ROCK.darkened(0.1), Vector3(1.0, 0.7, 1.0))
	return f.commit(ArtMaterials.base())


static func _stake(with_flag: bool) -> ArrayMesh:
	var f := MeshFactory.new()
	f.box(Vector3(0, 0.38, 0), Vector3(0.09, 0.76, 0.09), Palette.WOOD_LIGHT, Palette.WOOD)
	f.box(Vector3(0, 0.66, 0), Vector3(0.11, 0.1, 0.11), Palette.TERRACOTTA)
	f.box(Vector3(0, 0.55, 0), Vector3(0.11, 0.08, 0.11), Palette.HOUSE_WALL)
	if with_flag:
		f.box(Vector3(0, 0.95, 0), Vector3(0.04, 0.4, 0.04), Palette.WOOD_DARK)
		f.flag(Vector3(0.02, 1.14, 0), 0.4, 0.26, Palette.GOLD)
	return f.commit(ArtMaterials.base())


# --- units ---------------------------------------------------------------------------------

static func _townsfolk(variant: int) -> ArrayMesh:
	var f := MeshFactory.new()
	var tunic: Color = Palette.TUNICS[variant % Palette.TUNICS.size()]
	var hair: Color = Palette.HAIR[variant % Palette.HAIR.size()]
	f.cylinder(Vector3.ZERO, 0.16, 0.13, 0.32, 7, tunic.darkened(0.12))
	f.cylinder(Vector3(0, 0.3, 0), 0.14, 0.14, 0.05, 7, Palette.LEATHER)
	f.cylinder(Vector3(0, 0.33, 0), 0.13, 0.1, 0.2, 7, tunic)
	f.box(Vector3(0.155, 0.39, 0), Vector3(0.07, 0.22, 0.08), tunic)
	f.box(Vector3(-0.155, 0.39, 0), Vector3(0.07, 0.22, 0.08), tunic)
	f.sphere(Vector3(0, 0.63, 0), 0.105, 4, 7, Palette.SKIN)
	f.sphere(Vector3(0, 0.67, -0.015), 0.1, 3, 7, hair, Vector3(1.05, 0.75, 1.05))
	return f.commit(ArtMaterials.base())


static func _carry_wood() -> ArrayMesh:
	var f := MeshFactory.new()
	f.xform = Transform3D(Basis(Vector3(0, 0, 1), PI * 0.5), Vector3(0, 0.46, -0.16))
	f.cylinder(Vector3(0, -0.17, 0), 0.055, 0.055, 0.34, 6, Palette.TRUNK, true, true, Palette.WOOD_LIGHT)
	f.xform = Transform3D(Basis(Vector3(0, 0, 1), PI * 0.5), Vector3(0, 0.55, -0.15))
	f.cylinder(Vector3(0, -0.15, 0), 0.05, 0.05, 0.3, 6, Palette.TRUNK, true, true, Palette.WOOD_LIGHT)
	return f.commit(ArtMaterials.base())


static func _carry_food() -> ArrayMesh:
	var f := MeshFactory.new()
	f.cylinder(Vector3(0, 0.38, -0.17), 0.09, 0.11, 0.12, 7, Palette.WOOD_LIGHT, true, true, Palette.WOOD)
	f.box(Vector3(0.03, 0.51, -0.17), Vector3(0.07, 0.07, 0.07), Palette.BERRY)
	f.box(Vector3(-0.04, 0.52, -0.15), Vector3(0.07, 0.07, 0.07), Palette.BERRY)
	f.box(Vector3(0.0, 0.51, -0.21), Vector3(0.06, 0.06, 0.06), Palette.BERRY.darkened(0.15))
	return f.commit(ArtMaterials.base())
