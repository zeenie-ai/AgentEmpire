extends SceneTree
## Renders AgentEmpire's Google Play graphics and its Android launcher icons, then checks them:
##   store/graphics/icon-512.png            the Play icon: 512 x 512, 32-bit, full bleed (Play
##                                          rounds the corners itself), under 1024 KB
##   store/graphics/feature-1024x500.png    the feature graphic: the town with the title, 24-bit
##   client/art/launcher/icon_192.png       the legacy launcher icon: client/icon.svg as it is
##   client/art/launcher/icon_fg_432.png    the adaptive icon's foreground: the motif, inside the
##                                          middle 264 px (the 66 dp every mask keeps)
##   client/art/launcher/icon_bg_432.png    the adaptive icon's background: the icon's dark field
##   client/art/launcher/icon_mono_432.png  the themed icon (Android 13 and later): the motif in white
##   out/store/launcher_preview.png         for review only: the adaptive icon under three launcher
##                                          masks and the themed icon, full size and at phone size
## The icons come from client/icon.svg, split into its background rect, its frame (only the legacy
## icon keeps it, since launchers and Play cut their own shapes) and its motif. Every check failure
## is printed and the tool exits 1. The feature graphic needs a window, so do not pass --headless:
##   .tools/godot/Godot_v4.7.2-stable_win64_console.exe --path client -s res://tools/store_art.gd
## Options after "--":
##   --only=icons,feature   render only these (both by default); --check renders nothing
##   --seed=<n>             the town in the feature graphic and the screenshots
##   --shots                store screenshots of the phone and tablet build, at the window size
##                          --size=WxH, into out/store/shots/<WxH>-<n>-<scene>.png, best first.
##                          They need the renderer phones use and the phone build's flags:
##     <godot> --rendering-method mobile --path client -s res://tools/store_art.gd -- --shots
##       phone          --size=1920x1080 --mobile --dpi=420
##       small tablet   --size=1920x1200 --mobile --dpi=280 --only=town,unit,build
##       large tablet   --size=2560x1440 --mobile --dpi=320 --only=keep,unit,group,build
##                          (not town there: the full layout shows an empty command grid
##                          while nothing is selected)
##                          --only=<scenes> picks scenes in that order from SHOT_SCENES; the
##                          graphics are the build's default on phones (Low) unless --quality=.

const ICON_SVG := "res://icon.svg"
const LAUNCHER_DIR := "res://art/launcher"
const ICON_512 := "icon-512.png"
const FEATURE := "feature-1024x500.png"
const LEGACY := "icon_192.png"
const FOREGROUND := "icon_fg_432.png"
const BACKGROUND := "icon_bg_432.png"
const MONOCHROME := "icon_mono_432.png"

const PLAY_ICON_PX := 512
const LEGACY_PX := 192
const FEATURE_SIZE := Vector2i(1024, 500)
## The feature graphic is drawn at twice its size and scaled down, for clean edges.
const SUPERSAMPLE := 2
## Its camera looks at a point FEATURE_SHIFT tiles left (on screen) of the Keep, from
## FEATURE_DISTANCE tiles away, FEATURE_PITCH_DEG down and turned FEATURE_YAW_DEG.
const FEATURE_SHIFT := 12.0
const FEATURE_DISTANCE := 38.5
const FEATURE_PITCH_DEG := 34.0
const FEATURE_YAW_DEG := 32.0
## Android's adaptive icon layers are 108 dp at 4 px per dp. Launchers show the middle 72 dp
## (VISIBLE_PX) through their mask, and every mask keeps the middle 66 dp (SAFE_ZONE_PX).
const ADAPTIVE_PX := 432
const VISIBLE_PX := 288
const SAFE_ZONE_PX := 264
## In the white (themed) icon, each shape cuts an outline this wide (icon.svg units) out of the
## shapes drawn before it, so overlapping shapes stay apart in one colour.
const CUT_GAP := 2.0

## Play's limit for the icon; the feature graphic and screenshots stay under the 8 MB Play gives
## screenshots.
const ICON_MAX_BYTES := 1024 * 1024
const GRAPHIC_MAX_BYTES := 8 * 1024 * 1024
## Play's screenshot sides, and the longer side at most twice the shorter.
const SHOT_MIN_PX := 320
const SHOT_MAX_PX := 3840
## PNG colour types: 2 is RGB (24-bit at 8 bits), 6 is RGBA (32-bit).
const PNG_RGB := 2
const PNG_RGBA := 6

