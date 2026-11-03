class_name BackChain
extends Node
## Android's Back button. It undoes the most recent thing and never quits: in order, it closes a
## touch tip or the minimap overlay, closes the top window, cancels placement or rally, turns the
## Select toggle off, clears the selection, and otherwise opens the game menu (which has Quit).
## When the app comes back from the background (where Game pauses the town) it opens the game
## menu, so the town waits until Resume. Hud creates it in setup().
##
## One press is one step, though Godot 4.7.2 may say Back more than once for it
## (godotengine/godot#123454): the Back key sends a go-back notification for its down event and
## for every repeat, and since Android 16 the back dispatcher sends one more as the key comes up.
## A back gesture there sends only the dispatcher's. So the key's down event takes the step, each
## key event's own notification is dropped (one per down or repeat event), and a dispatcher's is
## dropped when it answers a key press, or else (a gesture) takes the step. Key events reach the
## game at the start of the next frame, after a dispatcher's notification for a quick tap, so a
## dispatcher's notification is weighed once the frame's key events are in. Android 15 and older
## send no dispatcher notification for the key: its presses are simply never answered.

var hud: Hud
var input: RtsInput
## Phones and tablets (tests set it).
var mobile: bool = Platform.is_mobile()

## Go-back notifications still to come from Back key down and repeat events, one each.
var _key_notices: int = 0
## Back key presses the back dispatcher may still answer with a notification of its own.
var _key_presses: int = 0


func _ready() -> void:
	set_process_input(mobile)


func setup(hud_layer: Hud, rts_input: RtsInput) -> void:
	hud = hud_layer
	input = rts_input


## The Back key itself (with the navigation bar's Back button or a hardware key).
func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or key.physical_keycode != KEY_BACK:
		return
	if key.pressed:
		_key_notices += 1
		if not key.echo:
			_key_presses += 1
			go_back()
	get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_GO_BACK_REQUEST:
			if _key_notices > 0:
				_key_notices -= 1
			else:
				_on_dispatcher_back.call_deferred()
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


## The back dispatcher's notification, once the frame's key events are in: its answer to a Back
## key press (already taken) or a back gesture (one step).
func _on_dispatcher_back() -> void:
	if _key_presses > 0:
		_key_presses -= 1
	else:
		go_back()


## Back from the background: the town waits in the game menu (over any other window, so there is
## always a Resume), unless one is open already.
func _on_resumed() -> void:
	if not GameMenu.is_open():
		hud.open_game_menu()
