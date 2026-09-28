class_name MeshFactory
extends RefCounted
## Builds flat-shaded, vertex-coloured low-poly meshes from primitives. Every triangle gets its
## own vertices and face normal, which gives the faceted look. Faces are oriented away from an
## "inside" point, so winding mistakes cannot flip them.
##
## Several surfaces can go into one ArrayMesh: add parts, call end_surface(material), repeat.

## Applied to every point added after it is set (rotated or scaled parts).
var xform: Transform3D = Transform3D.IDENTITY

var _st: SurfaceTool
var _mesh: ArrayMesh
var _count: int = 0


func _init() -> void:
	_mesh = ArrayMesh.new()
	_begin()


func _begin() -> void:
	_st = SurfaceTool.new()
	_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_count = 0


## Closes the current surface with `material` and starts a new one.
func end_surface(material: Material) -> void:
	if _count > 0:
		_st.set_material(material)
		_st.commit(_mesh)
	_begin()


## Finishes and returns the mesh (the open surface gets `material`).
func commit(material: Material) -> ArrayMesh:
	end_surface(material)
	return _mesh


## A triangle facing away from `inner`.
func tri(a: Vector3, b: Vector3, c: Vector3, col: Color, inner: Vector3) -> void:
	a = xform * a
	b = xform * b
	c = xform * c
	var ii := xform * inner
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-14:
		return
	if n.dot((a + b + c) / 3.0 - ii) < 0.0:
		var t := b
		b = c
		c = t
		n = -n
	n = n.normalized()
	# Godot treats clockwise triangles as front-facing: emit a, c, b.
	_st.set_color(col)
	_st.set_normal(n)
	_st.add_vertex(a)
	_st.add_vertex(c)
	_st.add_vertex(b)
	_count += 3


func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color, inner: Vector3) -> void:
	tri(a, b, c, col, inner)
	tri(a, c, d, col, inner)


## Axis-aligned box. `top` (if set) colours the upper face.
func box(center: Vector3, size: Vector3, col: Color, top: Color = Color(0, 0, 0, 0)) -> void:
	var h := size * 0.5
	var x0 := center.x - h.x
	var x1 := center.x + h.x
	var y0 := center.y - h.y
	var y1 := center.y + h.y
	var z0 := center.z - h.z
	var z1 := center.z + h.z
	var tc := top if top.a > 0.0 else col
	quad(Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x0, y1, z1), tc, center)
	quad(Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1), col, center)
	quad(Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), col, center)
	quad(Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x0, y1, z0), col, center)
	quad(Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0), col, center)
	quad(Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x0, y1, z0), col, center)


## Vertical frustum from `base` (centre of the bottom) up by `h`.
func cylinder(base: Vector3, r_bottom: float, r_top: float, h: float, segments: int, col: Color,
		cap_top: bool = true, cap_bottom: bool = false, top_col: Color = Color(0, 0, 0, 0)) -> void:
	var inner := base + Vector3(0, h * 0.5, 0)
	var top := base + Vector3(0, h, 0)
	var tc := top_col if top_col.a > 0.0 else col
	for i in segments:
		var a0 := TAU * float(i) / float(segments)
		var a1 := TAU * float(i + 1) / float(segments)
		var d0 := Vector3(cos(a0), 0, sin(a0))
		var d1 := Vector3(cos(a1), 0, sin(a1))
		var p0 := base + d0 * r_bottom
		var p1 := base + d1 * r_bottom
		if r_top <= 0.0001:
			tri(p0, p1, top, col, inner)
		else:
			var q0 := top + d0 * r_top
			var q1 := top + d1 * r_top
			quad(p0, p1, q1, q0, col, inner)
			if cap_top:
				tri(top, q0, q1, tc, inner)
		if cap_bottom:
			tri(base, p0, p1, col, inner)


func cone(base: Vector3, r: float, h: float, segments: int, col: Color, cap_bottom: bool = true) -> void:
	cylinder(base, r, 0.0, h, segments, col, false, cap_bottom)


