class_name HomeStatusView
extends Node3D
## What an agent's home shows the player, readable from across the town:
## - a name plate (the agent's name, role and rank), tinted by what the agent is doing;
## - a signal post beside the entrance: its hand bell swings and glows and a banner is raised
##   while an approval waits (blue once a Mana seal ran out), since approvals are what the
##   player must answer;
## - a chest glowing at the door when a result waits for review;
## - smoke from the roof after a failed task, a red mark while the agent is blocked;
## - a warm pulse of light at the add-on the agent is working at;
## - flagged stakes at the corners of its plot.
## It reads Realm a few times a second; the home's BuildingView knows nothing about it.

const REFRESH_S := 0.25
const PLATE_PIXEL := 0.0085
## The blocked mark floats above the name plate so no roof hides it.
const MARKER_ABOVE := 1.75
## The chest and the signal post flank the entrance path (home-centre space).
const CHEST_AT := Vector3(1.05, 0.0, 2.05)
const POST_AT := Vector3(-1.05, 0.0, 2.0)
const POST_HEIGHT := 2.2
const BANNER_YELLOW := Color("#e8b73a")
const BANNER_BLUE := Color("#4f8fe0")
const COLOR_IDLE := Color("#f3e6c8")
const COLOR_WORKING := Color("#a9f0d0")
const COLOR_WAITING := Color("#ffd27a")
const COLOR_BAD := Color("#ec6a52")
const COLOR_SEAL := Color("#8fc8ff")

var agent_id: String = ""
var building_id: int = 0

var _roof: float = 2.0
var _door: Vector3 = Vector3.ZERO
var _name: Label3D
var _sub: Label3D
var _post: Node3D
var _bell: Node3D
var _bell_mat: StandardMaterial3D
var _bell_light: OmniLight3D
var _banner: MeshInstance3D
var _banner_mat: StandardMaterial3D
var _chest: Node3D
var _chest_light: OmniLight3D
var _smoke: GeometryInstance3D
var _mark: Label3D
var _work_light: OmniLight3D
var _stakes: Array[Node3D] = []
var _timer: float = 0.0
var _flags: Dictionary = {}
var _work_pos: Variant = null


func setup(b: SimBuilding, height: float, door: Vector3) -> void:
	agent_id = b.owner_agent_id
	building_id = b.id
	position = Vector3(b.center().x, 0.0, b.center().y)
	_roof = maxf(height, 1.4)
	_door = door
	_build_plate()
	_build_bell()
	_build_chest()
	_build_mark()
	_work_light = OmniLight3D.new()
	_work_light.light_color = Color(1.0, 0.8, 0.45)
	_work_light.omni_range = 3.2
	_work_light.shadow_enabled = false
	_work_light.visible = false
	add_child(_work_light)
	_place_stakes(b.plot)
	refresh()


func _build_plate() -> void:
	_name = _label(64, UiFonts.cinzel(700, 1))
	_name.position = Vector3(0, _roof + 1.05, 0)
	_sub = _label(40, UiFonts.mono(500, 1))
	_sub.position = Vector3(0, _roof + 0.62, 0)
	_sub.modulate = Color(1, 1, 1, 0.85)


func _label(size: int, font: Font) -> Label3D:
	var l := Label3D.new()
	l.font = font
	l.font_size = size
	l.pixel_size = PLATE_PIXEL
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.outline_size = 14
	l.outline_modulate = Color(0.08, 0.05, 0.03, 0.9)
	l.modulate = COLOR_IDLE
	l.no_depth_test = true
	l.render_priority = 2
	l.double_sided = true
	add_child(l)
	return l


