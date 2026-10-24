class_name TouchTip
extends RefCounted
## Tooltips on a touch screen, where nothing hovers: shows a control's tooltip beside it until the
## next touch or Back.
##
## Stub: the menu stream fills it in.


## Shows `control`'s tooltip beside it.
static func show_for(_control: Control) -> void:
	pass


## Hides the tip if one is showing. True when it did (the first step of the Back chain).
static func dismiss() -> bool:
	return false
