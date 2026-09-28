class_name UnitView
extends Node3D
## A walking unit. Interpolates between the simulation's prev_pos and pos, turns toward where
## it walks, bobs while walking, swings while working, and shows what it carries.

const SCALE := 1.25
const BOB_HEIGHT := 0.07
const BOB_SPEED := 9.0

var unit_id: int = 0
var body: Node3D
var carry_wood: Node3D
var carry_food: Node3D

var _phase: float = 0.0
var _bob: float = 0.0


func setup(u: SimUnit) -> void:
	unit_id = u.id
	_phase = float(u.id % 17) * 0.7
	var model := ModelLibrary.instance("unit/" + u.kind, u.id)
	add_child(model)
	body = model.get_node("Body")
	carry_wood = body.get_node_or_null("CarryWood")
	carry_food = body.get_node_or_null("CarryFood")
	scale = Vector3.ONE * SCALE
	position = Vector3(u.pos.x, 0.0, u.pos.y)
	rotation.y = u.facing


## Interpolated position on the ground.
static func visual_pos(u: SimUnit, alpha: float) -> Vector3:
	var p := u.prev_pos.lerp(u.pos, alpha)
	return Vector3(p.x, 0.0, p.y)


func update_visual(u: SimUnit, alpha: float, time: float, delta: float) -> void:
	position = visual_pos(u, alpha)
	rotation.y = lerp_angle(rotation.y, u.facing, clampf(delta * 10.0, 0.0, 1.0))
	var moving := u.prev_pos.distance_squared_to(u.pos) > 0.0000004
	var target_bob := 0.0
	var tilt := 0.0
	if moving:
		target_bob = absf(sin(time * BOB_SPEED + _phase)) * BOB_HEIGHT
		tilt = 0.08
	elif u.is_working():
		tilt = 0.12 + sin(time * 7.0 + _phase) * 0.18
	_bob = lerpf(_bob, target_bob, clampf(delta * 20.0, 0.0, 1.0))
	body.position.y = _bob
	body.rotation.x = lerpf(body.rotation.x, tilt, clampf(delta * 12.0, 0.0, 1.0))
	if carry_wood != null:
		carry_wood.visible = u.carry_m > 0 and u.carry_res == "wood"
	if carry_food != null:
		carry_food.visible = u.carry_m > 0 and u.carry_res == "food"
