class_name UnitAnim
extends RefCounted
## Pure mapping from a unit's simulation state to an animation state, and from animation states
## to the character clips (art_src/manifest.json "character_animations"). UnitView drives an
## AnimationTree state machine with it; everything here is data and can be unit-tested.
##
## | state  | when                                   | clips (first found)                 |
## |--------|----------------------------------------|-------------------------------------|
## | idle   | standing                               | Idle, Unarmed_Idle                  |
## | walk   | moving                                 | Walking_A (speed matched)           |
## | carry  | moving with a load (prop in the hand)  | Walking_A (speed matched)           |
## | gather | gathering berries or farming           | Interact, PickUp                    |
## | chop   | gathering wood                         | 1H_Melee_Attack_Chop                |
## | build  | building                               | Use_Item, then the chop             |
## | cheer  | just finished a construction           | Cheer                               |

const IDLE := "idle"
const WALK := "walk"
const CARRY := "carry"
const GATHER := "gather"
const CHOP := "chop"
const BUILD := "build"
const CHEER := "cheer"
const STATES: Array[String] = [IDLE, WALK, CARRY, GATHER, CHOP, BUILD, CHEER]

const CLIPS := {
	IDLE: ["Idle", "Unarmed_Idle"],
	WALK: ["Walking_A", "Walking_B", "Walking_C", "Running_A"],
	CARRY: ["Walking_A", "Walking_B", "Walking_C", "Running_A"],
	GATHER: ["Interact", "PickUp", "Use_Item"],
	CHOP: ["1H_Melee_Attack_Chop", "2H_Melee_Attack_Chop", "Use_Item"],
	BUILD: ["Use_Item", "1H_Melee_Attack_Chop", "Interact"],
	CHEER: ["Cheer", "Idle"],
}
## States whose clips loop (cheer plays once).
const LOOPING: Array[String] = [IDLE, WALK, CARRY, GATHER, CHOP, BUILD]
## Blend time between states, in seconds.
const XFADE := 0.22
## Tiles per second that Walking_A covers at speed 1 for a figure about 1 tile tall.
const WALK_NATIVE_SPEED := 0.85
## Seconds a unit cheers after finishing a construction.
const CHEER_S := 1.6
## Bone names for the right hand, best first (KayKit rigs use "handslot.r").
const HAND_BONES: Array[String] = ["handslot.r", "handslot_r", "hand.r", "hand_r", "Hand.R", "hand_R", "RightHand", "mixamorig:RightHand"]


## The animation state for a unit. `moving`: it changed position this tick; `cheering`: it
## finished a construction a moment ago.
static func state_for(job: String, phase: String, gather_kind: String, carrying: bool, moving: bool, cheering: bool) -> String:
	if moving:
		return CARRY if carrying else WALK
	if cheering:
		return CHEER
	match job:
		SimConst.JOB_GATHER:
			if phase == GatherJob.GATHERING:
				return CHOP if gather_kind == "tree" else GATHER
		SimConst.JOB_BUILD:
			if phase == BuildJob.BUILDING:
				return BUILD
	return IDLE


static func state_for_unit(u: SimUnit, moving: bool, cheering: bool) -> String:
	return state_for(u.job, u.phase, u.gather_kind, u.is_carrying(), moving, cheering)


## The clip for `state` among the rig's `available` animation names ("" if none fits).
static func clip_for(state: String, available: PackedStringArray) -> String:
	for want: String in CLIPS.get(state, []):
		var hit := find_clip(want, available)
		if hit != "":
			return hit
	return ""


## `want` in `available`: exact, case-insensitive, or as the last part of a "Rig|Name" or
## "library/Name" path.
static func find_clip(want: String, available: PackedStringArray) -> String:
	if want in available:
		return want
	var lw := want.to_lower()
	for a in available:
		var la := a.to_lower()
		if la == lw or la.ends_with("|" + lw) or la.ends_with("/" + lw):
			return a
	return ""


## Playback speed for `state` at a ground speed of `tiles_per_s`, for a figure `height` tiles
## tall: walking legs keep pace with the ground so feet do not slide.
static func speed_scale(state: String, tiles_per_s: float, height: float = 1.0) -> float:
	match state:
		WALK, CARRY:
			var native := WALK_NATIVE_SPEED * maxf(height, 0.1)
			return clampf(tiles_per_s / native, 0.6, 2.4)
		CHOP:
			return 1.1
		GATHER:
			return 0.9
		BUILD:
			return 1.0
	return 1.0


## Index of the right-hand bone in `bone_names`, or -1 (then props go on the root).
static func hand_bone(bone_names: PackedStringArray) -> int:
	for want in HAND_BONES:
		var i := bone_names.find(want)
		if i >= 0:
			return i
	for i in bone_names.size():
		var n := bone_names[i].to_lower()
		if n.contains("hand") and (n.ends_with(".r") or n.ends_with("_r") or n.ends_with("right")):
			return i
	return -1


## A state machine with one blend tree per state (the clip through a TimeScale named "speed"),
## cross-fading between any two states. `clips` maps state -> animation name.
static func build_tree(clips: Dictionary) -> AnimationNodeStateMachine:
	var sm := AnimationNodeStateMachine.new()
	var x := 0.0
	for state: String in STATES:
		var bt := AnimationNodeBlendTree.new()
		var anim := AnimationNodeAnimation.new()
		anim.animation = StringName(String(clips.get(state, "")))
		bt.add_node("clip", anim, Vector2(0, 0))
		var ts := AnimationNodeTimeScale.new()
		bt.add_node("speed", ts, Vector2(200, 0))
		bt.connect_node("speed", 0, "clip")
		bt.connect_node("output", 0, "speed")
		sm.add_node(state, bt, Vector2(x, 0))
		x += 160.0
	for a: String in STATES:
		for b: String in STATES:
			if a == b:
				continue
			var t := AnimationNodeStateMachineTransition.new()
			t.xfade_time = XFADE
			t.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
			t.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_ENABLED
			sm.add_transition(a, b, t)
	var start := AnimationNodeStateMachineTransition.new()
	start.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	sm.add_transition("Start", IDLE, start)
	return sm
