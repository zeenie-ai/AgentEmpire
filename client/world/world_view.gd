class_name WorldView
extends Node3D
## The 3D town. Binds to a SimWorld and follows its signals: entity_spawned / entity_removed /
## entity_changed create, free and refresh views. Every frame, units are interpolated between
## ticks (Game.interp_alpha) and construction sites rise with their progress.
## Agent homes carry a HomeStatusView (name plate, approval bell, review chest, trouble), and
## Font Wisps in flight get a WispView.
## Graphics quality (Settings "graphics/quality") is applied here to the environment, the grass
## and the selection rings (decals on Forward+, a MultiMesh elsewhere).
## The town walls (WallView) stand for the current age; survey stakes mark the rings to come.
## While the Town Hall researches the next age, ResearchView shows it at the Keep and at the
## gates of the ring that will rise.
## When the age changes a ring rises with the handoff's animation (wall_rise_started lets the
## camera frame it), then the stakes move out to the next ring.
## World sounds go to the Audio autoload at their positions: hammering at construction sites,
## chopping and foraging at gatherers, drop-offs, and Font Wisps setting off.

## A town wall ring starts to rise: `center` and `radius` frame it, `seconds` is how long it takes.
signal wall_rise_started(ring: int, center: Vector3, radius: float, seconds: float)

const UNIT_RING := 0.42
const RING_UNIT := Color(0.663, 0.941, 0.816, 0.95)
const RING_BUILDING := Color(0.878, 0.71, 0.376, 0.95)
const RING_HOVER := Color(1.0, 1.0, 1.0, 0.45)
const MOTES_EXTENT := Vector3(24.0, 3.5, 18.0)
const MOTE_DAY := Color(1.0, 0.86, 0.55)
const MOTE_NIGHT := Color(0.62, 0.9, 1.0)
## A ring that stands within this many seconds of binding a town appears without a rise (the
## town was just loaded, or caught up with the Town Hall's age).
const RISE_AFTER_S := 1.5
## World sounds: seconds between hammer blows at a site, chops at a tree and handfuls at a bush
## or field (each with jitter), and how far from the point the camera looks at they are played.
const HAMMER_S := Vector2(0.5, 0.8)
const CHOP_S := Vector2(0.85, 1.15)
const FORAGE_S := Vector2(1.3, 1.9)
const SOUND_RANGE := 42.0
## Canvas layer of the agent homes' name plates: over the town, under the HUD (layer 10).
const PLATE_LAYER := 4

var world: SimWorld
var selection: Selection
## Entity under the cursor (0 for none), ringed faintly.
var hover_id: int = 0

var environment_view: SkyEnvironment
var ground: GroundView
var resources: ResourceFieldView
var stakes: SurveyStakes
var walls: WallView
var research: ResearchView
## Tools and tests: an age research to show instead of the Town Hall's ({} for none).
var research_override: Dictionary = {}
## SelectionRings or DecalRings: both take set_rings(entries).
var rings: Node3D
var ghost: PlacementGhost
var rally: RallyFlag
var floating: FloatingText
var motes: GeometryInstance3D
## Screen-space name plates of agent homes (NamePlate), under the HUD.
var plate_root: Control

var unit_views: Dictionary = {}
var building_views: Dictionary = {}
## Agent home building id -> HomeStatusView.
var home_views: Dictionary = {}
## Wisp id -> WispView.
var wisp_views: Dictionary = {}

var _units_root: Node3D
var _buildings_root: Node3D
var _time: float = 0.0
var _motes_material: StandardMaterial3D
## Seconds since the current town was bound.
var _bound_s: float = 0.0
## Sound clocks: site id or unit id -> seconds to the next sound.
var _site_sound: Dictionary = {}
var _unit_sound: Dictionary = {}
## Wisp id -> true once it has set off (its "wisp" cue played).
var _wisp_flying: Dictionary = {}
var _rng := RandomNumberGenerator.new()


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
	walls = WallView.new()
	walls.name = "Walls"
	add_child(walls)
	walls.rise_started.connect(_on_rise_started)
	walls.rise_finished.connect(_on_rise_finished)
	research = ResearchView.new()
	research.name = "Research"
	add_child(research)
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
	var plates := CanvasLayer.new()
	plates.name = "Plates"
	plates.layer = PLATE_LAYER
	add_child(plates)
	plate_root = Control.new()
	plate_root.name = "PlateRoot"
	plate_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plates.add_child(plate_root)
	plate_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	motes = Fx.motes(MOTES_EXTENT)
	motes.name = "Motes"
	_motes_material = (Fx.sprite_material(WorldTextures.soft_dot(), true).duplicate() as StandardMaterial3D)
	motes.material_override = _motes_material
	add_child(motes)
	_make_rings(GraphicsQuality.current())
	var settings := get_node_or_null("/root/Settings")
	if settings != null:
		settings.changed.connect(_on_setting_changed)
	var realm := get_node_or_null("/root/Realm")
	if realm != null:
		realm.task_changed.connect(_on_task_changed)


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
	walls.build(w)
	_bound_s = 0.0
	for b: SimBuilding in w.buildings.values():
		_add_building(b)
	for u: SimUnit in w.units.values():
		_add_unit(u)
	w.entity_spawned.connect(_on_spawned)
	w.entity_removed.connect(_on_removed)
	w.entity_changed.connect(_on_changed)
	w.notice.connect(_on_notice)
	w.walls_changed.connect(_on_walls_changed)
	research.bind(w, building_views.get(w.keep_id), plate_root)


