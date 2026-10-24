class_name BackChain
extends Node
## Android's Back button. It undoes the most recent thing and never quits: in order, it closes a
## touch tip or the minimap overlay, closes the top window, cancels placement or rally, turns the
## Select toggle off, clears the selection, and otherwise opens the game menu (which has Quit).
## When the app comes back from the background (where Game pauses the town) it opens the game
## menu, so the town waits until Resume. Hud creates it in setup().

var hud: Hud
var input: RtsInput
## Phones and tablets (tests set it).
var mobile: bool = Platform.is_mobile()


func setup(hud_layer: Hud, rts_input: RtsInput) -> void:
	hud = hud_layer
	input = rts_input


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_GO_BACK_REQUEST:
			go_back()
		NOTIFICATION_APPLICATION_RESUMED:
			if mobile:
				# After the tree has passed the notification on: Game hears it first, and nodes can
				# be added again.
				_on_resumed.call_deferred()


## One press of Back.
func go_back() -> void:
	if TouchTip.dismiss() or hud.close_overlay():
		return
	if hud.has_window():
		hud.close_window()
	elif input.mode != RtsInput.Mode.SELECT:
		input.cancel_mode()
	elif input.drag_selects:
		input.set_drag_selects(false)
	elif not input.selection.is_empty():
		input.selection.clear()
	else:
		hud.open_game_menu()


## Back from the background: the town waits in the game menu (over any other window, so there is
## always a Resume), unless one is open already.
func _on_resumed() -> void:
	if not GameMenu.is_open():
		hud.open_game_menu()
