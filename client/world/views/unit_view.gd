class_name UnitView
extends Node3D
## A walking unit. Interpolates between the simulation's prev_pos and pos and turns toward
## where it walks.
## - Rigged characters (res://art/characters/townsfolk_[a-d].glb) are driven by an AnimationTree
##   state machine from the unit's state (UnitAnim: idle, walk, carry, gather, chop, build,
##   cheer), cross-fading between states, with walking speed matched to the ground speed. The
##   carried load hangs from the right-hand bone (BoneAttachment3D, or the root when the rig has
##   no hand bone). Off-screen units stop animating.
## - The procedural figure bobs while walking, swings while working and shows its load on its
##   back.

const SCALE_PROC := 1.25
## Rigged figures are normalised to about 0.85 tiles tall; this brings them to about 1 tile.
const SCALE_RIGGED := 1.18
const BOB_HEIGHT := 0.07
const BOB_SPEED := 9.0
## Units live on render layer 2 so ground decals (selection rings) skip them.
const LAYER := 2

## Built state machines, shared by rigs with the same clip set: clip-set key -> tree root.
static var _trees: Dictionary = {}

var unit_id: int = 0
var rigged: bool = false
var body: Node3D
var carry_wood: Node3D
var carry_food: Node3D
var anim_tree: AnimationTree
var anim_state: String = ""

var _phase: float = 0.0
var _bob: float = 0.0
var _playback: AnimationNodeStateMachinePlayback
var _cheer_left: float = 0.0
## The construction site this unit last worked on (WorldView cheers its builders on completion).
var last_build_target: int = 0
var _on_screen: bool = true
var _speed: float = 0.0
var _clips: Dictionary = {}


func setup(u: SimUnit) -> void:
	unit_id = u.id
	_phase = float(u.id % 17) * 0.7
	var model := ModelLibrary.instance("unit/" + u.kind, u.id)
	add_child(model)
	rigged = bool(model.get_meta("rigged", false))
	if rigged:
		_setup_rig(model.get_node("Rig") as Node3D)
		scale = Vector3.ONE * SCALE_RIGGED
	else:
		body = model.get_node("Body")
		carry_wood = body.get_node_or_null("CarryWood")
		carry_food = body.get_node_or_null("CarryFood")
		scale = Vector3.ONE * SCALE_PROC
	for gi in find_children("*", "GeometryInstance3D", true, false):
		(gi as GeometryInstance3D).layers = 1 << (LAYER - 1)
	var notifier := VisibleOnScreenNotifier3D.new()
	notifier.aabb = AABB(Vector3(-0.6, 0.0, -0.6), Vector3(1.2, 1.6, 1.2))
	notifier.screen_entered.connect(_set_on_screen.bind(true))
	notifier.screen_exited.connect(_set_on_screen.bind(false))
	add_child(notifier)
	position = Vector3(u.pos.x, 0.0, u.pos.y)
	rotation.y = u.facing


func _setup_rig(rig: Node3D) -> void:
	body = rig
	var players := rig.find_children("*", "AnimationPlayer", true, false)
	var skeletons := rig.find_children("*", "Skeleton3D", true, false)
	var skeleton: Skeleton3D = skeletons[0] if not skeletons.is_empty() else null
	if not players.is_empty():
		var player := players[0] as AnimationPlayer
		var names := player.get_animation_list()
		for state: String in UnitAnim.STATES:
			_clips[state] = UnitAnim.clip_for(state, names)
			var clip := String(_clips[state])
			if clip != "" and state in UnitAnim.LOOPING:
				var a := player.get_animation(clip)
				if a != null and a.loop_mode == Animation.LOOP_NONE:
					a.loop_mode = Animation.LOOP_LINEAR
		var key := str(_clips)
		if not _trees.has(key):
			_trees[key] = UnitAnim.build_tree(_clips)
		anim_tree = AnimationTree.new()
		anim_tree.name = "AnimationTree"
		anim_tree.tree_root = _trees[key]
		rig.add_child(anim_tree)
		anim_tree.anim_player = anim_tree.get_path_to(player)
		anim_tree.active = true
		_playback = anim_tree.get("parameters/playback")
	var holder: Node3D = rig
	if skeleton != null:
		var bones := PackedStringArray()
		for i in skeleton.get_bone_count():
			bones.append(skeleton.get_bone_name(i))
		var hand := UnitAnim.hand_bone(bones)
		if hand >= 0:
			var ba := BoneAttachment3D.new()
			ba.name = "CarrySlot"
			skeleton.add_child(ba)
			ba.bone_name = bones[hand]
			holder = ba
	# Bones live in the skeleton's own scale (the art normalises the figure's height); props
	# undo it so they keep their size in tiles.
	var rig_scale := 1.0
	if skeleton != null:
		rig_scale = maxf(ModelLibrary._relative(skeleton, rig).basis.get_scale().x, 0.001)
	var in_hand := holder != rig
	carry_wood = _prop(holder, "wood", in_hand, rig_scale)
	carry_food = _prop(holder, "food", in_hand, rig_scale)


