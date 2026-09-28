class_name SimResourceNode
extends RefCounted
## A gatherable 1x1 cell: a tree or a berry bush (kinds from economy.json gather.nodes).
## Depleted nodes stop blocking movement and regrow after regrow_s.

var id: int = 0
var kind: String = ""
var cell: Vector2i = Vector2i.ZERO
## Remaining amount in thousandths of a unit.
var amount_m: int = 0
var max_m: int = 0
var depleted: bool = false
## Ticks left before a depleted node regrows.
var regrow_ticks: int = 0
## Visual variety seed (mesh variant, scale, rotation); fixed at map generation.
var variant: int = 0


func rect() -> Rect2i:
	return Rect2i(cell, Vector2i.ONE)


func center() -> Vector2:
	return Vector2(cell.x + 0.5, cell.y + 0.5)


func is_live() -> bool:
	return not depleted


func amount() -> int:
	return int(amount_m / 1000.0)
