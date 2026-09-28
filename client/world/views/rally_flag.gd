class_name RallyFlag
extends Node3D
## The Keep's rally point: a small banner, shown while the Keep is selected.

var _mesh: MeshInstance3D
var _time: float = 0.0


func _ready() -> void:
	var f := MeshFactory.new()
	f.box(Vector3(0, 0.55, 0), Vector3(0.05, 1.1, 0.05), Palette.WOOD_DARK)
	f.flag(Vector3(0.025, 1.08, 0), 0.42, 0.3, Palette.GOLD)
	f.ring_flat(Vector3(0, 0.03, 0), 0.22, 0.3, 20, Palette.GOLD)
	_mesh = MeshInstance3D.new()
	_mesh.mesh = f.commit(ArtMaterials.base())
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)
	visible = false


func show_at(cell: Vector2i) -> void:
	position = Vector3(cell.x + 0.5, 0.0, cell.y + 0.5)
	visible = true


func _process(delta: float) -> void:
	if visible:
		_time += delta
		_mesh.rotation.y = sin(_time * 1.6) * 0.25
