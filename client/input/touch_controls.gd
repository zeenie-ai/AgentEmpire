class_name TouchControls
extends Node
## Touch in the world on phones and tablets. Reads InputEventScreenTouch and ScreenDrag through
## TouchGestures and turns the gestures into RtsInput and RtsCamera calls: a tap selects, or with
## townsfolk selected gives them the order a right-click gives; one finger pans (or draws a
## selection box while the Select toggle is on); two fingers pinch to zoom and twist to rotate.
## The HUD keeps the engine's mouse emulation, so its buttons work as they do with a mouse.
## GameMain creates this only when Platform.is_mobile().
##
## Stub: the touch stream fills it in.

var view: WorldView
var camera: RtsCamera
var selection: Selection
var input: RtsInput
var hud: Hud


func setup(world_view: WorldView, rts_camera: RtsCamera, sel: Selection, rts_input: RtsInput, hud_layer: Hud) -> void:
	view = world_view
	camera = rts_camera
	selection = sel
	input = rts_input
	hud = hud_layer
