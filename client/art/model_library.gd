class_name ModelLibrary
extends RefCounted
## The boundary between game code and art. Views ask for models and meshes by key
## ("building/cottage", "node/tree_conifer", "unit/townsfolk", "carry/wood", "stage/a", ...).
## Each key maps to an art-manifest id (AssetCatalog). When the processed GLB exists under
## res://art it is used, otherwise the procedural model in the handoff palette is built, so the
## game runs with any subset of the art present (or none).
##
## Conventions (art_src/manifest.json): origin at the centre of the footprint on the ground
## (y = 0), +Y up, 1 unit = 1 tile, front facing +Z. Static GLBs hold one mesh node named
## "Mesh", which mesh() hands to MultiMesh views. Building models carry meta "height"
## (construction rise, picking), "door", "top" and "chimney" points (anchors.json when present)
## and may hold a "Font" node (the Keep's spinning ring).

const HEIGHTS := {"keep": 6.3, "cottage": 1.85, "farm": 0.4, "storehouse": 1.85}
## Procedural door and chimney points (model space).
const PROC_DOORS := {"keep": Vector3(0, 0.3, 1.45), "cottage": Vector3(-0.28, 0.3, 0.75), "storehouse": Vector3(0, 0.3, 0.75)}
const PROC_CHIMNEYS := {"cottage": Vector3(0.45, 1.93, -0.3), "keep": Vector3(0.55, 3.2, -0.55)}
## Kit atlas cells (u0, v0, u1, v1) that glow at night as windows, per building id. The KayKit
## medieval atlas is 8 x 4 swatches; houses glaze their windows with swatch (6, 1).
const WINDOW_CELLS := {
	"cottage": Vector4(0.75, 0.25, 0.875, 0.5),
	"storehouse": Vector4(0.75, 0.25, 0.875, 0.5),
	"keep": Vector4(0.375, 0.0, 0.5, 0.25),
}
## Kit shader profile for characters: a touch of rim light and softer shading for readability.
const CHARACTER_PROFILE := {"rim": 0.28, "wrap": 0.35, "saturation": 1.12}
## Foliage: softer light through the leaves and a calmer green that sits with the meadow.
const FOLIAGE_PROFILE := {"saturation": 0.84, "wrap": 0.4}

## Look-dev hook (tools only, never set by the game): an object with
## variant_count(id: String) -> int, make(id: String, variant: int) -> Node3D and
## make_character(kind: String, variant: int) -> Node3D, used when no file exists.
static var preview: Object = null

static var _meshes: Dictionary = {}
static var _scenes: Dictionary = {}
## Building heights by type, and chimney points by art stem ("chimney:<stem>").
static var _heights: Dictionary = {}


static func clear_cache() -> void:
	_meshes.clear()
	_scenes.clear()
	_heights.clear()
	AssetCatalog.clear_cache()


## True when `key` is drawn from art files (or the look-dev preview) rather than procedurally.
static func has_art(key: String) -> bool:
	return variant_count_art(key) > 0


## Number of art variants for `key` (0 when it is procedural).
static func variant_count_art(key: String) -> int:
	var n := AssetCatalog.model_paths(key).size()
	if n == 0 and preview != null:
		n = int(preview.call("variant_count", AssetCatalog.id_for(key)))
	return n


## Number of variants mesh(key, i) offers (at least 1).
static func variant_count(key: String) -> int:
	return maxi(variant_count_art(key), 1)


## A fresh model node for `key`: "building/<type>", "unit/<kind>", or any prop key.
static func instance(key: String, variant: int = 0) -> Node3D:
	var parts := key.split("/")
	match parts[0]:
		"building":
			return _building(parts[1] if parts.size() > 1 else "", variant)
		"unit":
			return character(parts[1] if parts.size() > 1 else "townsfolk", variant)
	var root := Node3D.new()
	root.name = key.get_slice("/", 1).to_pascal_case()
	var art := _make(key, variant)
	if art != null:
		art.name = "Body"
		KitMaterials.apply(art)
		root.add_child(art)
		root.set_meta("from_art", true)
	else:
		_add(root, "Body", mesh(key))
	return root


