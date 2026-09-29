class_name IconDraw
extends RefCounted
## HUD icons: the art's rendered icon (res://art/icons/<id>.png, see AssetCatalog.icon_id) when
## it exists, otherwise a small vector glyph drawn with CanvasItem primitives (resources,
## buildings, orders). draw() fits the icon into `rect`.

static var _textures: Dictionary = {}


## The icon texture for a HUD icon name, or null when the art has none.
static func texture_for(icon: String) -> Texture2D:
	if icon == "":
		return null
	if not _textures.has(icon):
		var path := AssetCatalog.icon_path(AssetCatalog.icon_id(icon))
		var tex: Texture2D = null
		if path != "":
			tex = AssetCatalog.loader.call(path) as Texture2D
		_textures[icon] = tex
	return _textures[icon]


static func clear_cache() -> void:
	_textures.clear()


static func draw(ci: CanvasItem, icon: String, rect: Rect2, dim: bool = false) -> void:
	var tex := texture_for(icon)
	if tex != null:
		var ts := tex.get_size()
		var k2 := minf(rect.size.x / ts.x, rect.size.y / ts.y)
		var size := ts * k2
		var tint := Color(0.5, 0.5, 0.5, 0.85) if dim else Color.WHITE
		ci.draw_texture_rect(tex, Rect2(rect.get_center() - size * 0.5, size), false, tint)
		return
	var c := rect.get_center()
	var s := minf(rect.size.x, rect.size.y) * 0.5
	var k := 0.55 if dim else 1.0
	match icon:
		"food", "focus_food", "berry_bush":
			_berries(ci, c, s, k)
		"wood", "focus_wood":
			_log(ci, c, s, k)
		"tree":
			_tree(ci, c, s, k)
		"stone":
			var pts := PackedVector2Array([c + Vector2(-0.8, 0.45) * s, c + Vector2(-0.45, -0.45) * s, c + Vector2(0.25, -0.7) * s,
				c + Vector2(0.8, -0.1) * s, c + Vector2(0.6, 0.6) * s, c + Vector2(-0.3, 0.7) * s])
			ci.draw_colored_polygon(pts, _c(Palette.resource("stone"), k))
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.45, -0.45) * s, c + Vector2(0.25, -0.7) * s, c + Vector2(0.05, -0.05) * s]), _c(Color("#d8d2c4"), k))
		"gold":
			ci.draw_circle(c, s * 0.8, _c(Palette.GOLD_DEEP, k))
			ci.draw_circle(c, s * 0.6, _c(Palette.GOLD_BRIGHT, k))
			ci.draw_arc(c, s * 0.45, 0.0, TAU, 20, _c(Palette.GOLD_DEEP, k), maxf(s * 0.1, 1.0))
		"pop", "townsfolk", "idle":
			var col := _c(UiTokens.HUD_TEXT if icon == "pop" else Palette.TUNICS[0].lightened(0.2), k)
			ci.draw_circle(c + Vector2(0, -0.38) * s, s * 0.3, _c(Palette.SKIN, k) if icon != "pop" else col)
			var body := PackedVector2Array([c + Vector2(-0.62, 0.8) * s, c + Vector2(-0.45, 0.05) * s, c + Vector2(0, -0.08) * s,
				c + Vector2(0.45, 0.05) * s, c + Vector2(0.62, 0.8) * s])
			ci.draw_colored_polygon(body, col)
			if icon == "idle":
				ci.draw_arc(c + Vector2(0.55, -0.6) * s, s * 0.22, PI * 0.3, PI * 1.6, 10, _c(UiTokens.GOLD_BRIGHT, k), maxf(s * 0.1, 1.2))
		"cottage":
			_house(ci, c, s, Palette.HOUSE_WALL, Palette.TERRACOTTA, k)
		"storehouse":
			ci.draw_rect(Rect2(c + Vector2(-0.7, -0.35) * s, Vector2(1.4, 1.05) * s), _c(Palette.WOOD, k))
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.85, -0.3) * s, c + Vector2(0, -0.85) * s, c + Vector2(0.85, -0.3) * s]), _c(Palette.WOOD_DARK, k))
			ci.draw_rect(Rect2(c + Vector2(-0.25, 0.05) * s, Vector2(0.5, 0.65) * s), _c(Palette.INK, k))
		"farm":
			ci.draw_rect(Rect2(c - Vector2(0.8, 0.7) * s, Vector2(1.6, 1.4) * s), _c(Palette.SOIL, k))
			for i in 4:
				var y := -0.5 + i * 0.33
				ci.draw_line(c + Vector2(-0.7, y) * s, c + Vector2(0.7, y) * s, _c(Palette.CROP, k), maxf(s * 0.16, 1.5))
		"keep":
			ci.draw_rect(Rect2(c + Vector2(-0.7, -0.1) * s, Vector2(1.4, 0.85) * s), _c(Palette.STONE, k))
			ci.draw_rect(Rect2(c + Vector2(-0.22, -0.55) * s, Vector2(0.44, 1.3) * s), _c(Palette.STONE.lightened(0.08), k))
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.32, -0.5) * s, c + Vector2(0, -0.95) * s, c + Vector2(0.32, -0.5) * s]), _c(Palette.SLATE, k))
			for x in [-0.62, 0.62]:
				ci.draw_colored_polygon(PackedVector2Array([c + Vector2(x - 0.18, -0.1) * s, c + Vector2(x, -0.42) * s, c + Vector2(x + 0.18, -0.1) * s]), _c(Palette.SLATE, k))
		"stop":
			var oct := PackedVector2Array()
			for i in 8:
				var a := PI / 8.0 + TAU * i / 8.0
				oct.append(c + Vector2(cos(a), sin(a)) * s * 0.78)
			ci.draw_colored_polygon(oct, _c(UiTokens.BAD.darkened(0.15), k))
			ci.draw_rect(Rect2(c + Vector2(-0.42, -0.1) * s, Vector2(0.84, 0.2) * s), _c(Color.WHITE, k))
		"return":
			ci.draw_rect(Rect2(c + Vector2(-0.7, 0.05) * s, Vector2(1.4, 0.7) * s), _c(Palette.WOOD, k))
			ci.draw_line(c + Vector2(0, -0.85) * s, c + Vector2(0, 0.15) * s, _c(UiTokens.GOLD_BRIGHT, k), maxf(s * 0.18, 1.5))
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.35, -0.1) * s, c + Vector2(0.35, -0.1) * s, c + Vector2(0, 0.3) * s]), _c(UiTokens.GOLD_BRIGHT, k))
		"gather", "focus_auto":
			_berries(ci, c + Vector2(-0.35, 0.1) * s, s * 0.62, k)
			_log(ci, c + Vector2(0.38, -0.2) * s, s * 0.62, k)
		"summon":
			ci.draw_arc(c, s * 0.75, 0.0, TAU, 32, _c(UiTokens.GOLD_BRIGHT, k), maxf(s * 0.12, 1.5))
			var star := PackedVector2Array()
			for i in 10:
				var a := -PI * 0.5 + TAU * i / 10.0
				star.append(c + Vector2(cos(a), sin(a)) * s * (0.5 if i % 2 == 0 else 0.22))
			ci.draw_colored_polygon(star, _c(UiTokens.MINT, k))
		"rally":
			ci.draw_line(c + Vector2(-0.4, 0.85) * s, c + Vector2(-0.4, -0.8) * s, _c(Palette.WOOD_LIGHT, k), maxf(s * 0.12, 1.5))
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.35, -0.8) * s, c + Vector2(0.7, -0.5) * s, c + Vector2(-0.35, -0.15) * s]), _c(UiTokens.GOLD, k))
		"cancel":
			var w := maxf(s * 0.22, 2.0)
			ci.draw_line(c + Vector2(-0.6, -0.6) * s, c + Vector2(0.6, 0.6) * s, _c(UiTokens.BAD, k), w)
			ci.draw_line(c + Vector2(0.6, -0.6) * s, c + Vector2(-0.6, 0.6) * s, _c(UiTokens.BAD, k), w)
		"dismantle":
			ci.draw_line(c + Vector2(-0.55, 0.7) * s, c + Vector2(0.3, -0.2) * s, _c(Palette.WOOD_LIGHT, k), maxf(s * 0.16, 1.5))
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(0.05, -0.55) * s, c + Vector2(0.45, -0.85) * s,
				c + Vector2(0.8, -0.45) * s, c + Vector2(0.45, -0.15) * s]), _c(Palette.ROCK.lightened(0.2), k))
		"task", "scroll":
			_scroll(ci, c, s, k)
		"review":
			_scroll(ci, c + Vector2(-0.15, 0.1) * s, s * 0.85, k)
			var w := maxf(s * 0.2, 2.0)
			ci.draw_line(c + Vector2(0.05, 0.1) * s, c + Vector2(0.3, 0.4) * s, _c(UiTokens.MINT, k), w)
			ci.draw_line(c + Vector2(0.3, 0.4) * s, c + Vector2(0.85, -0.35) * s, _c(UiTokens.MINT, k), w)
		"bell", "approvals":
			var bell := PackedVector2Array([c + Vector2(-0.62, 0.45) * s, c + Vector2(-0.4, 0.3) * s, c + Vector2(-0.32, -0.3) * s,
				c + Vector2(0, -0.62) * s, c + Vector2(0.32, -0.3) * s, c + Vector2(0.4, 0.3) * s, c + Vector2(0.62, 0.45) * s])
			ci.draw_colored_polygon(bell, _c(UiTokens.GOLD_BRIGHT, k))
			ci.draw_circle(c + Vector2(0, 0.6) * s, s * 0.14, _c(UiTokens.GOLD, k))
			ci.draw_circle(c + Vector2(0, -0.72) * s, s * 0.1, _c(UiTokens.GOLD, k))
		"plot":
			ci.draw_rect(Rect2(c + Vector2(-0.8, -0.35) * s, Vector2(1.6, 1.1) * s), _c(Palette.LEAF.darkened(0.2), k), false, maxf(s * 0.1, 1.2))
			ci.draw_line(c + Vector2(-0.1, 0.6) * s, c + Vector2(-0.1, -0.85) * s, _c(Palette.WOOD_LIGHT, k), maxf(s * 0.12, 1.5))
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.05, -0.85) * s, c + Vector2(0.7, -0.6) * s, c + Vector2(-0.05, -0.35) * s]), _c(UiTokens.MINT, k))
		"resume":
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.45, -0.65) * s, c + Vector2(0.65, 0.0) * s, c + Vector2(-0.45, 0.65) * s]), _c(UiTokens.MINT, k))
		"retire":
			ci.draw_rect(Rect2(c + Vector2(-0.5, -0.75) * s, Vector2(0.75, 1.5) * s), _c(Palette.WOOD_DARK, k))
			ci.draw_line(c + Vector2(0.0, 0.0) * s, c + Vector2(0.85, 0.0) * s, _c(UiTokens.GOLD_BRIGHT, k), maxf(s * 0.16, 1.5))
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(0.55, -0.3) * s, c + Vector2(0.95, 0.0) * s, c + Vector2(0.55, 0.3) * s]), _c(UiTokens.GOLD_BRIGHT, k))
		_:
			ci.draw_circle(c, s * 0.5, _c(UiTokens.HUD_MUTED, k))