func unbind() -> void:
	if world != null:
		world.entity_spawned.disconnect(_on_spawned)
		world.entity_removed.disconnect(_on_removed)
		world.entity_changed.disconnect(_on_changed)
		world.notice.disconnect(_on_notice)
		world.walls_changed.disconnect(_on_walls_changed)
	walls.clear()
	research.clear()
	_site_sound.clear()
	_unit_sound.clear()
	_wisp_flying.clear()
	for v: Node in unit_views.values():
		v.queue_free()
	for v: Node in building_views.values():
		v.queue_free()
	for v: Node in home_views.values():
		v.queue_free()
	for v: Node in wisp_views.values():
		v.queue_free()
	unit_views.clear()
	building_views.clear()
	home_views.clear()
	wisp_views.clear()
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
	if b.owner_agent_id != "" and b.tool_id == "":
		var hv := HomeStatusView.new()
		hv.name = "Home%d" % b.id
		_buildings_root.add_child(hv)
		hv.setup(b, v.height, v.model.get_meta("door", Vector3(0, 0.3, float(b.size.y) * 0.5)), plate_root)
		home_views[b.id] = hv


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
			if home_views.has(id):
				(home_views[id] as Node).queue_free()
				home_views.erase(id)
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
	if kind == "wanderer":
		var notify := get_node_or_null("/root/Notify")
		if notify != null:
			notify.call("push", "A wanderer has come to join your town.", "good", "wanderer", 5000)
		return
	if kind != "deposited" or int(data.get("amount", 0)) <= 0:
		return
	var b: SimBuilding = world.buildings.get(int(data.get("building", 0)))
	var at := Vector3.ZERO
	if b != null:
		at = Vector3(b.center().x, ModelLibrary.building_height(b.type) * 0.55 + 0.6, b.center().y)
		_sound("drop_off", Vector3(b.center().x, 0.5, b.center().y))
	var u: SimUnit = world.units.get(int(data.get("unit", 0)))
	if u != null:
		at = Vector3(u.pos.x, 1.4, u.pos.y)
	floating.spawn(at, "+%d" % int(data["amount"]), Palette.resource(String(data.get("res", ""))).lightened(0.25))


## A wall ring rose, fell, or opened or closed a gap. A ring that rises while the town runs plays
## the wall-rise (the stakes move out when it is done); otherwise it simply appears.
func _on_walls_changed(ring: int) -> void:
	var animate := _bound_s >= RISE_AFTER_S and ring < world.walls_up and not walls.rings.has(ring)
	walls.on_walls_changed(ring, animate)
	if not animate:
		stakes.build(world)
		_paint_walls()


func _on_rise_started(ring: int, center: Vector3, radius: float, seconds: float) -> void:
	wall_rise_started.emit(ring, center, radius, seconds)


func _on_rise_finished(_ring: int) -> void:
	if world == null:
		return
	stakes.build(world)
	_paint_walls()


func _paint_walls() -> void:
	if ground.mask == null:
		return
	for k in world.walls_up:
		ground.mask.paint_wall_ring(world, k)
	ground.mask.flush()


func _process(delta: float) -> void:
	if world == null:
		return
	_time += delta
	_bound_s += delta
	var alpha := Game.interp_alpha if Game.world == world else 1.0
	for id: int in unit_views:
		var u: SimUnit = world.units.get(id)
		if u != null:
			(unit_views[id] as UnitView).update_visual(u, alpha, _time, delta)
	for id: int in building_views:
		var b: SimBuilding = world.buildings.get(id)
		if b != null:
			(building_views[id] as BuildingView).update_visual(b, _time, delta)
	for id: int in home_views:
		var hv := home_views[id] as HomeStatusView
		hv.set_work_position(_work_position(hv.agent_id))
		hv.update_visual(_time, delta)
	_update_wisps(alpha)
	_update_rings(alpha)
	_update_motes()
	_update_sounds(delta)
	research.show_research(_research())
	research.update_visual(Time.get_unix_time_from_system(), delta, _time)


