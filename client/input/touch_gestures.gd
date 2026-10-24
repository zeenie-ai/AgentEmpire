class_name TouchGestures
extends RefCounted
## Turns raw touches into gestures: tap, hold, one-finger drag, and the two-finger pinch (zoom,
## twist, pan). Pure logic, events and times in and intents out, so it can be tested without a
## window. TouchControls feeds it and acts on the intents.
##
## Each intent is a Dictionary with a "kind" and its fields:
##   tap {pos, double}, hold {pos}, drag_begin {pos}, drag {pos}, drag_end {pos, canceled},
##   pinch_begin {centre}, pinch {centre, zoom, twist}, pinch_end {}.
## Positions are viewport coordinates; thresholds are in dp, times in milliseconds.
##
## Stub: the touch stream fills it in.

## Logical pixels per dp (Platform.px_per_dp), for the dp thresholds.
var px_per_dp: float = 1.0


func _init(pixels_per_dp: float = 1.0) -> void:
	px_per_dp = pixels_per_dp


## A finger went down or up (or the system canceled it). Returns the intents this completes.
func touch(_index: int, _pos: Vector2, _pressed: bool, _double_tap: bool, _canceled: bool, _t_ms: int) -> Array[Dictionary]:
	return []


## A finger moved. Returns the intents this completes.
func drag(_index: int, _pos: Vector2, _t_ms: int) -> Array[Dictionary]:
	return []


## Time passed: a press held long enough becomes a hold.
func tick(_t_ms: int) -> Array[Dictionary]:
	return []
