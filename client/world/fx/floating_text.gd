class_name FloatingText
extends Node3D
## "+10" labels that rise and fade over drop-offs. A small pool of Label3D nodes is reused.

const POOL := 24
const LIFE := 1.3
const RISE := 1.4

var _labels: Array[Label3D] = []
var _ages: Array[float] = []
var _next: int = 0


func _ready() -> void:
	var font := UiFonts.mono(700)
	for i in POOL:
		var l := Label3D.new()
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.fixed_size = false
		l.pixel_size = 0.012
		l.font = font
		l.font_size = 40
		l.outline_size = 10
		l.outline_modulate = Color(0.106, 0.078, 0.055, 0.9)
		l.visible = false
		add_child(l)
		_labels.append(l)
		_ages.append(LIFE)


func spawn(at: Vector3, text: String, color: Color) -> void:
	var l := _labels[_next]
	_ages[_next] = 0.0
	_next = (_next + 1) % POOL
	l.text = text
	l.modulate = color
	l.position = at
	l.set_meta("origin", at)
	l.visible = true


func _process(delta: float) -> void:
	for i in POOL:
		if _ages[i] >= LIFE:
			continue
		_ages[i] += delta
		var l := _labels[i]
		var t := _ages[i] / LIFE
		var origin: Vector3 = l.get_meta("origin")
		l.position = origin + Vector3(0, BuildingView.ease_out_cubic(t) * RISE, 0)
		l.modulate.a = 1.0 - t * t
		if _ages[i] >= LIFE:
			l.visible = false