## Low-poly UV sphere.
func sphere(center: Vector3, r: float, rings: int, segments: int, col: Color, squash: Vector3 = Vector3.ONE) -> void:
	for j in rings:
		var t0 := PI * float(j) / float(rings)
		var t1 := PI * float(j + 1) / float(rings)
		for i in segments:
			var a0 := TAU * float(i) / float(segments)
			var a1 := TAU * float(i + 1) / float(segments)
			var p00 := center + _sph(t0, a0, r) * squash
			var p01 := center + _sph(t0, a1, r) * squash
			var p10 := center + _sph(t1, a0, r) * squash
			var p11 := center + _sph(t1, a1, r) * squash
			if j == 0:
				tri(p00, p10, p11, col, center)
			elif j == rings - 1:
				tri(p00, p10, p01, col, center)
			else:
				quad(p00, p10, p11, p01, col, center)


func _sph(theta: float, phi: float, r: float) -> Vector3:
	return Vector3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi)) * r


## Gable roof: base rectangle half-extents (hx, hz) at `base`, ridge along X (or Z) at height h.
func gable(base: Vector3, hx: float, hz: float, h: float, col: Color, ridge_along_x: bool = true, end_col: Color = Color(0, 0, 0, 0)) -> void:
	var ec := end_col if end_col.a > 0.0 else col
	var inner := base + Vector3(0, h * 0.3, 0)
	var y0 := base.y
	var yr := base.y + h
	if ridge_along_x:
		var x0 := base.x - hx
		var x1 := base.x + hx
		var z0 := base.z - hz
		var z1 := base.z + hz
		var zc := base.z
		quad(Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, yr, zc), Vector3(x0, yr, zc), col, inner)
		quad(Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, yr, zc), Vector3(x0, yr, zc), col, inner)
		tri(Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x0, yr, zc), ec, inner)
		tri(Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x1, yr, zc), ec, inner)
		quad(Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1), col.darkened(0.3), inner)
	else:
		var x0 := base.x - hx
		var x1 := base.x + hx
		var z0 := base.z - hz
		var z1 := base.z + hz
		var xc := base.x
		quad(Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(xc, yr, z1), Vector3(xc, yr, z0), col, inner)
		quad(Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(xc, yr, z1), Vector3(xc, yr, z0), col, inner)
		tri(Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(xc, yr, z0), ec, inner)
		tri(Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(xc, yr, z1), ec, inner)
		quad(Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1), col.darkened(0.3), inner)


## Four-sided pyramid roof.
func pyramid(base: Vector3, hx: float, hz: float, h: float, col: Color) -> void:
	var apex := base + Vector3(0, h, 0)
	var inner := base + Vector3(0, h * 0.25, 0)
	var c := [base + Vector3(-hx, 0, -hz), base + Vector3(hx, 0, -hz), base + Vector3(hx, 0, hz), base + Vector3(-hx, 0, hz)]
	for i in 4:
		tri(c[i], c[(i + 1) % 4], apex, col, inner)
	quad(c[0], c[1], c[2], c[3], col.darkened(0.3), inner)


## Flat ring lying on the ground (normals up), for selection rings and survey lines.
func ring_flat(center: Vector3, r_in: float, r_out: float, segments: int, col: Color) -> void:
	var below := center - Vector3(0, 1, 0)
	for i in segments:
		var a0 := TAU * float(i) / float(segments)
		var a1 := TAU * float(i + 1) / float(segments)
		var d0 := Vector3(cos(a0), 0, sin(a0))
		var d1 := Vector3(cos(a1), 0, sin(a1))
		quad(center + d0 * r_in, center + d1 * r_in, center + d1 * r_out, center + d0 * r_out, col, below)


## A flat triangle flag in the XY plane (visible from both sides).
func flag(pole_top: Vector3, w: float, h: float, col: Color) -> void:
	var a := pole_top
	var b := pole_top + Vector3(w, -h * 0.5, 0)
	var c := pole_top + Vector3(0, -h, 0)
	tri(a, b, c, col, a + Vector3(0, 0, -1))
	tri(a, b, c, col, a + Vector3(0, 0, 1))
