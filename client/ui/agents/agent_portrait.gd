class_name AgentPortrait
extends Control
## An agent's round portrait in the status-window style: the role's rendered bust on a navy disc,
## a ring coloured by what the agent is doing (it pulses while the agent waits on the player) and
## the rank badge at the lower right. With `clickable` it reacts to the mouse and emits `pressed`.

signal pressed()

## The mood of the ring: "working", "waiting" (on the player), "review", "blocked", "training",
## "idle" or "" (plain mint).
var mood: String = "":
	set(value):
		mood = value
		set_process(mood in PULSING)
		queue_redraw()
var role: String = "":
	set(value):
		role = value
		queue_redraw()
var rank: String = "":
	set(value):
		rank = value
		queue_redraw()
var show_rank: bool = true
var clickable: bool = false:
	set(value):
		clickable = value
		mouse_filter = Control.MOUSE_FILTER_STOP if value else Control.MOUSE_FILTER_IGNORE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if value else Control.CURSOR_ARROW

const PULSING := ["working", "waiting", "review"]

var _t: float = 0.0
var _hover: bool = false


func _init(px: float = 96.0) -> void:
	custom_minimum_size = Vector2(px, px)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	set_process(false)
	mouse_entered.connect(_on_hover.bind(true))
	mouse_exited.connect(_on_hover.bind(false))


## Role, rank and mood from an Agent object (and the player's pending business with it).
func set_agent(a: Dictionary, agent_mood: String = "") -> void:
	role = J.gs(a, "role")
	rank = J.gs(a, "rank", "F")
	mood = agent_mood


func _on_hover(on: bool) -> void:
	_hover = on and clickable
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if not clickable:
		return
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
		accept_event()
		pressed.emit()


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func ring_color() -> Color:
	match mood:
		"working":
			return UiTokens.MINT
		"waiting":
			return UiTokens.WARN
		"review":
			return UiTokens.GOLD_BRIGHT
		"blocked":
			return UiTokens.BAD
		"training":
			return Color("#8cc8ff")
		"idle":
			return UiTokens.GOLD
	return UiTokens.MINT


func _draw() -> void:
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.5 - 3.0
	var ring := ring_color()
	var pulse := 0.5 + 0.5 * sin(_t * (5.0 if mood == "waiting" else 2.6)) if mood in PULSING else 0.0
	# Halo.
	if pulse > 0.0 or _hover:
		var k := maxf(pulse, 0.8 if _hover else 0.0)
		for i in 3:
			draw_circle(c, r + 2.0 + float(i) * 2.0, Color(ring, 0.1 * k * (1.0 - float(i) / 3.0)))
	draw_circle(c, r, Color(0.07, 0.09, 0.22))
	draw_circle(c + Vector2(0, r * 0.35), r * 0.8, Color(0.11, 0.15, 0.33, 0.8))
	var tex := IconDraw.texture_for(AgentUi.role_icon(role))
	if tex != null and role != "":
		_draw_clipped(tex, c, r - 1.0)
	else:
		Glyph.paint(self, "person", Rect2(c - Vector2(r, r) * 0.6, Vector2(r, r) * 1.2), Color(UiTokens.MINT, 0.55))
	# Rim: a dark inner edge, the coloured ring and a small highlight arc.
	draw_arc(c, r - 1.5, 0.0, TAU, 64, Color(0, 0, 0, 0.35), 3.0, true)
	var ring_w := 2.5 if not _hover else 3.0
	draw_arc(c, r, 0.0, TAU, 64, Color(ring, 0.75 + 0.25 * pulse), ring_w, true)
	draw_arc(c, r + 1.8, PI * 1.08, PI * 1.62, 24, Color(1, 1, 1, 0.28), 1.0, true)
	if show_rank and rank != "":
		var bh := clampf(r * 0.46, 14.0, 30.0)
		var bw := bh * 1.1
		RankBadge.paint(self, rank, Rect2(Vector2(c.x + r * 0.72 - bw * 0.5, c.y + r * 0.72 - bh * 0.5), Vector2(bw, bh)))


func _draw_clipped(tex: Texture2D, c: Vector2, r: float) -> void:
	var pts := PackedVector2Array()
	var uvs := PackedVector2Array()
	for i in 48:
		var a := TAU * float(i) / 48.0
		var d := Vector2(cos(a), sin(a))
		pts.append(c + d * r)
		uvs.append(Vector2(0.5, 0.47) + d * 0.47)
	draw_colored_polygon(pts, Color.WHITE, uvs, tex)