func _build_bell() -> void:
	_post = Node3D.new()
	_post.name = "SignalPost"
	_post.position = POST_AT
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color("#6b4426")
	wood.roughness = 0.85
	var pole := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.045
	cyl.bottom_radius = 0.06
	cyl.height = POST_HEIGHT
	cyl.radial_segments = 10
	pole.mesh = cyl
	pole.material_override = wood
	pole.position.y = POST_HEIGHT * 0.5
	_post.add_child(pole)
	_post.add_child(_box(Vector3(0.62, 0.06, 0.07), Vector3(0.26, POST_HEIGHT - 0.08, 0), wood))
	add_child(_post)
	_banner = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.46, 0.72)
	_banner.mesh = quad
	_banner_mat = StandardMaterial3D.new()
	_banner_mat.albedo_color = BANNER_YELLOW
	_banner_mat.roughness = 0.9
	_banner_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_banner.material_override = _banner_mat
	_banner.position = Vector3(-0.27, POST_HEIGHT - 0.42, 0.0)
	_banner.visible = false
	_post.add_child(_banner)
	_bell = Node3D.new()
	_bell.name = "Bell"
	_bell_mat = StandardMaterial3D.new()
	_bell_mat.albedo_color = UiTokens.GOLD_DEEP
	_bell_mat.metallic = 0.75
	_bell_mat.roughness = 0.32
	_bell_mat.emission_enabled = true
	_bell_mat.emission = UiTokens.GOLD_BRIGHT
	_bell_mat.emission_energy_multiplier = 0.0
	var body := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.07
	cone.bottom_radius = 0.2
	cone.height = 0.26
	cone.radial_segments = 20
	body.mesh = cone
	body.material_override = _bell_mat
	body.position.y = -0.13
	_bell.add_child(body)
	var cap := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.08
	sphere.height = 0.12
	cap.mesh = sphere
	cap.material_override = _bell_mat
	_bell.add_child(cap)
	var lip := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.17
	torus.outer_radius = 0.22
	torus.rings = 20
	torus.ring_segments = 8
	lip.mesh = torus
	lip.material_override = _bell_mat
	lip.position.y = -0.26
	_bell.add_child(lip)
	var clapper := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.05
	ball.height = 0.1
	clapper.mesh = ball
	clapper.material_override = _bell_mat
	clapper.position.y = -0.3
	_bell.add_child(clapper)
	_bell_light = OmniLight3D.new()
	_bell_light.light_color = COLOR_WAITING
	_bell_light.omni_range = 2.6
	_bell_light.light_energy = 1.4
	_bell_light.shadow_enabled = false
	_bell_light.position.y = -0.2
	_bell_light.visible = false
	_bell.add_child(_bell_light)
	_bell.position = Vector3(0.48, POST_HEIGHT - 0.12, 0.0)
	_bell.scale = Vector3.ONE * 1.25
	for gi in _post.find_children("*", "GeometryInstance3D", true, false):
		(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_post.add_child(_bell)


func _build_chest() -> void:
	_chest = Node3D.new()
	_chest.name = "Chest"
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color("#7a4a26")
	wood.roughness = 0.8
	var band := ArtMaterials.gold()
	_chest.add_child(_box(Vector3(0.46, 0.26, 0.32), Vector3(0, 0.13, 0), wood))
	var lid := _box(Vector3(0.48, 0.1, 0.34), Vector3(0, 0.0, 0.0), wood)
	var hinge := Node3D.new()
	hinge.position = Vector3(0, 0.27, -0.16)
	hinge.rotation.x = -0.55
	lid.position = Vector3(0, 0.04, 0.16)
	hinge.add_child(lid)
	_chest.add_child(hinge)
	for x in [-0.16, 0.16]:
		_chest.add_child(_box(Vector3(0.04, 0.27, 0.33), Vector3(x, 0.135, 0), band))
	var glow := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.9, 0.9)
	glow.mesh = quad
	glow.material_override = Fx.sprite_material(WorldTextures.soft_dot(), true)
	glow.position = Vector3(0, 0.36, 0)
	(glow.material_override as StandardMaterial3D).billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	(glow.material_override as StandardMaterial3D).albedo_color = Color(1.0, 0.82, 0.4, 0.8)
	_chest.add_child(glow)
	_chest_light = OmniLight3D.new()
	_chest_light.light_color = Color(1.0, 0.8, 0.4)
	_chest_light.omni_range = 2.2
	_chest_light.light_energy = 1.2
	_chest_light.shadow_enabled = false
	_chest_light.position = Vector3(0, 0.4, 0)
	_chest.add_child(_chest_light)
	_chest.position = CHEST_AT
	_chest.scale = Vector3.ONE * 1.35
	_chest.rotation.y = -0.35
	_chest.visible = false
	add_child(_chest)


