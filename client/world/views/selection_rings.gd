class_name SelectionRings
extends MultiMeshInstance3D
## Selection and hover rings on the ground, all in one MultiMesh (the Compatibility renderer has
## no decals). Callers hand over the full list every frame.

const MAX_RINGS := 512
const LIFT := 0.035


func _ready() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = ModelLibrary.mesh("fx/ring")
	mm.instance_count = MAX_RINGS
	mm.visible_instance_count = 0
	multimesh = mm
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## entries: [[Vector3 position, float radius, Color colour], ...]
func set_rings(entries: Array) -> void:
	var n := mini(entries.size(), MAX_RINGS)
	for i in n:
		var e: Array = entries[i]
		var r: float = e[1]
		var p: Vector3 = e[0]
		multimesh.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(r, 1.0, r)), Vector3(p.x, LIFT, p.z)))
		multimesh.set_instance_color(i, e[2])
	multimesh.visible_instance_count = n