const SEED := 4127
## The phone's screenshot scenes, best first: the walled town; a townsperson farming, close up;
## a cottage being placed; every townsperson selected; the Keep training; the minimap; How to
## play.
const SHOT_SCENES: Array[String] = ["town", "unit", "build", "group", "keep", "map", "help"]
## The group shot frames the townsfolk this close to the Keep (tiles): inside the Keep Ring and
## at the groves by its gates.
const GROUP_RADIUS := 16.0

var _args: PackedStringArray
var _failures: int = 0


## client/icon.svg in parts: the canvas size, the colour of the background rect that covers it,
## and the motif: every other element but the stroke-only frame, in drawing order, as
## [tag, {attribute: value}].
class IconParts:
	var size: float = 0.0
	var background: String = ""
	var motif: Array[Array] = []


func _initialize() -> void:
	_args = OS.get_cmdline_user_args()
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	for a in _args:
		if a.begins_with("--%s=" % name):
			return a.get_slice("=", 1)
	return fallback


func _wanted(part: String) -> bool:
	var only := _arg("only", "")
	return only == "" or part in only.split(",")


func _run() -> void:
	if "--shots" in _args:
		await _shots()
		_check_shots()
	else:
		var parts := _icon_parts()
		if not "--check" in _args:
			if _wanted("icons"):
				_render_icons(parts)
			if _wanted("feature"):
				await _render_feature()
		_check_art(parts)
	if _failures > 0:
		printerr("store_art: %d check(s) failed" % _failures)
	else:
		print("store_art: all checks passed")
	quit(1 if _failures > 0 else 0)


func _fail(message: String) -> void:
	_failures += 1
	printerr("store_art: FAIL " + message)


# --- paths --------------------------------------------------------------------------------------