## The age research under way: the tools' override, else the Town Hall's (online towns only).
func _research() -> Dictionary:
	if not research_override.is_empty():
		return research_override
	var game := get_node_or_null("/root/Game")
	var realm := get_node_or_null("/root/Realm")
	if game == null or realm == null or not bool(game.call("is_online_town")):
		return {}
	return J.d(J.d(realm.get("age")).get("research"))


## Where an agent's add-on in use stands, or null when it works at none.
func _work_position(agent_id: String) -> Variant:
	var u := world.agent_unit(agent_id)
	if u == null or u.activity != "working" or u.work_tool == "":
		return null
	var t := AgentJob.tool_of_type(world, agent_id, u.work_tool)
	if t == null:
		return null
	return Vector3(t.center().x, 0.0, t.center().y)


func _update_wisps(alpha: float) -> void:
	var live := {}
	for wisp in world.wisps:
		var id := int(wisp["id"])
		live[id] = true
		if not wisp_views.has(id):
			var v := WispView.new()
			v.name = "Wisp%d" % id
			add_child(v)
			v.setup(id)
			wisp_views[id] = v
		(wisp_views[id] as WispView).update_visual(wisp, alpha, _time)
		if int(wisp["delay"]) <= 0 and not _wisp_flying.has(id):
			_wisp_flying[id] = true
			var p: Vector2 = wisp["pos"]
			_sound("wisp", Vector3(p.x, WispView.FLY_HEIGHT, p.y))
	for id: int in wisp_views.keys():
		if not live.has(id):
			(wisp_views[id] as Node).queue_free()
			wisp_views.erase(id)
			_wisp_flying.erase(id)


## An agent whose work was accepted cheers.
func _on_task_changed(t: Dictionary, before: String) -> void:
	if world == null or J.gs(t, "state") != "accepted" or before == "accepted":
		return
	var u := world.agent_unit(J.gs(t, "agent_id"))
	if u != null and unit_views.has(u.id):
		(unit_views[u.id] as UnitView).cheer()


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


# --- world sounds -----------------------------------------------------------------------------

## Hammering at construction sites while builders work, chopping and foraging at gatherers.
## Only near where the camera looks, each on its own jittered clock.
func _update_sounds(delta: float) -> void:
	var focus: Variant = _camera_focus()
	if focus == null:
		return
	var at: Vector2 = focus
	var sites := {}
	for u: SimUnit in world.units.values():
		if u.pos.distance_to(at) > SOUND_RANGE:
			continue
		if u.job == SimConst.JOB_BUILD and u.phase == BuildJob.BUILDING:
			sites[u.target_id] = true
		elif u.job == SimConst.JOB_GATHER and u.phase == GatherJob.GATHERING:
			var left := float(_unit_sound.get(u.id, _rng.randf_range(0.0, 0.6))) - delta
			if left <= 0.0:
				var chop := u.gather_kind == "tree"
				var span := CHOP_S if chop else FORAGE_S
				left = _rng.randf_range(span.x, span.y)
				_sound("chop" if chop else "gather_food", Vector3(u.pos.x, 0.6, u.pos.y))
			_unit_sound[u.id] = left
		elif _unit_sound.has(u.id):
			_unit_sound.erase(u.id)
	for id: int in _site_sound.keys():
		if not sites.has(id):
			_site_sound.erase(id)
	for id: int in sites:
		var b: SimBuilding = world.buildings.get(id)
		if b == null or b.complete:
			continue
		var left := float(_site_sound.get(id, _rng.randf_range(0.05, 0.3))) - delta
		if left <= 0.0:
			left = _rng.randf_range(HAMMER_S.x, HAMMER_S.y)
			_sound("construct_hit", Vector3(b.center().x, 0.5, b.center().y))
		_site_sound[id] = left


## The ground point at the centre of the view, as a Vector2, or null.
func _camera_focus() -> Variant:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return null
	var fwd := -cam.global_transform.basis.z
	if fwd.y > -0.05:
		return null
	var hit := cam.global_position + fwd * (cam.global_position.y / -fwd.y)
	return Vector2(hit.x, hit.z)


func _sound(cue: String, at: Vector3) -> void:
	var audio := get_node_or_null("/root/Audio")
	if audio != null and audio.has_method("play_at"):
		audio.call("play_at", cue, at)


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