static func _c(col: Color, k: float) -> Color:
	return Color(col.r * k, col.g * k, col.b * k, col.a)


static func _berries(ci: CanvasItem, c: Vector2, s: float, k: float) -> void:
	ci.draw_colored_polygon(PackedVector2Array([c + Vector2(0.05, -0.35) * s, c + Vector2(0.65, -0.85) * s, c + Vector2(0.45, -0.25) * s]), _c(Palette.LEAF_LIGHT, k))
	for p: Vector2 in [Vector2(-0.35, 0.15), Vector2(0.3, 0.25), Vector2(-0.02, -0.25), Vector2(-0.05, 0.55)]:
		ci.draw_circle(c + p * s, s * 0.34, _c(Palette.BERRY, k))
		ci.draw_circle(c + p * s + Vector2(-0.1, -0.1) * s, s * 0.08, _c(Color(1, 1, 1, 0.6), k))


## A rolled parchment scroll: a task.
static func _scroll(ci: CanvasItem, c: Vector2, s: float, k: float) -> void:
	ci.draw_rect(Rect2(c + Vector2(-0.55, -0.5) * s, Vector2(1.1, 1.0) * s), _c(UiTokens.PARCHMENT, k))
	for y in [-0.2, 0.05, 0.3]:
		ci.draw_line(c + Vector2(-0.35, y) * s, c + Vector2(0.35, y) * s, _c(UiTokens.SEPIA, k), maxf(s * 0.06, 1.0))
	for y in [-0.55, 0.55]:
		ci.draw_rect(Rect2(c + Vector2(-0.7, y - 0.12) * s, Vector2(1.4, 0.24) * s), _c(Palette.WOOD_LIGHT, k))


