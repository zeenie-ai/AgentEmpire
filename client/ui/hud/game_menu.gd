class_name GameMenu
extends PanelContainer
## The game menu on phones and tablets: Resume, Save, Load, New town, How to play, Sound,
## Graphics, Privacy policy and Quit. The town is paused while it is open. Opened with
## Hud.open_game_menu() from the top bar's Menu button and by Back.
##
## Stub: the menu stream fills it in.

var hud: Hud
var input: RtsInput


func setup(hud_layer: Hud, rts_input: RtsInput) -> GameMenu:
	hud = hud_layer
	input = rts_input
	return self
