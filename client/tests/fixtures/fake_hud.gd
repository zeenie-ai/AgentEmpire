extends Hud
## A HUD for testing what drives it (BackChain, GameMenu, CursorHint): it keeps the windows,
## overlay, game menus and confirmations it is asked for instead of showing them. Keep it out of
## the tree, where Hud would build the real HUD; free_windows() frees the windows it holds.

## Windows opened, the newest last.
var windows: Array[Control] = []
## Whether the phone's minimap overlay is open.
var overlay: bool = false
## How many game menus were opened.
var menus: int = 0
## Confirmations asked for: [title, text, on_yes].
var confirms: Array = []
## What world_rect() returns.
var band: Rect2 = Rect2(0, 46, 1600, 628)


func has_window() -> bool:
	return not windows.is_empty()


func open_window(w: Control) -> void:
	windows.append(w)


func close_window() -> void:
	if not windows.is_empty():
		windows.pop_back().free()


func close_overlay() -> bool:
	var was := overlay
	overlay = false
	return was


func open_game_menu() -> void:
	menus += 1


func confirm(title: String, text: String, on_yes: Callable) -> void:
	confirms.append([title, text, on_yes])


func world_rect() -> Rect2:
	return band


func free_windows() -> void:
	for w in windows:
		w.free()
	windows.clear()