func _prop(holder: Node3D, res: String, in_hand: bool, rig_scale: float) -> Node3D:
	var p := ModelLibrary.instance("carry/" + res)
	p.name = "Carry" + res.capitalize()
	if in_hand:
		var t := prop_offset(res)
		p.transform = Transform3D(t.basis.scaled(Vector3.ONE / rig_scale), t.origin / rig_scale)
	else:
		p.position = Vector3(0, 0.45, -0.18)
	p.visible = false
	holder.add_child(p)
	return p


## Where a carried prop sits relative to the hand bone, in tiles (tuned for the KayKit rigs with
## tools/prop_check.gd): lumber rests diagonally across the body, a sack hangs from the hand.
static func prop_offset(res: String) -> Transform3D:
	if res == "wood":
		return Transform3D(Basis.IDENTITY, Vector3(0.0, 0.02, 0.0))
	return Transform3D(Basis.from_euler(Vector3(PI * 0.5, 0.0, 0.0)).scaled(Vector3.ONE * 0.85), Vector3(0.0, 0.0, 0.0))


func _set_on_screen(on: bool) -> void:
	_on_screen = on
	if anim_tree != null:
		anim_tree.active = on


## Interpolated position on the ground.
static func visual_pos(u: SimUnit, alpha: float) -> Vector3:
	var p := u.prev_pos.lerp(u.pos, alpha)
	return Vector3(p.x, 0.0, p.y)


func update_visual(u: SimUnit, alpha: float, time: float, delta: float) -> void:
	position = visual_pos(u, alpha)
	var step := u.prev_pos.distance_to(u.pos)
	var moving := step > 0.0006
	if u.job == SimConst.JOB_BUILD:
		last_build_target = u.target_id
	_cheer_left = maxf(_cheer_left - delta, 0.0)
	if carry_wood != null:
		carry_wood.visible = u.carry_m > 0 and u.carry_res == "wood"
	if carry_food != null:
		carry_food.visible = u.carry_m > 0 and u.carry_res == "food"
	if not _on_screen:
		rotation.y = u.facing
		return
	rotation.y = lerp_angle(rotation.y, u.facing, clampf(delta * 10.0, 0.0, 1.0))
	if rigged:
		_animate_rig(u, moving, step, delta)
	else:
		_animate_procedural(u, moving, time, delta)


## Just finished building something: cheer for a moment (used by WorldView on completion).
func cheer() -> void:
	_cheer_left = UnitAnim.CHEER_S


func _animate_rig(u: SimUnit, moving: bool, step: float, delta: float) -> void:
	if _playback == null:
		return
	var state := UnitAnim.state_for_unit(u, moving, _cheer_left > 0.0)
	if state != anim_state:
		anim_state = state
		_playback.travel(state)
	var tiles_per_s := step * float(Game.world.tick_rate) if Game.world != null else 0.0
	_speed = lerpf(_speed, tiles_per_s, clampf(delta * 8.0, 0.0, 1.0))
	var k := UnitAnim.speed_scale(state, _speed, SCALE_RIGGED * 0.85)
	anim_tree.set("parameters/%s/speed/scale" % state, k)


func _animate_procedural(u: SimUnit, moving: bool, time: float, delta: float) -> void:
	var target_bob := 0.0
	var tilt := 0.0
	if moving:
		target_bob = absf(sin(time * BOB_SPEED + _phase)) * BOB_HEIGHT
		tilt = 0.08
	elif u.is_working():
		tilt = 0.12 + sin(time * 7.0 + _phase) * 0.18
	elif _cheer_left > 0.0:
		target_bob = absf(sin(time * 12.0)) * 0.12
	_bob = lerpf(_bob, target_bob, clampf(delta * 20.0, 0.0, 1.0))
	body.position.y = _bob
	body.rotation.x = lerpf(body.rotation.x, tilt, clampf(delta * 12.0, 0.0, 1.0))
