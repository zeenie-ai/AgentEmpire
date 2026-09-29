class_name WorldView
extends Node3D
## The 3D town. Binds to a SimWorld and follows its signals: entity_spawned / entity_removed /
## entity_changed create, free and refresh views. Every frame, units are interpolated between
## ticks (Game.interp_alpha) and construction sites rise with their progress.
## Graphics quality (Settings "graphics/quality") is applied here to the environment, the grass
## and the selection rings (decals on Forward+, a MultiMesh elsewhere).

const UNIT_RING := 0.42
const RING_UNIT := Color(0.663, 0.941, 0.816, 0.95)
const RING_BUILDING := Color(0.878, 0.71, 0.376, 0.95)
const RING_HOVER := Color(1.0, 1.0, 1.0, 0.45)
const MOTES_EXTENT := Vector3(24.0, 3.5, 18.0)
const MOTE_DAY := Color(1.0, 0.86, 0.55)
const MOTE_NIGHT := Color(0.62, 0.9, 1.0)

var world: SimWorld
var selection: Selection
## Entity under the cursor (0 for none), ringed faintly.
var hover_id: int = 0

var environment_view: SkyEnvironment
var ground: GroundView
var resources: ResourceFieldView
var stakes: SurveyStakes
## SelectionRings or DecalRings: both take set_rings(entries).
var rings: Node3D
var ghost: PlacementGhost
var rally: RallyFlag
var floating: FloatingText
var motes: GeometryInstance3D

var unit_views: Dictionary = {}
var building_views: Dictionary = {}

var _units_root: Node3D
var _buildings_root: Node3D
var _time: float = 0.0
var _motes_material: StandardMaterial3D


func _ready() -> void:
	environment_view = SkyEnvironment.new()
	environment_view.name = "Environment"
	add_child(environment_view)
	ground = GroundView.new()
	ground.name = "Ground"
	add_child(ground)
	resources = ResourceFieldView.new()
	resources.name = "Resources"
	add_child(resources)
	stakes = SurveyStakes.new()
	stakes.name = "SurveyStakes"
	add_child(stakes)
	_buildings_root = Node3D.new()
	_buildings_root.name = "Buildings"
	add_child(_buildings_root)
	_units_root = Node3D.new()
	_units_root.name = "Units"
	add_child(_units_root)
	ghost = PlacementGhost.new()
	ghost.name = "PlacementGhost"
	ghost.visible = false
	add_child(ghost)
	rally = RallyFlag.new()
	rally.name = "RallyFlag"
	add_child(rally)
	floating = FloatingText.new()
	floating.name = "FloatingText"
	add_child(floating)
	motes = Fx.motes(MOTES_EXTENT)
	motes.name = "Motes"
	_motes_material = (Fx.sprite_material(WorldTextures.soft_dot(), true).duplicate() as StandardMaterial3D)
	motes.material_override = _motes_material
	add_child(motes)
	_make_rings(GraphicsQuality.current())
	var settings := get_node_or_null("/root/Settings")
	if settings != null:
		settings.changed.connect(_on_setting_changed)


func _on_setting_changed(key: String, _value: Variant) -> void:
	if key == GraphicsQuality.SETTING:
		apply_quality(GraphicsQuality.current())


## Applies a graphics preset to everything in the world.
func apply_quality(q: Dictionary) -> void:
	environment_view.apply_quality(q)
	ground.apply_quality(q)
	_make_rings(q)


func _make_rings(q: Dictionary) -> void:
	var want_decals := GraphicsQuality.use_decals(q)
	if rings != null:
		if (rings is DecalRings) == want_decals:
			return
		rings.queue_free()
	rings = DecalRings.new() if want_decals else SelectionRings.new()
	rings.name = "SelectionRings"
	add_child(rings)


func bind(w: SimWorld) -> void:
	unbind()
	world = w
	ground.build(w)
	resources.build(w)
	stakes.build(w)
	for b: SimBuilding in w.buildings.values():
		_add_building(b)
	for u: SimUnit in w.units.values():
		_add_unit(u)
	w.entity_spawned.connect(_on_spawned)
	w.entity_removed.connect(_on_removed)
	w.entity_changed.connect(_on_changed)
	w.notice.connect(_on_notice)


func unbind() -> void:
	if world != null:
		world.entity_spawned.disconnect(_on_spawned)
		world.entity_removed.disconnect(_on_removed)
		world.entity_changed.disconnect(_on_changed)
		world.notice.disconnect(_on_notice)
	for v: Node in unit_views.values():
		v.queue_free()
	for v: Node in building_views.values():
		v.queue_free()
	unit_views.clear()
	building_views.clear()
	world = null


func _add_unit(u: SimUnit) -> void:
	var v := UnitView.new()
	v.name = "Unit%d" % u.id
	_units_root.add_child(v)
	v.setup(u)
	unit_views[u.id] = v


func _add_building(b: SimBuilding) -> void:
	var v := BuildingView.new()
	v.name = "%s%d" % [b.type.capitalize(), b.id]
	_buildings_root.add_child(v)
	v.setup(b)
	building_views[b.id] = v


func _on_spawned(id: int, category: String) -> void:
	match category:
		SimWorld.CAT_UNIT:
			_add_unit(world.units[id])
		SimWorld.CAT_BUILDING:
			_add_building(world.buildings[id])
			ground.building_added(world.buildings[id])
		SimWorld.CAT_NODE:
			resources.refresh(id)


