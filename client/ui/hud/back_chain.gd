class_name BackChain
extends Node
## Android's Back button. It undoes the most recent thing and never quits: in order, it closes a
## touch tip or the minimap overlay, closes the top window, cancels placement or rally, turns the
## Select toggle off, clears the selection, and otherwise opens the game menu (which has Quit).
## When the app comes back from the background it opens the game menu, so the town waits paused.
## Hud creates it in setup().
##
## Stub: the menu stream fills it in.

var hud: Hud
var input: RtsInput


func setup(hud_layer: Hud, rts_input: RtsInput) -> void:
	hud = hud_layer
	input = rts_input


## One press of Back.
func go_back() -> void:
	pass
