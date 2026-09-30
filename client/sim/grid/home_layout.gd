class_name HomeLayout
extends RefCounted
## Geometry of an agent's plot (economy.json map.home_plot, 7x7): the 3x3 home in the middle,
## a two-tile ring around it for tool add-ons, and the entrance path from the home's door (the
## south side, +y) to the plot edge, which is always kept free.
##
##   plot cell (0, 0) is the top-left corner; the home covers (2..4, 2..4);
##   the entrance is (3, 5) and (3, 6).
##
## Add-ons go on the first free anchor in ANCHORS order (corners first, then the sides), where
## their whole footprint lies in the ring, off the entrance and off other add-ons.

const PLOT := 7
const HOME := 3
const HOME_OFFSET := Vector2i(2, 2)
const ENTRANCE: Array[Vector2i] = [Vector2i(3, 5), Vector2i(3, 6)]
## Preferred top-left cells for add-ons, relative to the plot.
const ANCHORS: Array[Vector2i] = [
	Vector2i(0, 0), Vector2i(5, 0), Vector2i(0, 5), Vector2i(5, 5),
	Vector2i(2, 0), Vector2i(0, 2), Vector2i(5, 2), Vector2i(4, 0),
	Vector2i(0, 4), Vector2i(5, 4), Vector2i(3, 0), Vector2i(0, 3),
	Vector2i(6, 3), Vector2i(1, 5), Vector2i(4, 5), Vector2i(1, 6),
	Vector2i(5, 6), Vector2i(1, 0), Vector2i(6, 0), Vector2i(0, 1),
]


## The plot around a home whose top-left cell is `home_cell`.
static func plot_rect(home_cell: Vector2i) -> Rect2i:
	return Rect2i(home_cell - HOME_OFFSET, Vector2i(PLOT, PLOT))


## The home's top-left cell for a plot whose top-left cell is `plot_cell`.
static func home_cell(plot_cell: Vector2i) -> Vector2i:
	return plot_cell + HOME_OFFSET


## The home's top-left cell for a plot centred on `centre` (what the placement ghost follows).
static func home_cell_at(centre: Vector2i) -> Vector2i:
	return centre - Vector2i(1, 1)


## The cell in front of the home's door (the first entrance cell), in world cells.
static func door_cell(home: Rect2i) -> Vector2i:
	return home.position + Vector2i(1, HOME)


static func entrance_cells(plot: Rect2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in ENTRANCE:
		out.append(plot.position + c)
	return out


## True when `r` (world cells) lies in the plot's ring: inside the plot, off the home and off
## the entrance.
static func in_ring(plot: Rect2i, r: Rect2i) -> bool:
	if not plot.encloses(r):
		return false
	var home := Rect2i(plot.position + HOME_OFFSET, Vector2i(HOME, HOME))
	if home.intersects(r):
		return false
	for c in entrance_cells(plot):
		if r.has_point(c):
			return false
	return true


## Where an add-on of `size` goes in `plot`, avoiding `taken` rects (other add-ons) and cells
## for which `blocked` (Callable(cell: Vector2i) -> bool) returns true. Returns the top-left
## cell, or Pathing.NO_CELL when the ring is full.
static func tool_cell(plot: Rect2i, size: Vector2i, taken: Array[Rect2i], blocked: Callable = Callable()) -> Vector2i:
	for a in ANCHORS:
		var r := Rect2i(plot.position + a, size)
		if not in_ring(plot, r) or _clashes(r, taken, blocked):
			continue
		return r.position
	return Pathing.NO_CELL


static func _clashes(r: Rect2i, taken: Array[Rect2i], blocked: Callable) -> bool:
	for t in taken:
		if t.intersects(r):
			return true
	if blocked.is_valid():
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				if bool(blocked.call(Vector2i(x, y))):
					return true
	return false
