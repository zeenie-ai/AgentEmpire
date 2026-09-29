class_name DecalRings
extends Node3D
## Selection and hover rings as Decals projected onto the ground (Forward+): they follow the
## terrain, sit under the grass and buildings' edges, and glow faintly at night. Units are on
## their own render layer (UnitView.LAYER), which the decals skip. Same interface as the
## MultiMesh SelectionRings used where decals are unavailable.

## The ring in WorldTextures.ring() sits at this fraction of the texture's radius.
const RING_AT := 0.86
const HEIGHT := 1.2

var _pool: Array[Decal] = []


## entries: [[Vector3 position, float radius, Color colour], ...]
func set_rings(entries: Array) -> void:
	while _pool.size() < entries.size():
		_pool.append(_make())
	for i in _pool.size():
		var d := _pool[i]
		if i >= entries.size():
			d.visible = false
			continue
		var e: Array = entries[i]
		var p: Vector3 = e[0]
		var r: float = e[1]
		var c: Color = e[2]
		var span := r / RING_AT * 2.0
		d.size = Vector3(span, HEIGHT, span)
		d.position = Vector3(p.x, 0.0, p.z)
		d.modulate = c
		d.visible = true


func _make() -> Decal:
	var d := Decal.new()
	d.texture_albedo = WorldTextures.ring()
	d.texture_emission = WorldTextures.ring_glow()
	d.emission_energy = 0.8
	d.albedo_mix = 1.0
	d.upper_fade = 0.35
	d.lower_fade = 0.35
	d.cull_mask = 1
	d.visible = false
	add_child(d)
	return d