func _repo_path(rel: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").path_join(rel).simplify_path()


func _store_path(file: String) -> String:
	return _repo_path("store/graphics").path_join(file)


func _launcher_path(file: String) -> String:
	return ProjectSettings.globalize_path(LAUNCHER_DIR).path_join(file)


func _save(img: Image, path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := img.save_png(path)
	if err != OK:
		_fail("could not write %s (error %d)" % [path, err])
		return
	print("store_art: wrote %s (%dx%d)" % [path, img.get_width(), img.get_height()])


# --- the icon -----------------------------------------------------------------------------------

func _icon_parts() -> IconParts:
	var parts := IconParts.new()
	var xml := XMLParser.new()
	if xml.open_buffer(FileAccess.get_file_as_bytes(ICON_SVG)) != OK:
		return parts
	while xml.read() == OK:
		if xml.get_node_type() != XMLParser.NODE_ELEMENT:
			continue
		var tag := xml.get_node_name()
		var attrs := {}
		for i in xml.get_attribute_count():
			attrs[xml.get_attribute_name(i)] = xml.get_attribute_value(i)
		var fill := xml.get_named_attribute_value_safe("fill")
		if tag == "svg":
			parts.size = xml.get_named_attribute_value_safe("width").to_float()
		elif tag == "rect" and fill == "none":
			continue
		elif tag == "rect" and _covers(xml, parts.size):
			parts.background = fill
		else:
			parts.motif.append([tag, attrs])
	return parts


## Whether the rect being read covers the whole `size` square canvas.
func _covers(xml: XMLParser, size: float) -> bool:
	return xml.get_named_attribute_value_safe("x").to_float() == 0.0 \
		and xml.get_named_attribute_value_safe("y").to_float() == 0.0 \
		and xml.get_named_attribute_value_safe("width").to_float() == size \
		and xml.get_named_attribute_value_safe("height").to_float() == size


func _element(tag: String, attrs: Dictionary) -> String:
	var out := "<" + tag
	for key: String in attrs:
		out += ' %s="%s"' % [key, str(attrs[key]).xml_escape(true)]
	return out + "/>"


## The motif in its colours, as SVG elements.
func _motif(parts: IconParts) -> String:
	var out := ""
	for e: Array in parts.motif:
		out += _element(e[0], e[1])
	return out


## The motif in white. Each shape is drawn over the ones before it with a CUT_GAP outline cut out
## of them (an SVG mask), where the colours used to tell them apart.
func _white_motif(parts: IconParts) -> String:
	var keep := '<rect x="0" y="0" width="%f" height="%f" fill="#ffffff"/>' % [parts.size, parts.size]
	var defs := ""
	var body := ""
	for i in parts.motif.size():
		var tag: String = parts.motif[i][0]
		var attrs: Dictionary = parts.motif[i][1]
		if i > 0:
			defs += '<mask id="cut%d" maskUnits="userSpaceOnUse" x="0" y="0" width="%f" height="%f">%s%s</mask>' % [
				i, parts.size, parts.size, keep, _element(tag, _cutter(attrs))]
			body = '<g mask="url(#cut%d)">%s</g>' % [i, body]
		body += _element(tag, _whitened(attrs))
	return "<defs>%s</defs>%s" % [defs, body]


## The same attributes with every fill and stroke white (a missing fill is black in SVG).
func _whitened(attrs: Dictionary) -> Dictionary:
	var out := attrs.duplicate()
	if str(out.get("fill", "")) != "none":
		out["fill"] = "#ffffff"
	if out.has("stroke") and str(out["stroke"]) != "none":
		out["stroke"] = "#ffffff"
	return out


## The shape in black for a mask, grown by CUT_GAP all round.
func _cutter(attrs: Dictionary) -> Dictionary:
	var out := attrs.duplicate()
	out.erase("opacity")
	var stroke := 0.0
	if str(out.get("stroke", "none")) != "none":
		stroke = str(out.get("stroke-width", "1")).to_float()
	if str(out.get("fill", "")) != "none":
		out["fill"] = "#000000"
	out["stroke"] = "#000000"
	out["stroke-width"] = str(stroke + 2.0 * CUT_GAP)
	out["stroke-linejoin"] = "round"
	return out


## An SVG `px` pixels square that shows the `view` square of icon.svg's canvas.
func _svg(px: int, view: Rect2, body: String) -> String:
	return '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="%f %f %f %f">%s</svg>' % [
		px, px, view.position.x, view.position.y, view.size.x, view.size.y, body]


func _render(svg: String, scale: float = 1.0) -> Image:
	var img := Image.new()
	var err := img.load_svg_from_string(svg, scale)
	if err != OK:
		_fail("could not render an SVG (error %d)" % err)
	return img


func _field(parts: IconParts) -> String:
	return '<rect x="0" y="0" width="%f" height="%f" fill="%s"/>' % [parts.size, parts.size, parts.background]


## The centre of the motif's bounding box, in icon.svg units, measured on a large render.
func _motif_centre(parts: IconParts) -> Vector2:
	var scale := 8.0
	var img := _render(_svg(int(parts.size * scale), Rect2(0, 0, parts.size, parts.size), _motif(parts)))
	var used := img.get_used_rect()
	return (Vector2(used.position) + Vector2(used.size) * 0.5) / scale


## The part of icon.svg's canvas an adaptive layer shows: centred on the motif, and scaled so the
## whole canvas fills the 72 dp a launcher shows, which keeps the motif as large as in the icon.
func _adaptive_view(parts: IconParts) -> Rect2:
	var centre := _motif_centre(parts)
	var half := parts.size * 0.5 * ADAPTIVE_PX / VISIBLE_PX
	return Rect2(centre.x - half, centre.y - half, half * 2.0, half * 2.0)


func _render_icons(parts: IconParts) -> void:
	if parts.size <= 0.0 or parts.background == "" or parts.motif.is_empty():
		_fail("could not split %s into its background and motif" % ICON_SVG)
		return
	var whole := Rect2(0, 0, parts.size, parts.size)
	# The Play icon: the dark field full bleed, the motif as drawn; Play cuts the corners.
	_save(_render(_svg(PLAY_ICON_PX, whole, _field(parts) + _motif(parts))), _store_path(ICON_512))
	# The legacy launcher icon (Android 7): icon.svg as it is, rounded corners and frame.
	_save(_render(FileAccess.get_file_as_string(ICON_SVG), LEGACY_PX / parts.size), _launcher_path(LEGACY))
	# The adaptive icon (Android 8 and later): the launcher puts the motif on the field and cuts
	# its own shape, so neither layer has corners or the frame.
	var view := _adaptive_view(parts)
	var fg := _render(_svg(ADAPTIVE_PX, view, _motif(parts)))
	_save(fg, _launcher_path(FOREGROUND))
	var bg := Image.create_empty(ADAPTIVE_PX, ADAPTIVE_PX, false, Image.FORMAT_RGBA8)
	bg.fill(Color(parts.background))
	_save(bg, _launcher_path(BACKGROUND))
	var mono := _render(_svg(ADAPTIVE_PX, view, _white_motif(parts)))
	_save(mono, _launcher_path(MONOCHROME))
	_save(_launcher_preview(fg, bg, mono), _repo_path("out/store/launcher_preview.png"))


## For review: the adaptive icon under a circle, a squircle and a rounded square, and the themed
## icon, each at full size (the visible 72 dp) and at a 420 dpi phone's 48 dp.
func _launcher_preview(fg: Image, bg: Image, mono: Image) -> Image:
	var icon := bg.duplicate() as Image
	icon.blend_rect(fg, Rect2i(Vector2i.ZERO, fg.get_size()), Vector2i.ZERO)
	var themed := Image.create_empty(ADAPTIVE_PX, ADAPTIVE_PX, false, Image.FORMAT_RGBA8)
	themed.fill(Color("#d6e3ff"))
	var tint := mono.duplicate() as Image
	for y in tint.get_height():
		for x in tint.get_width():
			tint.set_pixel(x, y, Color(Color("#1d2c4a"), tint.get_pixel(x, y).a))
	themed.blend_rect(tint, Rect2i(Vector2i.ZERO, tint.get_size()), Vector2i.ZERO)
	var crop := Rect2i(Vector2i.ONE * (ADAPTIVE_PX - VISIBLE_PX) / 2, Vector2i.ONE * VISIBLE_PX)
	var tiles: Array[Image] = [
		_masked(icon.get_region(crop), "circle"),
		_masked(icon.get_region(crop), "squircle"),
		_masked(icon.get_region(crop), "rounded"),
		_masked(themed.get_region(crop), "circle"),
	]
	var small := int(round(48.0 * 420.0 / 160.0))
	var gap := 24
	var out := Image.create_empty(gap + tiles.size() * (VISIBLE_PX + gap), VISIBLE_PX + small + gap * 3, false, Image.FORMAT_RGBA8)
	out.fill(Color("#6f7a86"))
	for i in tiles.size():
		var x := gap + i * (VISIBLE_PX + gap)
		out.blend_rect(tiles[i], Rect2i(Vector2i.ZERO, tiles[i].get_size()), Vector2i(x, gap))
		var s := tiles[i].duplicate() as Image
		s.resize(small, small, Image.INTERPOLATE_LANCZOS)
		out.blend_rect(s, Rect2i(Vector2i.ZERO, s.get_size()), Vector2i(x + (VISIBLE_PX - small) / 2, VISIBLE_PX + gap * 2))
	return out


## `img` (square) cut to a launcher shape, with a one-pixel soft edge.
func _masked(img: Image, shape: String) -> Image:
	var n := float(img.get_width())
	var out := img.duplicate() as Image
	for y in img.get_height():
		for x in img.get_width():
			var p := (Vector2(x + 0.5, y + 0.5) / n - Vector2(0.5, 0.5)) * 2.0
			var edge := 0.0
			match shape:
				"circle":
					edge = 1.0 - p.length()
				"squircle":
					edge = 1.0 - pow(pow(absf(p.x), 4.0) + pow(absf(p.y), 4.0), 0.25)
				_:
					var q := Vector2(absf(p.x), absf(p.y)) - Vector2.ONE * 0.6
					edge = 0.4 - (Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0))
			var c := img.get_pixel(x, y)
			c.a *= clampf(edge * n * 0.5 + 0.5, 0.0, 1.0)
			out.set_pixel(x, y, c)
	return out


# --- the feature graphic ------------------------------------------------------------------------

func _render_feature() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("the feature graphic needs a real window: run without --headless")
		return
	var size := FEATURE_SIZE * SUPERSAMPLE
	await _fix_window(size)
	var game := root.get_node("Game")
	var main: Variant = load("res://game/main.tscn").instantiate()
	main.autostart = false
	root.add_child(main)
	await process_frame
	game.paused = true
	var w: SimWorld = game.new_town(int(_arg("seed", str(SEED))), "store")
	DemoTown.build(w, 14, 90.0)
	_quiet_scene(main)
	game.paused = false
	root.add_child(_title_overlay(size))
	var aim := _aim.bind(main.camera.camera, Vector3(w.keep().center().x, 0.0, w.keep().center().y))
	var img := await _capture(size, 90, aim)
	img.resize(FEATURE_SIZE.x, FEATURE_SIZE.y, Image.INTERPOLATE_LANCZOS)
	img.convert(Image.FORMAT_RGB8)
	_save(img, _store_path(FEATURE))
	main.queue_free()


## Points `camera` at the walled town, lower than the game's camera goes, with the Keep (`keep`)
## right of centre so the title has the fields and forest on the left.
## Called every frame, since the main scene frames its opening view after a town starts.
func _aim(camera: Camera3D, keep: Vector3) -> void:
	var yaw := deg_to_rad(FEATURE_YAW_DEG)
	var pitch := deg_to_rad(FEATURE_PITCH_DEG)
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var target := keep - right * FEATURE_SHIFT
	var back := Vector3(sin(yaw), 0.0, cos(yaw))
	var eye := target + (back * cos(pitch) + Vector3.UP * sin(pitch)) * FEATURE_DISTANCE
	camera.global_transform = Transform3D(Basis.looking_at(target - eye, Vector3.UP), eye)


## No HUD, no hover ring under the resting mouse, no floating gains, and the camera left to
## _aim(): just the town.
func _quiet_scene(main: Variant) -> void:
	main.hud.visible = false
	main.camera.input_enabled = false
	main.camera.set_process(false)
	main.selection.clear()
	main.input.set_process(false)
	main.input.set_process_input(false)
	main.input.set_process_unhandled_input(false)
	main.world_view.hover_id = 0
	main.world_view.floating.visible = false


## The title over the left of the town: a band of the HUD's dark wood fading to the right,
## "AgentEmpire" in Cinzel over a gold rule, and a line in JetBrains Mono. Sizes are in feature
## graphic pixels, times `size` / FEATURE_SIZE.
func _title_overlay(size: Vector2i) -> CanvasLayer:
	var k := float(size.x) / float(FEATURE_SIZE.x)
	var layer := CanvasLayer.new()
	layer.layer = 100
	var shade := Gradient.new()
	shade.set_color(0, Color(UiTokens.HUD_BG, 0.88))
	shade.set_color(1, Color(UiTokens.HUD_BG, 0.0))
	shade.add_point(0.55, Color(UiTokens.HUD_BG, 0.62))
	var band := GradientTexture2D.new()
	band.gradient = shade
	band.width = 512
	band.height = 4
	var band_rect := TextureRect.new()
	band_rect.texture = band
	band_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	band_rect.stretch_mode = TextureRect.STRETCH_SCALE
	band_rect.size = Vector2(size.x * 0.58, size.y)
	layer.add_child(band_rect)

	var title_font := FontVariation.new()
	title_font.base_font = load(UiFonts.CINZEL) as Font
	title_font.variation_opentype = {"wght": 700}
	title_font.spacing_glyph = int(round(2.0 * k))
	var title := LabelSettings.new()
	title.font = title_font
	title.font_size = int(round(50.0 * k))
	title.font_color = UiTokens.GOLD_BRIGHT
	title.outline_size = int(round(5.0 * k))
	title.outline_color = Color("#120d09")
	title.shadow_size = int(round(8.0 * k))
	title.shadow_color = Color(0, 0, 0, 0.45)
	title.shadow_offset = Vector2(0, 3.0 * k)
	var line_font := FontVariation.new()
	line_font.base_font = load(UiFonts.MONO) as Font
	line_font.variation_opentype = {"wght": 500}
	line_font.spacing_glyph = int(round(3.0 * k))
	var line := LabelSettings.new()
	line.font = line_font
	line.font_size = int(round(15.0 * k))
	line.font_color = UiTokens.HUD_TEXT
	line.outline_size = int(round(3.0 * k))
	line.outline_color = Color(UiTokens.HUD_BG, 0.8)

	var left := 64.0 * k
	var title_size := title_font.get_string_size("AgentEmpire", HORIZONTAL_ALIGNMENT_LEFT, -1, title.font_size)
	var top := size.y * 0.5 - (title_size.y + 34.0 * k) * 0.5
	var title_label := Label.new()
	title_label.text = "AgentEmpire"
	title_label.label_settings = title
	title_label.position = Vector2(left, top)
	layer.add_child(title_label)
	var rule := Control.new()
	rule.position = Vector2(left, top + title_size.y + 6.0 * k)
	rule.size = Vector2(title_size.x, 10.0 * k)
	rule.draw.connect(_draw_rule.bind(rule, k))
	layer.add_child(rule)
	var line_label := Label.new()
	line_label.text = "BUILD A TOWN IN AURELHAVEN"
	line_label.label_settings = line
	line_label.position = Vector2(left, top + title_size.y + 20.0 * k)
	layer.add_child(line_label)
	return layer


## A gold rule with a diamond at each end and in the middle, like the HUD's trim.
func _draw_rule(c: Control, k: float) -> void:
	var y := c.size.y * 0.5
	var gold := UiTokens.GOLD
	c.draw_line(Vector2(0, y), Vector2(c.size.x, y), Color(gold, 0.85), maxf(1.0, 1.5 * k), true)
	for x: float in [0.0, c.size.x * 0.5, c.size.x]:
		var d := 4.0 * k
		c.draw_colored_polygon(PackedVector2Array([Vector2(x, y - d), Vector2(x + d, y), Vector2(x, y + d), Vector2(x - d, y)]), gold)


# --- screenshots --------------------------------------------------------------------------------

func _shots_dir() -> String:
	return _repo_path("out/store/shots")


## Store screenshots at the window size, from the phone and tablet build (--mobile) on the
## renderer phones use: one per scene in --only (SHOT_SCENES by default), numbered in that order.
func _shots() -> void:
	if DisplayServer.get_name() == "headless" or not Platform.is_mobile():
		_fail("--shots needs a real window and --mobile --dpi=<n>")
		return
	if RenderingServer.get_current_rendering_method() != "mobile":
		_fail("--shots needs --rendering-method mobile, the renderer phones use")
		return
	var dims := _arg("size", "1920x1080").split("x")
	var size := Vector2i(int(dims[0]), int(dims[1]))
	await _fix_window(size)
	var game := root.get_node("Game")
	var main: Variant = load("res://game/main.tscn").instantiate()
	main.autostart = false
	root.add_child(main)
	await process_frame
	game.paused = true
	var w: SimWorld = game.new_town(int(_arg("seed", str(SEED))), "store")
	# Long enough for the demo town's training and building to finish, so no "is ready" or
	# "completed" toast lands on a later shot.
	DemoTown.build(w, 12, 100.0)
	print("store_art: the Keep has %d in training" % w.keep().queue.size())
	main.camera.input_enabled = false
	main.world_view.hover_id = 0
	# Two "+10" gains landing together overlap into a smudge.
	main.world_view.floating.visible = false
	# The scene frames a new town again a couple of frames after it starts: let that pass, so the
	# shots' own views are the ones that stand.
	main.camera.user_moved_since_frame = true
	for i in 3:
		await process_frame
	game.paused = false
	# The toasts from building the town ("Cottage completed." and so on) last about 4 seconds.
	await create_timer(4.5).timeout
	var prefix := _shots_dir().path_join("%dx%d" % [size.x, size.y])
	var scenes := _arg("only", ",".join(PackedStringArray(SHOT_SCENES))).split(",")
	for i in scenes.size():
		var frames: int = await _stage(scenes[i], main, w)
		if frames > 0:
			await _shot(size, "%s-%d-%s.png" % [prefix, i + 1, scenes[i]], frames)
		main.input.cancel_mode()
		main.hud.close_overlay()
		if main.hud.has_window():
			main.hud.close_window()
		main.selection.clear()


## Sets up one screenshot (SHOT_SCENES) and returns how many frames to let it settle, or 0 when
## it cannot be staged.
func _stage(scene: String, main: Variant, w: SimWorld) -> int:
	var k := w.keep()
	var keep := Vector3(k.center().x, 0.0, k.center().y)
	var folk := _townsfolk(w)
	match scene:
		"town":
			# Nothing selected, so the town in the middle of the whole screen.
			main.camera.set_view(keep + Vector3(0.0, 0.0, 1.5), 30.0, deg_to_rad(-20.0))
			main.camera.user_moved_since_frame = true
			return 30
		"keep":
			if w.ledger.can_afford(w.econ.unit_cost("townsfolk")):
				w.commands.push(GameCommands.train(k.id, "townsfolk"))
			main.selection.set_ids([k.id])
			_look_at(main, keep, 22.0, -20.0)
			return 45
		"group":
			# Everyone selected, framed on the Keep and the townsfolk inside the walls and at the
			# groves by their gates.
			main.selection.set_ids(folk)
			var points := PackedVector3Array([keep])
			for id: int in folk:
				var p := w.units[id].pos
				if p.distance_to(k.center()) <= GROUP_RADIUS:
					points.append(Vector3(p.x, 0.0, p.y))
			main.camera.frame(points, 24.0, 0.06, true, 40.0, deg_to_rad(-20.0))
			main.camera.user_moved_since_frame = true
			return 20
		"unit":
			# A townsperson farming, close up: the wheat is low and open, where trees, bushes by
			# the walls and the walls themselves hide gatherers from the town's view.
			var farmer: SimUnit = null
			for id: int in folk:
				if w.units[id].gather_kind == "farm":
					farmer = w.units[id]
			if farmer == null:
				_fail("unit: nobody works a farm")
				return 0
			main.selection.set_ids([farmer.id])
			_look_at(main, Vector3(farmer.pos.x, 0.0, farmer.pos.y), 11.0, -20.0)
			return 20
		"build":
			# A cottage being placed on open ground beside the Keep's square: the ghost starts in the
			# middle of the free part of the screen, where the camera puts the spot.
			var spot := DemoTown.find_spot(w, "cottage", Vector2i(k.center()) + Vector2i(-4, 3), 4)
			if spot == Pathing.NO_CELL:
				_fail("build: no room for a cottage near the Keep")
				return 0
			main.selection.set_ids(folk.slice(0, 3))
			_look_at(main, Vector3(spot.x + 1.0, 0.0, spot.y + 1.0), 26.0, -20.0)
			main.input.begin_placement("cottage")
			return 30
		"map":
			_look_at(main, keep + Vector3(0.0, 0.0, 1.5), 28.0, -20.0)
			if not main.hud.open_map():
				_fail("map: this layout has no minimap overlay")
				return 0
			return 20
		"help":
			main.hud.open_window(load("res://ui/hud/help_panel.gd").new())
			return 20
	_fail("no screenshot scene called %s" % scene)
	return 0


func _townsfolk(w: SimWorld) -> Array[int]:
	var out: Array[int] = []
	for u: SimUnit in w.units.values():
		if u.kind == "townsfolk":
			out.append(u.id)
	return out


## Points the camera at `at` from `distance` and `yaw_deg`, in the middle of the part of the screen
## the HUD leaves free (RtsCamera.focus), as the player's own view so the scene leaves it be.
func _look_at(main: Variant, at: Vector3, distance: float, yaw_deg: float) -> void:
	main.camera.set_view(at, distance, deg_to_rad(yaw_deg))
	main.camera.focus(at, true)
	main.camera.user_moved_since_frame = true


func _shot(size: Vector2i, path: String, frames: int) -> void:
	var img := await _capture(size, frames)
	img.convert(Image.FORMAT_RGB8)
	_save(img, path)


func _check_shots() -> void:
	var dir := _shots_dir()
	var found := 0
	for file in DirAccess.get_files_at(dir):
		if not file.ends_with(".png"):
			continue
		found += 1
		var path := dir.path_join(file)
		var head := _png_header(path)
		if head.is_empty():
			_fail("%s is not a PNG" % path)
			continue
		var long_side := maxi(head[0], head[1])
		var short_side := mini(head[0], head[1])
		_expect(head[3] == PNG_RGB and head[2] == 8, "%s is a 24-bit PNG without alpha" % file)
		_expect(short_side >= SHOT_MIN_PX and long_side <= SHOT_MAX_PX, "%s has sides from %d to %d px" % [file, SHOT_MIN_PX, SHOT_MAX_PX])
		_expect(long_side <= 2 * short_side, "%s is at most twice as long as it is high" % file)
		_expect(FileAccess.get_file_as_bytes(path).size() <= GRAPHIC_MAX_BYTES, "%s is under 8 MB" % file)
	_expect(found > 0, "screenshots in %s" % dir)


# --- capture ------------------------------------------------------------------------------------

func _fix_window(size: Vector2i) -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	for i in 3:
		await process_frame


## The window's picture after `frames` frames, keeping the window at `size` (the OS sometimes
## maximises it mid-run) and calling `each_frame` (if valid) every frame.
func _capture(size: Vector2i, frames: int, each_frame: Callable = Callable()) -> Image:
	var img: Image = null
	for attempt in 4:
		for i in frames:
			if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			if DisplayServer.window_get_size() != size:
				DisplayServer.window_set_size(size)
			if each_frame.is_valid():
				each_frame.call()
			await process_frame
		img = root.get_texture().get_image()
		if img.get_size() == size:
			break
		frames = 12
	return img


# --- checks -------------------------------------------------------------------------------------

func _expect(ok: bool, what: String) -> void:
	if ok:
		print("store_art: ok   " + what)
	else:
		_fail(what)


## The PNG's [width, height, bit depth, colour type] from its IHDR chunk, or [] if it is no PNG.
func _png_header(path: String) -> Array[int]:
	var b := FileAccess.get_file_as_bytes(path)
	if b.size() < 26 or b.slice(0, 8) != PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10]):
		return []
	var width := (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19]
	var height := (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23]
	return [width, height, b[24], b[25]]