func _box(size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = at
	return mi


func _build_mark() -> void:
	_mark = _label(120, UiFonts.cinzel(700, 1))
	_mark.text = "!"
	_mark.modulate = COLOR_BAD
	_mark.position = Vector3(0, _roof + MARKER_ABOVE, 0)
	_mark.visible = false


func _place_stakes(plot: Rect2i) -> void:
	if plot.size == Vector2i.ZERO:
		return
	var c := Vector2(plot.position) + Vector2(plot.size) * 0.5
	var corners := [Vector2(plot.position), Vector2(plot.end.x, plot.position.y), Vector2(plot.position.x, plot.end.y), Vector2(plot.end)]
	for i in corners.size():
		var p: Vector2 = corners[i]
		var inset := (c - p).normalized() * 0.3
		var stake := ModelLibrary.instance("decor/stake_flag" if i % 2 == 0 else "decor/stake", building_id + i)
		stake.position = Vector3(p.x + inset.x - c.x, 0.0, p.y + inset.y - c.y)
		stake.scale = Vector3.ONE * 0.85
		add_child(stake)
		_stakes.append(stake)


## Re-reads the agent from Realm.
func refresh() -> void:
	var a := Realm.agent(agent_id)
	if a.is_empty():
		visible = false
		return
	visible = true
	var role := J.gs(a, "role")
	_name.text = J.gs(a, "name", "Agent")
	var status := ""
	var approvals := Realm.approvals_for(agent_id)
	var review := false
	var failed := false
	for t in Realm.tasks_of(agent_id):
		var s := J.gs(t, "state")
		review = review or s == "awaiting_review" or s == "accepting"
		failed = failed or s == "failed"
	var activity := J.gs(a, "activity", "idle")
	var lifecycle := J.gs(a, "lifecycle")
	var seal_out := false
	for ap in approvals:
		seal_out = seal_out or J.b(ap.get("seal_exhausted"))
	var color := COLOR_IDLE
	if not approvals.is_empty():
		status = "NEEDS YOUR APPROVAL"
		color = COLOR_SEAL if seal_out else COLOR_WAITING
	elif review:
		status = "RESULT READY"
		color = COLOR_WAITING
	elif failed:
		status = "TASK FAILED"
		color = COLOR_BAD
	elif activity == "blocked":
		status = "BLOCKED"
		color = COLOR_BAD
	elif activity == "working":
		status = "WORKING"
		color = COLOR_WORKING
	elif lifecycle == "settling":
		status = "SETTLING IN"
	_sub.text = ("%s  RANK %s" % [Economy.data.role_name(role).to_upper(), J.gs(a, "rank", "F")]) + (("  -  " + status) if status != "" else "")
	_name.modulate = color
	_flags = {"approval": not approvals.is_empty(), "seal": seal_out, "review": review, "failed": failed,
		"blocked": activity == "blocked", "working": activity == "working"}
	var ringing := bool(_flags["approval"])
	_banner.visible = ringing
	_banner_mat.albedo_color = BANNER_BLUE if seal_out else BANNER_YELLOW
	_bell_light.visible = ringing
	_bell_light.light_color = COLOR_SEAL if seal_out else COLOR_WAITING
	_bell_mat.emission = COLOR_SEAL if seal_out else UiTokens.GOLD_BRIGHT
	_bell_mat.emission_energy_multiplier = 0.45 if ringing else 0.0
	if not ringing:
		_bell.rotation.z = 0.0
	_chest.visible = review
	_mark.visible = bool(_flags["blocked"]) and not bool(_flags["approval"])
	if failed and _smoke == null:
		_smoke = Fx.trouble_smoke()
		_smoke.position = Vector3(0.3, _roof * 0.9, 0.0)
		add_child(_smoke)
	elif not failed and _smoke != null:
		_smoke.queue_free()
		_smoke = null


## Where the agent's add-on in use stands (world position), or null.
func set_work_position(p: Variant) -> void:
	_work_pos = p


func update_visual(time: float, delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_timer = REFRESH_S
		refresh()
	if _banner.visible:
		_bell.rotation.z = sin(time * 6.5) * 0.45
		_bell_light.light_energy = 1.1 + 0.6 * absf(sin(time * 6.5))
		_banner.rotation.y = sin(time * 1.7 + float(building_id)) * 0.18
		_banner.rotation.z = sin(time * 2.3) * 0.04
	if _chest.visible:
		_chest_light.light_energy = 1.0 + 0.35 * sin(time * 3.0)
	if _mark.visible:
		_mark.position.y = _roof + MARKER_ABOVE + sin(time * 3.5) * 0.06
	var working := bool(_flags.get("working", false)) and _work_pos != null
	_work_light.visible = working
	if working:
		var wp: Vector3 = _work_pos
		_work_light.global_position = wp + Vector3(0, 1.1, 0)
		_work_light.light_energy = 0.9 + 0.4 * sin(time * 4.2)