## A construction stage model ("stage/a", "stage/b", "stage/c", "stage/scaffolding") from the
## art files, or null when there is none (BuildingView then uses its procedural site).
static func stage(key: String) -> Node3D:
	var art := _make(key, 0)
	if art != null:
		KitMaterials.apply(art)
	return art


## A unit figure. From art: the character GLB with its Skeleton3D and AnimationPlayer (meta
## "rigged"). Procedural: Body/Mesh with CarryWood and CarryFood children.
static func character(kind: String, variant: int) -> Node3D:
	var root := Node3D.new()
	root.name = kind.to_pascal_case()
	var art: Node3D = null
	var paths := AssetCatalog.character_paths(kind)
	if not paths.is_empty():
		art = _instantiate(paths[posmod(variant, paths.size())])
	elif preview != null:
		art = preview.call("make_character", kind, variant)
	if art != null:
		art.name = "Rig"
		KitMaterials.apply(art, CHARACTER_PROFILE)
		root.add_child(art)
		root.set_meta("rigged", true)
		return root
	var body := Node3D.new()
	body.name = "Body"
	root.add_child(body)
	_add(body, "Mesh", mesh("unit/townsfolk/%d" % posmod(variant, Palette.TUNICS.size())))
	var wood := _add(body, "CarryWood", mesh("carry/wood_back"))
	var food := _add(body, "CarryFood", mesh("carry/food_back"))
	wood.visible = false
	food.visible = false
	return root


static func building_height(type: String) -> float:
	if _heights.has(type):
		return _heights[type]
	var h := float(HEIGHTS.get(type, 2.0))
	var art := _make("building/" + type, 0)
	if art != null:
		var rec := AssetCatalog.anchor(String(art.get_meta("art_stem", "")))
		h = float(rec.get("height", aabb_of(art).end.y))
		art.free()
	_heights[type] = h
	return h


## A cached mesh for `key` (variant `variant`), for MultiMesh views: the single "Mesh" of the
## art GLB with the kit material, or the procedural mesh.
static func mesh(key: String, variant: int = 0) -> Mesh:
	var ck := "%s#%d" % [key, variant]
	if _meshes.has(ck):
		return _meshes[ck]
	var m: Mesh = null
	if AssetCatalog.id_for(key) != "":
		var art := _make(key, variant)
		if art != null:
			m = _single_mesh(art, FOLIAGE_PROFILE if key.begins_with("node/") else {})
			art.free()
			if m != null and key == "decor/stake_flag":
				m = _with_flag(m)
	if m == null:
		var pk := key + "#proc"
		if not _meshes.has(pk):
			_meshes[pk] = _build(key)
		m = _meshes[pk]
	_meshes[ck] = m
	return m


## Every variant mesh of `key` (one procedural mesh when there is no art).
static func meshes(key: String) -> Array[Mesh]:
	var out: Array[Mesh] = []
	for i in variant_count(key):
		out.append(mesh(key, i))
	return out