func _on_removed(id: int, category: String) -> void:
	match category:
		SimWorld.CAT_UNIT:
			if unit_views.has(id):
				(unit_views[id] as Node).queue_free()
				unit_views.erase(id)
		SimWorld.CAT_BUILDING:
			if building_views.has(id):
				(building_views[id] as Node).queue_free()
				building_views.erase(id)
		SimWorld.CAT_NODE:
			resources.refresh(id)


func _on_changed(id: int, category: String) -> void:
	match category:
		SimWorld.CAT_BUILDING:
			if building_views.has(id) and world.buildings.has(id):
				var bv := building_views[id] as BuildingView
				var was_complete := bv.complete
				bv.refresh(world.buildings[id])
				if bv.complete and not was_complete:
					for v: UnitView in unit_views.values():
						if v.last_build_target == id:
							v.cheer()
		SimWorld.CAT_NODE:
			resources.refresh(id)


func _on_notice(kind: String, data: Dictionary) -> void:
	if kind != "deposited" or int(data.get("amount", 0)) <= 0:
		return
	var b: SimBuilding = world.buildings.get(int(data.get("building", 0)))
	var at := Vector3.ZERO
	if b != null:
		at = Vector3(b.center().x, ModelLibrary.building_height(b.type) * 0.55 + 0.6, b.center().y)
	var u: SimUnit = world.units.get(int(data.get("unit", 0)))
	if u != null:
		at = Vector3(u.pos.x, 1.4, u.pos.y)
	floating.spawn(at, "+%d" % int(data["amount"]), Palette.resource(String(data.get("res", ""))).lightened(0.25))


func _process(delta: float) -> void:
	if world == null:
		return
	_time += delta
	var alpha := Game.interp_alpha if Game.world == world else 1.0
	for id: int in unit_views:
		var u: SimUnit = world.units.get(id)
		if u != null:
			(unit_views[id] as UnitView).update_visual(u, alpha, _time, delta)
	for id: int in building_views:
		var b: SimBuilding = world.buildings.get(id)
		if b != null:
			(building_views[id] as BuildingView).update_visual(b, _time, delta)
	_update_rings(alpha)
	_update_motes()


## Pollen drifts in a box around the point the camera looks at.
func _update_motes() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or motes == null:
		return
	var fwd := -cam.global_transform.basis.z
	if fwd.y < -0.05:
		var t := cam.global_position.y / -fwd.y
		var focus := cam.global_position + fwd * t
		motes.global_position = Vector3(focus.x, MOTES_EXTENT.y + 0.3, focus.z)
	var n := ArtMaterials.night_amount()
	_motes_material.albedo_color = MOTE_DAY.lerp(MOTE_NIGHT, n) * Color(1, 1, 1, lerpf(0.55, 0.9, n))


## Order feedback: a ring that shrinks and fades where the order went.
func ping(cell: Vector2i, action: String) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = ModelLibrary.mesh("fx/ring")
	var mat := ArtMaterials.ring().duplicate() as StandardMaterial3D
	mat.vertex_color_use_as_albedo = false
	mat.albedo_color = RING_UNIT if action == RightClickRules.ACTION_MOVE else RING_BUILDING
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(cell.x + 0.5, 0.05, cell.y + 0.5)
	add_child(mi)
	var tw := mi.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3(0.15, 1.0, 0.15), 0.45).from(Vector3(0.7, 1.0, 0.7))
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.45)
	tw.chain().tween_callback(mi.queue_free)


## Where a unit is drawn right now (interpolated).
func unit_visual_position(id: int) -> Vector3:
	var u: SimUnit = world.units.get(id) if world != null else null
	if u == null:
		return Vector3.ZERO
	var alpha := Game.interp_alpha if Game.world == world else 1.0
	return UnitView.visual_pos(u, alpha)


func _update_rings(alpha: float) -> void:
	var entries: Array = []
	var keep_rally := Pathing.NO_CELL
	if selection != null:
		for id in selection.ids:
			_ring_for(id, alpha, entries, RING_UNIT, RING_BUILDING)
			var b: SimBuilding = world.buildings.get(id)
			if b != null and selection.ids.size() == 1 and not b.rally.is_empty():
				keep_rally = Vector2i(int(b.rally["x"]), int(b.rally["y"]))
	if hover_id != 0 and (selection == null or not selection.has(hover_id)):
		_ring_for(hover_id, alpha, entries, RING_HOVER, RING_HOVER)
	rings.call("set_rings", entries)
	if keep_rally != Pathing.NO_CELL:
		rally.show_at(keep_rally)
	else:
		rally.visible = false


func _ring_for(id: int, alpha: float, entries: Array, unit_col: Color, building_col: Color) -> void:
	var u: SimUnit = world.units.get(id)
	if u != null:
		entries.append([UnitView.visual_pos(u, alpha), UNIT_RING, unit_col])
		return
	var b: SimBuilding = world.buildings.get(id)
	if b != null:
		var c := b.center()
		entries.append([Vector3(c.x, 0, c.y), float(maxi(b.size.x, b.size.y)) * 0.5 + 0.35, building_col])
		return
	var n: SimResourceNode = world.nodes.get(id)
	if n != null and n.is_live():
		var nc := n.center()
		entries.append([Vector3(nc.x, 0, nc.y), 0.6, building_col])