static func _log(ci: CanvasItem, c: Vector2, s: float, k: float) -> void:
	var r := s * 0.34
	ci.draw_rect(Rect2(c + Vector2(-0.75 * s, -r), Vector2(1.3 * s, r * 2.0)), _c(Palette.TRUNK, k))
	ci.draw_circle(c + Vector2(0.55 * s, 0), r, _c(Palette.WOOD_LIGHT, k))
	ci.draw_arc(c + Vector2(0.55 * s, 0), r * 0.55, 0.0, TAU, 14, _c(Palette.TRUNK, k), maxf(s * 0.06, 1.0))


static func _tree(ci: CanvasItem, c: Vector2, s: float, k: float) -> void:
	ci.draw_rect(Rect2(c + Vector2(-0.1, 0.35) * s, Vector2(0.2, 0.5) * s), _c(Palette.TRUNK, k))
	ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.65, 0.45) * s, c + Vector2(0, -0.9) * s, c + Vector2(0.65, 0.45) * s]), _c(Palette.LEAF, k))


static func _house(ci: CanvasItem, c: Vector2, s: float, wall: Color, roof: Color, k: float) -> void:
	ci.draw_rect(Rect2(c + Vector2(-0.6, -0.15) * s, Vector2(1.2, 0.9) * s), _c(wall, k))
	ci.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.85, -0.1) * s, c + Vector2(0, -0.85) * s, c + Vector2(0.85, -0.1) * s]), _c(roof, k))
	ci.draw_rect(Rect2(c + Vector2(-0.15, 0.25) * s, Vector2(0.3, 0.5) * s), _c(Palette.WOOD_DARK, k))