## Bounds of every mesh under `root`, in root space.
static func aabb_of(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var list: Array[Node] = root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		list.append(root)
	for n in list:
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var box := _relative(mi, root) * mi.mesh.get_aabb()
		out = box if first else out.merge(box)
		first = false
	return out


# --- art ------------------------------------------------------------------------------------

## An instance of the art model for `key` (file first, then the look-dev preview), with meta
## "art_stem" naming its file stem for anchors; null when there is none.
static func _make(key: String, variant: int) -> Node3D:
	var paths := AssetCatalog.model_paths(key)
	if not paths.is_empty():
		var path := paths[posmod(variant, paths.size())]
		var n := _instantiate(path)
		if n != null:
			n.set_meta("art_stem", AssetCatalog.stem(path))
			return n
	if preview != null:
		var id := AssetCatalog.id_for(key)
		var count := int(preview.call("variant_count", id))
		if count > 0:
			var v := posmod(variant, count)
			var p: Node3D = preview.call("make", id, v)
			if p != null:
				p.set_meta("art_stem", id if count == 1 else "%s_%d" % [id, v])
				return p
	return null


static func _instantiate(path: String) -> Node3D:
	var res: Variant = null
	if _scenes.has(path):
		res = _scenes[path]
	else:
		res = AssetCatalog.loader.call(path)
		_scenes[path] = res
	if res is PackedScene:
		return (res as PackedScene).instantiate() as Node3D
	return null


## The node named "Mesh" (or the first mesh) as a standalone mesh in model space, with kit
## materials on its surfaces.
static func _single_mesh(root: Node3D, profile: Dictionary = {}) -> Mesh:
	var mi := root.find_child("Mesh", true, false) as MeshInstance3D
	if mi == null:
		if root is MeshInstance3D:
			mi = root
		else:
			var all := root.find_children("*", "MeshInstance3D", true, false)
			if all.is_empty():
				return null
			mi = all[0]
	if mi.mesh == null:
		return null
	var xf := _relative(mi, root)
	var out := ArrayMesh.new()
	for s in mi.mesh.get_surface_count():
		var st := SurfaceTool.new()
		st.append_from(mi.mesh, s, xf)
		st.commit(out)
		var has_colors := KitMaterials.mesh_has_colors(mi.mesh, s)
		var mat := KitMaterials.converted(mi.get_active_material(s), profile, has_colors)
		out.surface_set_material(s, mat if mat != null else mi.get_active_material(s))
	return out


## `node`'s transform relative to `root` (works outside the scene tree).
static func _relative(node: Node3D, root: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


## The art stake with a gold survey flag on top (the build-zone ring).
static func _with_flag(stake: Mesh) -> Mesh:
	var top := stake.get_aabb().end.y
	var f := MeshFactory.new()
	f.box(Vector3(0, top + 0.18, 0), Vector3(0.035, 0.36, 0.035), Palette.WOOD_DARK)
	f.flag(Vector3(0.02, top + 0.34, 0), 0.34, 0.22, Palette.GOLD)
	var flag := f.commit(KitMaterials.vertex_colored())
	var out := stake.duplicate() as ArrayMesh
	if out == null:
		return stake
	var arrays := flag.surface_get_arrays(0)
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	out.surface_set_material(out.get_surface_count() - 1, KitMaterials.vertex_colored())
	return out


static func _building(type: String, variant: int) -> Node3D:
	var root := Node3D.new()
	root.name = type.to_pascal_case()
	var height := float(HEIGHTS.get(type, 2.0))
	var art := _make("building/" + type, variant)
	if art != null:
		art.name = "Body"
		var profile := {}
		if WINDOW_CELLS.has(type):
			profile["glow_cell_a"] = WINDOW_CELLS[type]
		KitMaterials.apply(art, profile)
		root.add_child(art)
		var rec := AssetCatalog.anchor(String(art.get_meta("art_stem", "")))
		var box := aabb_of(art)
		height = float(rec.get("height", box.end.y))
		root.set_meta("door", AssetCatalog.anchor_point(rec, "door", Vector3(0, 0.3, box.end.z)))
		root.set_meta("top", AssetCatalog.anchor_point(rec, "top", Vector3(0, box.end.y, 0)))
		var stem_key := "chimney:" + String(art.get_meta("art_stem", type))
		if not _heights.has(stem_key):
			_heights[stem_key] = AssetCatalog.anchor_point(rec, "chimney", Vector3.ZERO) if rec.has("chimney") else _find_chimney(art, box)
		var chimney: Variant = _heights[stem_key]
		if chimney != null:
			root.set_meta("chimney", chimney)
		root.set_meta("from_art", true)
	else:
		_add(root, "Body", mesh("building/" + type))
		root.set_meta("door", PROC_DOORS.get(type, Vector3(0, 0.3, 0.7)))
		root.set_meta("top", Vector3(0, height, 0))
		if PROC_CHIMNEYS.has(type):
			root.set_meta("chimney", PROC_CHIMNEYS[type])
	root.set_meta("height", height)
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
		font.position = Vector3(0, height + 0.9, 0)
		font.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(font)
	if type == "keep" and not root.has_meta("chimney"):
		root.set_meta("chimney", PROC_CHIMNEYS["keep"] * Vector3(1, height / 6.3, 1))
	return root


## Kit houses: the chimney is the highest part drawn with the dark stone swatch (3, 0) that
## stands off-centre; null when the model has none.
static func _find_chimney(root: Node3D, box: AABB) -> Variant:
	var best := Vector3.ZERO
	var found := false
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := _relative(mi, root)
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var uvs: Variant = arr[Mesh.ARRAY_TEX_UV]
			if uvs == null:
				continue
			var uv: PackedVector2Array = uvs
			for i in verts.size():
				var u := uv[i]
				if u.x < 0.375 or u.x > 0.5 or u.y > 0.25:
					continue
				var p := xf * verts[i]
				if p.y > best.y:
					best = p
					found = true
	if not found or best.y < box.end.y * 0.7:
		return null
	if Vector2(best.x, best.z).length() < 0.1:
		return null
	return best + Vector3(0, 0.05, 0)


static func _add(parent: Node3D, node_name: String, m: Mesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = m
	parent.add_child(mi)
	return mi


# --- procedural fallback ------------------------------------------------------------------------

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
		"decor/mountain":
			return _mountain(0)
		"fx/ring":
			var f := MeshFactory.new()
			f.ring_flat(Vector3.ZERO, 0.84, 1.0, 40, Color.WHITE)
			return f.commit(ArtMaterials.ring())
		"carry/wood":
			return _carry_wood(false)
		"carry/food":
			return _carry_food(false)
		"carry/wood_back":
			return _carry_wood(true)
		"carry/food_back":
			return _carry_food(true)
	if parts.size() == 3 and parts[0] == "unit":
		return _townsfolk(int(parts[2]))
	if parts.size() == 4 and parts[0] == "scaffold":
		return _scaffold(Vector2i(int(parts[1]), int(parts[2])), float(parts[3]) / 100.0)
	if parts.size() == 3 and parts[0] == "plot":
		return _plot(Vector2i(int(parts[1]), int(parts[2])))
	if parts.size() == 3 and parts[0] == "decor" and parts[1] == "mountain":
		return _mountain(int(parts[2]))
	if parts.size() == 2 and parts[0] == "wall":
		return _wall_piece(parts[1])
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


# --- town walls ----------------------------------------------------------------------------

## Procedural wall pieces, normalised like the art: curtains 1 thick with battlements on the
## field side (+Z), towers with a shaft 1 across, the gate with an opening 1 wide.
static func _wall_piece(kind: String) -> ArrayMesh:
	var f := MeshFactory.new()
	var s := Palette.STONE
	var dark := Palette.STONE_DARK
	match kind:
		"curtain", "curtain_tall":
			var base := 0.35 if kind == "curtain_tall" else 0.0
			if base > 0.0:
				f.box(Vector3(0, base * 0.5, 0), Vector3(2.5, base, 1.2), dark)
			f.box(Vector3(0, base + 0.6, 0), Vector3(2.5, 1.2, 1.0), s, Palette.TERRACOTTA)
			for i in 4:
				f.box(Vector3(-0.94 + 0.625 * float(i), base + 1.33, 0.38), Vector3(0.36, 0.26, 0.24), s)
		"gate":
			for x in [-0.86, 0.86]:
				f.box(Vector3(x, 0.75, 0), Vector3(0.5, 1.5, 1.05), s)
			f.box(Vector3(0, 1.32, 0), Vector3(2.22, 0.36, 1.05), s, Palette.TERRACOTTA)
			f.box(Vector3(-0.38, 0.45, -0.3), Vector3(0.06, 0.88, 0.5), Palette.WOOD_DARK)
			f.box(Vector3(0.38, 0.45, -0.3), Vector3(0.06, 0.88, 0.5), Palette.WOOD_DARK)
		_:
			var h := {"tower_squat": 1.1, "tower": 1.6, "tower_roofed": 1.75, "tower_spire": 1.9, "tower_catapult": 1.6}.get(kind, 1.6) as float
			f.cylinder(Vector3.ZERO, 0.52, 0.5, h, 8, s, true, false, Palette.TERRACOTTA)
			for i in 8:
				var a := TAU * float(i) / 8.0
				f.box(Vector3(cos(a) * 0.45, h + 0.09, sin(a) * 0.45), Vector3(0.16, 0.18, 0.16), s)
			if kind == "tower_roofed" or kind == "tower_spire":
				f.cone(Vector3(0, h, 0), 0.62, 0.75 if kind == "tower_roofed" else 1.0, 8, Palette.SLATE)
			f.box(Vector3(0, 0.22, 0.5), Vector3(0.22, 0.44, 0.06), Palette.WOOD_DARK)
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


## A low-poly mountain about 12 units across: a noisy cone with grassy flanks, grey rock above
## and, on the taller variants, a pale cap. Variant picks the shape.
static func _mountain(variant: int) -> ArrayMesh:
	var f := MeshFactory.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7919 * (variant + 1)
	var rings := 5
	var segs := 11
	var heights: Array[float] = [7.5, 9.5, 6.0]
	var height := heights[posmod(variant, 3)]
	var radius := 6.0
	var pts: Array = []
	for r in rings + 1:
		var t := float(r) / float(rings)
		var row: Array[Vector3] = []
		for s in segs:
			var a := TAU * float(s) / float(segs) + rng.randf_range(-0.12, 0.12)
			var rad := radius * (1.0 - t) * rng.randf_range(0.82, 1.12)
			var y := height * pow(t, 0.85) * rng.randf_range(0.9, 1.08) if r > 0 else 0.0
			if r == rings:
				rad = 0.0
			row.append(Vector3(cos(a) * rad, y, sin(a) * rad))
		pts.append(row)
	var grass := Color("#6f8a45")
	var grass_dark := Color("#58703a")
	var rock := Color("#8d8a86")
	var rock_dark := Color("#6f6c6a")
	var snow := Color("#f1ece2")
	var inner := Vector3(0, height * 0.3, 0)
	for r in rings:
		for s in segs:
			var a: Vector3 = pts[r][s]
			var b: Vector3 = pts[r][(s + 1) % segs]
			var c: Vector3 = pts[r + 1][(s + 1) % segs]
			var d: Vector3 = pts[r + 1][s]
			var hmid := (a.y + c.y) * 0.5 / height
			var col: Color
			if hmid < 0.3:
				col = grass if (s + r) % 2 == 0 else grass_dark
			elif hmid < 0.72 or height < 7.0:
				col = rock if (s + r) % 3 != 0 else rock_dark
			else:
				col = snow
			if r == rings - 1:
				f.tri(a, b, c, col, inner)
			else:
				f.quad(a, b, c, d, col, inner)
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


## Two logs. On the back of a procedural figure, or centred (for a hand attachment).
static func _carry_wood(on_back: bool) -> ArrayMesh:
	var f := MeshFactory.new()
	var o := Vector3(0, 0.46, -0.16) if on_back else Vector3(0, 0.0, 0.0)
	f.xform = Transform3D(Basis(Vector3(0, 0, 1), PI * 0.5), o)
	f.cylinder(Vector3(0, -0.17, 0), 0.055, 0.055, 0.34, 6, Palette.TRUNK, true, true, Palette.WOOD_LIGHT)
	f.xform = Transform3D(Basis(Vector3(0, 0, 1), PI * 0.5), o + Vector3(0, 0.09, 0.01))
	f.cylinder(Vector3(0, -0.15, 0), 0.05, 0.05, 0.3, 6, Palette.TRUNK, true, true, Palette.WOOD_LIGHT)
	return f.commit(ArtMaterials.base())


## A basket of berries. On the back of a procedural figure, or centred.
static func _carry_food(on_back: bool) -> ArrayMesh:
	var f := MeshFactory.new()
	var o := Vector3(0, 0.38, -0.17) if on_back else Vector3.ZERO
	f.cylinder(o, 0.09, 0.11, 0.12, 7, Palette.WOOD_LIGHT, true, true, Palette.WOOD)
	f.box(o + Vector3(0.03, 0.13, 0.0), Vector3(0.07, 0.07, 0.07), Palette.BERRY)
	f.box(o + Vector3(-0.04, 0.14, 0.02), Vector3(0.07, 0.07, 0.07), Palette.BERRY)
	f.box(o + Vector3(0.0, 0.13, -0.04), Vector3(0.06, 0.06, 0.06), Palette.BERRY.darkened(0.15))
	return f.commit(ArtMaterials.base())