## Checks one file: a PNG of `size` with `color_type` at 8 bits, no larger than `max_bytes`.
## Returns the image for the alpha checks, or null.
func _check_png(path: String, size: Vector2i, color_type: int, max_bytes: int) -> Image:
	var file := path.get_file()
	if not FileAccess.file_exists(path):
		_fail("%s exists" % path)
		return null
	var head := _png_header(path)
	if head.is_empty():
		_fail("%s is a PNG" % path)
		return null
	_expect(Vector2i(head[0], head[1]) == size, "%s is %dx%d" % [file, size.x, size.y])
	var kind := "32-bit PNG with alpha" if color_type == PNG_RGBA else "24-bit PNG without alpha"
	_expect(head[2] == 8 and head[3] == color_type, "%s is a %s" % [file, kind])
	var bytes := FileAccess.get_file_as_bytes(path).size()
	_expect(bytes <= max_bytes, "%s is %d KB, at most %d KB" % [file, bytes / 1024, max_bytes / 1024])
	return Image.load_from_file(path)


func _check_art(parts: IconParts) -> void:
	_expect(parts.size > 0.0 and parts.background != "" and not parts.motif.is_empty(), "%s splits into a background and a motif" % ICON_SVG)
	var icon := _check_png(_store_path(ICON_512), Vector2i(PLAY_ICON_PX, PLAY_ICON_PX), PNG_RGBA, ICON_MAX_BYTES)
	if icon != null:
		_expect(icon.detect_alpha() == Image.ALPHA_NONE, "%s is full bleed: every pixel opaque" % ICON_512)
	_check_png(_store_path(FEATURE), FEATURE_SIZE, PNG_RGB, GRAPHIC_MAX_BYTES)
	var legacy := _check_png(_launcher_path(LEGACY), Vector2i(LEGACY_PX, LEGACY_PX), PNG_RGBA, ICON_MAX_BYTES)
	if legacy != null:
		var mid := LEGACY_PX / 2
		_expect(legacy.get_pixel(0, 0).a == 0.0 and legacy.get_pixel(mid, mid).a == 1.0, "%s has transparent corners and an opaque middle" % LEGACY)
	var square := Vector2i(ADAPTIVE_PX, ADAPTIVE_PX)
	var fg := _check_png(_launcher_path(FOREGROUND), square, PNG_RGBA, ICON_MAX_BYTES)
	if fg != null:
		_check_safe_zone(fg, FOREGROUND, false)
	var bg := _check_png(_launcher_path(BACKGROUND), square, PNG_RGBA, ICON_MAX_BYTES)
	if bg != null:
		_check_field(bg, Color(parts.background))
	var mono := _check_png(_launcher_path(MONOCHROME), square, PNG_RGBA, ICON_MAX_BYTES)
	if mono != null:
		_check_safe_zone(mono, MONOCHROME, true)


## An adaptive layer's art: centred, inside the middle SAFE_ZONE_PX circle, transparent around
## it, and (`white`) white wherever it is not transparent.
func _check_safe_zone(img: Image, file: String, white: bool) -> void:
	var used := img.get_used_rect()
	var centre := Vector2(img.get_size()) * 0.5
	var off := (Vector2(used.position) + Vector2(used.size) * 0.5 - centre).abs()
	_expect(used.has_area() and off.x <= 1.0 and off.y <= 1.0, "%s has its art centred (off by %.1f, %.1f px)" % [file, off.x, off.y])
	var outside := 0
	var tinted := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a == 0.0:
				continue
			if centre.distance_to(Vector2(x + 0.5, y + 0.5)) > SAFE_ZONE_PX * 0.5:
				outside += 1
			if white and (c.r < 1.0 or c.g < 1.0 or c.b < 1.0):
				tinted += 1
	_expect(outside == 0, "%s keeps its art inside the middle %d px circle (%d pixels outside)" % [file, SAFE_ZONE_PX, outside])
	if white:
		_expect(tinted == 0, "%s is white on transparent (%d pixels not white)" % [file, tinted])


func _check_field(img: Image, colour: Color) -> void:
	var off := 0
	for y in img.get_height():
		for x in img.get_width():
			if not img.get_pixel(x, y).is_equal_approx(colour):
				off += 1
	_expect(off == 0, "%s is the icon's field %s, opaque (%d pixels differ)" % [BACKGROUND, colour.to_html(false), off])
