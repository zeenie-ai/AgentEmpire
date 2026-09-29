"""Builds every static model in art_src/manifest.json into client/art/models/*.glb + anchors.json.

    blender --background --factory-startup --python art_src/blender/build_models.py -- [stem ...]

With no stems every model is rebuilt; otherwise only the listed output stems (e.g. farm rock_2).
Each output holds ONE mesh object named 'Mesh' with the medieval kit's atlas material, scaled
uniformly, origin at the centre of its footprint on the ground, front facing +Z. The atlas is
not embedded: every GLB references the shared client/art/models/hexagons_medieval.png by URI.
"""
from __future__ import annotations

import json
import math
import random
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ beside the scripts
sys.path.insert(0, str(Path(__file__).resolve().parent))

import bmesh  # noqa: E402
import bpy  # noqa: E402
from mathutils import Euler, Matrix, Vector  # noqa: E402

import common as C  # noqa: E402

DEFAULT_FIT = 0.92
# Props with no size in the manifest use the cottage's fit scale (building_home_A into 2x2 * 0.92)
# so barrels, crates and stone piles keep the kit's proportions next to the buildings.
KIT_SCALE = 1.84 / 0.854
ADV = "adventurers:Assets/gltf/"
MED = "medieval:"

# Yaw (degrees) that turns a source's front to +Z. Every KayKit model used here already faces +Z
# (checked on front renders); a source that faced elsewhere would get its correction here.
FRONT_YAW: dict[str, float] = {}

# Door x offsets in model units (the door's centre along the front face); 0 = centred.
DOOR_X: dict[str, float] = {"cottage_1": 0.24, "storehouse": -0.2, "workshop": -0.78}


def by_id(section: str) -> dict:
    return {e["id"]: e for e in C.MANIFEST[section]}


# --- helpers ------------------------------------------------------------------------------------

def kit(ref: str, drop=()) -> bpy.types.Object:
    """Import a kit glTF (minus the named sub-objects) and join it into one 'Mesh'."""
    objs = C.import_gltf(C.src_path(ref))
    keep = []
    for o in objs:
        if o.name.split(".")[0] in drop:
            bpy.data.objects.remove(o, do_unlink=True)
        else:
            keep.append(o)
    return C.join_parts(keep)


def part(ref: str, name: str, loc=(0, 0, 0), rot=(0, 0, 0), scale=1.0, remap: bool = False) -> bpy.types.Object:
    """Import a kit glTF as one placed part (not yet joined). `remap` moves foreign UVs onto the atlas."""
    objs = C.import_gltf(C.src_path(ref))
    meshes = [o for o in objs if o.type == 'MESH']
    others = [o for o in objs if o.type != 'MESH']
    if remap:
        for o in meshes:
            img = next(n.image for n in o.active_material.node_tree.nodes if n.type == 'TEX_IMAGE' and n.image)
            C.remap_uvs_to_atlas(o, img)
    C.apply_transforms(meshes)
    C.select_only(meshes)
    if len(meshes) > 1:
        bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    for o in others:
        bpy.data.objects.remove(o, do_unlink=True)
    ob.name = name
    ob.rotation_mode = 'XYZ'  # the glTF importer leaves objects in quaternion mode
    s = scale if isinstance(scale, (tuple, list)) else (scale,) * 3
    ob.scale = s
    ob.rotation_euler = Euler([math.radians(a) for a in rot])
    ob.location = loc
    return ob


def ground_center(ob) -> None:
    """Move mesh data so its bounds are centred on x/y at the origin with the lowest point at z=0."""
    mn, mx = C.bounds(ob)
    ob.data.transform(Matrix.Translation((-(mn.x + mx.x) / 2, -(mn.y + mx.y) / 2, -mn.z)))


def canonical_order(bm) -> None:
    """Sort vertices and faces by position: some bmesh operators (extrude, hole filling) emit
    geometry in memory order, which would make rebuilt GLBs differ byte-for-byte between runs."""
    bm.verts.index_update()
    bm.faces.index_update()
    verts = sorted(bm.verts, key=lambda v: (round(v.co.x, 5), round(v.co.y, 5), round(v.co.z, 5), v.index))
    vrank = {v: i for i, v in enumerate(verts)}
    bm.verts.sort(key=lambda v: vrank[v])  # BMElemSeq.sort needs a numeric key
    faces = sorted(bm.faces, key=lambda f: tuple(round(c, 5) for c in f.calc_center_median()) + (len(f.verts), f.index))
    frank = {f: i for i, f in enumerate(faces)}
    bm.faces.sort(key=lambda f: frank[f])


def cap_cut(bm, edges, uv_layer, uv) -> None:
    """Fill the open boundary left by a bisect with triangles and give them one atlas colour."""
    boundary = [e for e in edges if isinstance(e, bmesh.types.BMEdge) and e.is_valid and e.is_boundary]
    if not boundary:
        return
    res = bmesh.ops.triangle_fill(bm, use_beauty=True, use_dissolve=False, edges=boundary)
    for f in res["geom"]:
        if isinstance(f, bmesh.types.BMFace):
            f.smooth = False
            for loop in f.loops:
                loop[uv_layer].uv = uv


def trim_box(ob, x0=None, x1=None, y0=None, y1=None, cap_swatch=None, cap_t=0.5) -> None:
    """Cut the mesh with vertical axis planes, discard what lies outside and cap the cuts.
    Coincident vertices are welded first so a closed part leaves closed loops to cap."""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-4)
    uv_layer = bm.loops.layers.uv.active
    cuts = []
    if x1 is not None:
        cuts.append(((x1, 0, 0), (1, 0, 0)))
    if x0 is not None:
        cuts.append(((x0, 0, 0), (-1, 0, 0)))
    if y1 is not None:
        cuts.append(((0, y1, 0), (0, 1, 0)))
    if y0 is not None:
        cuts.append(((0, y0, 0), (0, -1, 0)))
    for co, no in cuts:
        geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
        res = bmesh.ops.bisect_plane(bm, geom=geom, dist=1e-5, plane_co=co, plane_no=no, clear_outer=True)
        if cap_swatch:
            cap_cut(bm, res["geom_cut"], uv_layer, C.atlas_uv(cap_swatch, cap_t))
    for f in bm.faces:
        f.smooth = False
    canonical_order(bm)
    bm.to_mesh(ob.data)
    bm.free()
    clear_custom_normals(ob)


def clear_custom_normals(ob) -> None:
    me = ob.data
    if me.has_custom_normals:
        C.select_only([ob])
        with bpy.context.temp_override(object=ob, active_object=ob, selected_objects=[ob]):
            bpy.ops.mesh.customdata_custom_splitnormals_clear()
    for p in me.polygons:
        p.use_smooth = False
    me.update()


# --- modelled pieces (bpy, flat-shaded, coloured from the kit atlas) ---------------------------------

def model_bush(berries: bool) -> bpy.types.Object:
    """A low stylised bush: flat-shaded lumpy blobs in the kit's grass green, optional red berries.
    The bare (depleted) bush is the same shape in the darker half of the green gradient."""
    lp = C.LowPoly(seed=11)
    light, dark = (0.05, 0.95) if berries else (0.45, 1.0)
    blobs = [((0.0, 0.02, 0.2), 0.24, (1.25, 1.1, 0.95)),
             ((0.17, -0.1, 0.15), 0.17, (1.1, 1.0, 0.9)),
             ((-0.19, -0.06, 0.14), 0.16, (1.1, 1.05, 0.9)),
             ((0.08, 0.17, 0.14), 0.16, (1.0, 1.0, 0.9)),
             ((-0.1, 0.16, 0.24), 0.15, (1.0, 1.0, 0.95))]
    for c, r, s in blobs:
        lp.blob(c, r, "grass", scale=s, subdiv=1, jitter=0.1, light=light, dark=dark, flatten_bottom=0.0)
    if berries:
        spots = [(0.12, -0.24, 0.24), (-0.08, -0.25, 0.3), (0.26, -0.13, 0.2), (-0.27, -0.12, 0.2),
                 (0.02, -0.16, 0.4), (0.2, 0.05, 0.33), (-0.2, 0.08, 0.33), (0.08, 0.28, 0.25),
                 (-0.14, 0.28, 0.3), (0.3, 0.12, 0.14), (-0.3, 0.1, 0.13), (0.0, 0.06, 0.45),
                 (0.15, -0.02, 0.43), (-0.12, -0.02, 0.44)]
        for i, p in enumerate(spots):
            lp.blob(p, 0.042 + 0.008 * (i % 3), "red", subdiv=1, jitter=0.05, light=0.1, dark=0.75)
    return lp.to_object()


def model_scroll(lp: C.LowPoly | None = None, at=(0, 0, 0), s: float = 1.0, yaw: float = 0.0,
                 tie: str = "red", sides: int = 8) -> bpy.types.Object | None:
    """A rolled parchment scroll, 0.25 long at s=1, lying along x (then turned by `yaw` degrees)
    with wooden end knobs and a coloured tie. Adds to `lp` when given, else returns an object."""
    own = lp is None
    lp = lp or C.LowPoly()
    rz = Matrix.Rotation(math.radians(yaw), 3, 'Z')
    along = rz @ Matrix.Rotation(math.radians(90), 3, 'Y')
    at = Vector(at)
    r = 0.034 * s

    def seg(x0, radius, length, swatch, sides, light, dark):
        lp.cylinder(at + rz @ Vector((x0 * s, 0, r)), radius, radius, length * s, sides, swatch,
                    light=light, dark=dark, rot=along)

    seg(-0.09, r, 0.18, "parchment", sides, 0.1, 0.55)
    for x in (-0.11, 0.09):
        seg(x, 0.02 * s, 0.02, "wood", sides, 0.1, 0.6)
    if sides >= 8:
        for x in (-0.125, 0.11):
            seg(x, 0.012 * s, 0.015, "wood", 6, 0.1, 0.6)
    seg(-0.012, r + 0.005 * s, 0.024, tie, sides, 0.15, 0.6)
    return lp.to_object() if own else None


def model_stake() -> bpy.types.Object:
    """A short survey stake: square post with a pointed foot and a cloth tie with a short tail."""
    lp = C.LowPoly()
    w = 0.055
    lp.box((0, 0, 0.26), (w, w, 0.44), "sand", light=0.1, dark=0.75)
    lp.cylinder((0, 0, -0.06), 0.001, w * 0.7, 0.1, 4, "sand", light=0.6, dark=0.8,
                rot=Matrix.Rotation(math.radians(45), 3, 'Z'))
    lp.box((0, 0, 0.485), (w * 1.06, w * 1.06, 0.03), "wood", light=0.2, dark=0.5)
    lp.box((0, 0, 0.395), (w + 0.012, w + 0.012, 0.05), "flame", light=0.05, dark=0.35)
    tail = Matrix.Rotation(math.radians(-18), 3, 'Y')
    lp.box((0.045, -0.018, 0.36), (0.05, 0.008, 0.075), "flame", light=0.05, dark=0.45, rot=tail)
    lp.box((0.05, 0.018, 0.365), (0.045, 0.008, 0.06), "flame", light=0.1, dark=0.5,
           rot=Matrix.Rotation(math.radians(-8), 3, 'Y'))
    return lp.to_object()


def model_anvil(lp: C.LowPoly, at: Vector, s: float) -> None:
    """A blacksmith's anvil on a wooden block, in the kit's iron greys."""
    x, y, z = at
    lp.cylinder((x, y, z), 0.07 * s, 0.062 * s, 0.09 * s, 8, "wood", light=0.2, dark=0.8)
    z += 0.09 * s
    lp.box((x, y, z + 0.012 * s), (0.11 * s, 0.07 * s, 0.024 * s), "iron", light=0.1, dark=0.6)
    lp.box((x, y, z + 0.045 * s), (0.06 * s, 0.04 * s, 0.045 * s), "iron", light=0.2, dark=0.7)
    lp.box((x, y, z + 0.085 * s), (0.14 * s, 0.065 * s, 0.035 * s), "stone", light=0.05, dark=0.55)
    horn = Matrix.Rotation(math.radians(-90), 3, 'Y')
    lp.cylinder((x - 0.07 * s, y, z + 0.09 * s), 0.028 * s, 0.002, 0.06 * s, 6, "stone", light=0.1, dark=0.5, rot=horn)


def model_hearth(lp: C.LowPoly, at: Vector, s: float) -> None:
    """A stone forge hearth: raised stone bed with glowing coals, back wall and a short chimney."""
    x, y, z = at
    lp.box((x, y, z + 0.065 * s), (0.24 * s, 0.17 * s, 0.13 * s), "stone", light=0.15, dark=0.85)
    lp.box((x, y - 0.008 * s, z + 0.134 * s), (0.2 * s, 0.13 * s, 0.012 * s), "ember", light=0.0, dark=0.3)
    for i, (dx, dy) in enumerate(((-0.05, -0.03), (0.02, -0.04), (0.06, 0.01), (-0.02, 0.02), (0.0, -0.01))):
        lp.blob((x + dx * s, y + dy * s, z + 0.142 * s), 0.02 * s, "charcoal" if i % 2 else "ember",
                scale=(1.2, 1.0, 0.6), subdiv=1, jitter=0.15, light=0.0, dark=0.5)
    lp.box((x, y + 0.075 * s, z + 0.2 * s), (0.24 * s, 0.03 * s, 0.14 * s), "stone", light=0.1, dark=0.7)
    lp.box((x, y + 0.04 * s, z + 0.285 * s), (0.2 * s, 0.1 * s, 0.03 * s), "iron", light=0.2, dark=0.7)
    lp.cylinder((x, y + 0.05 * s, z + 0.3 * s), 0.045 * s, 0.035 * s, 0.12 * s, 6, "stone", light=0.1, dark=0.6)


def model_lectern(lp: C.LowPoly, at: Vector, s: float) -> tuple[Vector, float]:
    """A wooden reading stand; returns the centre of its sloped desk and the slope angle."""
    x, y, z = at
    lp.box((x, y, z + 0.008 * s), (0.13 * s, 0.1 * s, 0.016 * s), "wood", light=0.3, dark=0.8)
    lp.box((x, y, z + 0.022 * s), (0.08 * s, 0.07 * s, 0.014 * s), "wood", light=0.25, dark=0.7)
    lp.box((x, y, z + 0.13 * s), (0.036 * s, 0.036 * s, 0.21 * s), "wood", light=0.1, dark=0.7)
    slope = 28.0
    tilt = Matrix.Rotation(math.radians(slope), 3, 'X')  # desk faces up and toward the reader at -Y
    desk = Vector((x, y, z + 0.25 * s))
    lp.box(desk, (0.17 * s, 0.13 * s, 0.014 * s), "wood", light=0.05, dark=0.45, rot=tilt)
    lip = desk + tilt @ Vector((0, -0.066 * s, 0.012 * s))
    lp.box(lip, (0.17 * s, 0.012 * s, 0.02 * s), "wood", light=0.2, dark=0.6, rot=tilt)
    lp.box((x, y + 0.02 * s, z + 0.225 * s), (0.06 * s, 0.05 * s, 0.03 * s), "wood", light=0.3, dark=0.8)
    return desk, slope


def model_writing_desk(lp: C.LowPoly, at: Vector, s: float) -> Vector:
    """A small writing table with a sheet of parchment, an inkpot and a tall quill."""
    x, y, z = at
    top = z + 0.13 * s
    lp.box((x, y, top), (0.21 * s, 0.13 * s, 0.016 * s), "wood", light=0.05, dark=0.45)
    for dx in (-0.09, 0.09):
        for dy in (-0.05, 0.05):
            lp.box((x + dx * s, y + dy * s, z + 0.065 * s), (0.018 * s, 0.018 * s, 0.13 * s), "wood", light=0.3, dark=0.85)
    surface = top + 0.008 * s
    sheet = Matrix.Rotation(math.radians(-12), 3, 'Z')
    lp.box((x - 0.03 * s, y - 0.01 * s, surface + 0.002 * s), (0.1 * s, 0.075 * s, 0.004 * s), "parchment",
           light=0.0, dark=0.2, rot=sheet)
    ink = Vector((x + 0.06 * s, y + 0.025 * s, surface))
    lp.cylinder(ink, 0.022 * s, 0.017 * s, 0.028 * s, 8, "ink", light=0.0, dark=0.4)
    lp.cylinder(ink + Vector((0, 0, 0.028 * s)), 0.012 * s, 0.012 * s, 0.008 * s, 8, "ink", light=0.0, dark=0.3)
    lean = Matrix.Rotation(math.radians(-24), 3, 'Y') @ Matrix.Rotation(math.radians(10), 3, 'X')
    lp.cylinder(ink + Vector((0, 0, 0.012 * s)), 0.0035 * s, 0.003 * s, 0.07 * s, 4, "sand", light=0.1, dark=0.6, rot=lean)
    vane_c = ink + Vector((0, 0, 0.012 * s)) + lean @ Vector((0, 0, 0.13 * s))
    lp.blob(vane_c, 0.075 * s, "white", scale=(0.28, 0.07, 1.0), subdiv=1, jitter=0.03, light=0.0, dark=0.45)
    return Vector((x, y, surface))


def model_coins() -> bpy.types.Object:
    """A small stack of gold coins with a few loose ones (used for the gold resource icon)."""
    lp = C.LowPoly(seed=5)
    r, t = 0.1, 0.022
    stacks = [((0.0, 0.0), 6), ((0.19, 0.06), 3), ((-0.13, 0.13), 2)]
    for (cx, cy), n in stacks:
        for i in range(n):
            ox = lp.rng.uniform(-0.012, 0.012)
            oy = lp.rng.uniform(-0.012, 0.012)
            lp.cylinder((cx + ox, cy + oy, i * t), r, r, t * 0.92, 12, "gold", light=0.02, dark=0.55)
    lean = Matrix.Rotation(math.radians(70), 3, 'X') @ Matrix.Rotation(math.radians(20), 3, 'Z')
    lp.cylinder((0.13, -0.16, r * 0.96), r, r, t * 0.92, 12, "gold", light=0.0, dark=0.6, rot=lean)
    lp.cylinder((-0.2, -0.08, 0.0), r, r, t * 0.92, 12, "gold", light=0.05, dark=0.45)
    ob = lp.to_object()
    # coin faces bright gold, rims deep amber, so the stack reads as metal discs
    C.paint_faces(ob, "gold", 0.3, face_filter=lambda p: p.loop_total > 4)     # 12-gon caps
    C.paint_faces(ob, "gold", 0.97, face_filter=lambda p: p.loop_total == 4)   # rim quads
    return ob


def model_wheat_rows(lp: C.LowPoly, half: float, rows: int, per_row: int, z0: float, height: float) -> None:
    """Rows of wheat bunches across a square field of half-size `half`; rows run along x.
    Each bunch is five blades fanning out from one point, tips light gold, bases amber."""
    for r in range(rows):
        y = -half + (r + 0.5) * (2 * half / rows)
        for i in range(per_row):
            x = -half + (i + 0.5) * (2 * half / per_row) + (0.03 if r % 2 else -0.03)
            for b in range(5):
                a = b * (2 * math.pi / 5) + 0.4 * r + 0.9 * i
                h = height * (0.75 + 0.25 * (((i * 7 + b * 3 + r * 5) % 5) / 4))
                fan = Matrix.Rotation(math.radians(17), 3, 'X')
                rot = Matrix.Rotation(a, 3, 'Z') @ fan
                lp.cylinder((x, y, z0), 0.042, 0.004, h, 3, "gold", light=0.0, dark=0.85, rot=rot, cap=False)


# --- recipes: each returns the joined 'Mesh' in final model units ------------------------------------

def building(entry: dict, ref: str, stem: str | None = None) -> bpy.types.Object:
    ob = kit(ref)
    C.face_front(ob, FRONT_YAW.get(stem or entry["id"], 0.0))
    C.normalize(ob, C.footprint_scale(ob, entry["footprint"], entry.get("fit", DEFAULT_FIT)))
    return ob


def soil_plot(ob, thickness: float, stubble_above: float) -> None:
    """Keep only the plot's top surface (stubble removed), lower it until the plot is `thickness`
    tall and give it a clean vertical skirt down to the ground, closed on every side."""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-4)
    bm.normal_update()
    drop = [f for f in bm.faces if f.normal.z < 0.5 or any(v.co.z > stubble_above for v in f.verts)]
    bmesh.ops.delete(bm, geom=drop, context='FACES')
    # keep the largest connected region of the top surface
    seen, islands = set(), []
    for f in bm.faces:
        if f in seen:
            continue
        stack, isl = [f], []
        seen.add(f)
        while stack:
            g = stack.pop()
            isl.append(g)
            for e in g.edges:
                for h in e.link_faces:
                    if h not in seen:
                        seen.add(h)
                        stack.append(h)
        islands.append(isl)
    islands.sort(key=len, reverse=True)
    bmesh.ops.delete(bm, geom=[f for isl in islands[1:] for f in isl], context='FACES')
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context='VERTS')
    sink = min(v.co.z for v in bm.verts) - thickness
    bmesh.ops.translate(bm, verts=bm.verts, vec=(0, 0, -sink))
    uv_layer = bm.loops.layers.uv.active
    top_faces = list(bm.faces)
    boundary = [e for e in bm.edges if e.is_boundary]
    res = bmesh.ops.extrude_edge_only(bm, edges=boundary)
    for v in res["geom"]:
        if isinstance(v, bmesh.types.BMVert):
            v.co.z = 0.0
    rng = random.Random(2)
    for f in bm.faces:
        f.smooth = False
        uv = C.atlas_uv("umber", 0.7 + rng.uniform(-0.05, 0.05)) if f in top_faces else C.atlas_uv("umber", 0.95)
        for loop in f.loops:
            loop[uv_layer].uv = uv
    bm.normal_update()
    canonical_order(bm)
    bm.to_mesh(ob.data)
    bm.free()
    clear_custom_normals(ob)


def fill_holes(ob, max_sides: int = 0) -> None:
    """Close every open boundary loop (the gate's door-hinge notches and its open underside)."""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-4)
    uv_layer = bm.loops.layers.uv.active
    res = bmesh.ops.holes_fill(bm, edges=[e for e in bm.edges if e.is_boundary], sides=max_sides)
    for f in res["faces"]:
        f.smooth = False
        for loop in f.loops:
            loop[uv_layer].uv = C.atlas_uv("stone", 0.8)
    canonical_order(bm)
    bm.to_mesh(ob.data)
    bm.free()
    clear_custom_normals(ob)


def build_farm(entry: dict) -> bpy.types.Object:
    """The kit grain plot trimmed to a thin square of tilled soil with rows of wheat, inside a low
    palisade fence (the kit segment scaled down) with a gap in the middle of the front side."""
    fx, fz = entry["footprint"]
    fit = entry.get("fit", 1.0)
    half = fx * fit / 2  # 1.5
    field = kit(MED + "buildings/neutral/building_grain.gltf")
    a = 0.655  # half-size of the square inscribed in the kit's hexagon
    trim_box(field, -a, a, -a, a)
    soil_plot(field, thickness=0.055, stubble_above=0.262)  # the plot's top surface is at ~0.25
    inner = half - 0.1
    field.data.transform(Matrix.Scale(inner / a, 4))
    top = C.bounds(field)[1].z
    lp = C.LowPoly()
    model_wheat_rows(lp, inner - 0.12, rows=8, per_row=13, z0=top - 0.01, height=0.27)
    wheat = lp.to_object("Wheat")
    segs = []
    n = 5
    seg_len = 2 * (half - 0.03) / n
    fscale = seg_len / 1.155
    for side, (rot_z, fixed) in {"left": (0, -1), "right": (0, 1), "back": (90, 1), "front": (90, -1)}.items():
        for i in range(n):
            if side == "front" and i == n // 2:
                continue
            t = -(half - 0.03) + (i + 0.5) * seg_len
            o = part(MED + "buildings/neutral/fence_wood_straight.gltf", f"fence_{side}_{i}")
            o.data.transform(Matrix.Translation((1.0, 0, 0)))  # the segment sits at x=-1 in the kit
            o.scale = (fscale,) * 3
            o.rotation_euler = (0, 0, math.radians(rot_z))
            p = fixed * (half - 0.035)
            o.location = (p, t, 0) if rot_z == 0 else (t, p, 0)
            segs.append(o)
    ob = C.join_parts([field, wheat] + segs)
    C.normalize(ob, C.footprint_scale(ob, entry["footprint"], fit))
    return ob


def build_lectern(entry: dict) -> bpy.types.Object:
    """Reading stand with the kit's open book on its desk; a small crate with a closed tome."""
    lp = C.LowPoly()
    desk, slope = model_lectern(lp, Vector((-0.1, 0.0, 0.0)), 1.0)
    stand = lp.to_object("Stand")
    # The kit book stands upright facing -Y; tip it back so it lies open on the sloped desk.
    book = part(ADV + "spellbook_open.gltf", "Book", remap=True)
    s = 0.165 / 0.828
    book.scale = (s,) * 3
    book.rotation_euler = (math.radians(-(90 - slope)), 0, 0)
    book.location = desk + Matrix.Rotation(math.radians(slope), 3, 'X') @ Vector((0, 0.0, 0.024))
    crate = part(MED + "decoration/props/crate_A_small.gltf", "Crate", loc=(0.15, 0.04, 0), rot=(0, 0, 12))
    closed = part(ADV + "spellbook_closed.gltf", "Tome", remap=True)
    cs = 0.1 / 0.576
    closed.scale = (cs,) * 3
    closed.rotation_euler = (0, math.radians(90), math.radians(-15))
    closed.location = (0.15, 0.04, 0.14 + 0.147 * cs)
    ob = C.join_parts([stand, book, crate, closed])
    ground_center(ob)
    C.normalize(ob, C.footprint_scale(ob, entry["footprint"], DEFAULT_FIT))
    return ob


def build_quillworks(entry: dict) -> bpy.types.Object:
    """The kit tent sheltering a writing desk (parchment, inkpot, quill), a crate of scrolls beside."""
    tent = part(MED + "decoration/props/tent.gltf", "Tent", loc=(0, 0.1, 0))
    lp = C.LowPoly(seed=3)
    surface = model_writing_desk(lp, Vector((-0.05, -0.12, 0.0)), 1.0)
    model_scroll(lp, surface + Vector((-0.03, 0.035, 0)), 0.42, yaw=8, tie="blue")
    model_scroll(lp, (0.14, 0.2, 0.14), 0.45, yaw=35, tie="red")
    model_scroll(lp, (0.13, 0.23, 0.168), 0.45, yaw=-20, tie="gold")
    desk = lp.to_object("Desk")
    crate = part(MED + "decoration/props/crate_A_small.gltf", "Crate", loc=(0.14, 0.21, 0), rot=(0, 0, -10))
    ob = C.join_parts([tent, desk, crate])
    ground_center(ob)
    C.normalize(ob, C.footprint_scale(ob, entry["footprint"], DEFAULT_FIT))
    return ob


def build_forge(entry: dict) -> bpy.types.Object:
    """Weapon rack with a sword and an axe, a stone hearth with glowing coals, an anvil, a barrel."""
    rack = part(MED + "decoration/props/weaponrack.gltf", "Rack", loc=(-0.37, 0.03, 0))
    sword = part(ADV + "sword_1handed.gltf", "Sword", remap=True)
    ss = 0.2 / 1.775
    sword.scale = (ss,) * 3
    sword.rotation_euler = (math.radians(-14), 0, 0)
    sword.location = (-0.405, -0.03, 0.366 * ss + 0.005)
    axe = part(ADV + "axe_1handed.gltf", "Axe", remap=True)
    axs = 0.19 / 1.244
    axe.scale = (axs,) * 3
    axe.rotation_euler = (math.radians(-14), 0, math.radians(180))
    axe.location = (-0.33, -0.03, 0.273 * axs + 0.005)
    barrel = part(MED + "decoration/props/barrel.gltf", "Barrel", loc=(0.38, 0.02, 0))
    lp = C.LowPoly(seed=9)
    model_hearth(lp, Vector((-0.1, 0.03, 0.0)), 1.0)
    model_anvil(lp, Vector((0.15, -0.03, 0.0)), 1.0)
    smithy = lp.to_object("Smithy")
    ob = C.join_parts([rack, sword, axe, barrel, smithy])
    ground_center(ob)
    C.normalize(ob, C.footprint_scale(ob, entry["footprint"], DEFAULT_FIT))
    return ob


def build_archive(entry: dict) -> bpy.types.Object:
    """A long crate packed with scrolls, two small crates stacked behind it and a sack.
    (crate_long_empty filled with scrolls replaces crate_long_A, whose fruit read as a larder.)"""
    long_c = part(MED + "decoration/props/crate_long_empty.gltf", "Long", loc=(0, -0.02, 0))
    lp = C.LowPoly(seed=4)
    ties = ["red", "blue", "gold", "flame", "red", "blue", "gold", "red", "blue"]
    k = 0
    for half_x in (-0.095, 0.095):
        for layer, (count, z) in enumerate(((4, 0.07), (3, 0.108), (2, 0.146))):
            for j in range(count):
                x = half_x + (j - (count - 1) / 2) * 0.041
                model_scroll(lp, (x, -0.02, z), 0.6, yaw=90 + (6 if (j + layer) % 2 else -6),
                             tie=ties[k % len(ties)], sides=6)
                k += 1
    scrolls = lp.to_object("Scrolls")
    small = part(MED + "decoration/props/crate_B_small.gltf", "Small", loc=(0.1, 0.17, 0), rot=(0, 0, 8))
    small2 = part(MED + "decoration/props/crate_A_small.gltf", "Small2", loc=(0.1, 0.17, 0.14), rot=(0, 0, -6))
    sack = part(MED + "decoration/props/sack.gltf", "Sack", loc=(-0.12, 0.17, 0.0), rot=(0, 0, 80))
    ob = C.join_parts([long_c, scrolls, small, small2, sack])
    ground_center(ob)
    C.normalize(ob, C.footprint_scale(ob, entry["footprint"], DEFAULT_FIT))
    return ob


def build_waygate(entry: dict) -> bpy.types.Object:
    """The kit's gate arch without its door leaves and with the flanking wall stubs cut away."""
    ob = kit(MED + "buildings/neutral/wall_straight_gate.gltf",
             drop=("wall_straight_gate_door_left", "wall_straight_gate_door_right"))
    co = C.world_coords(ob)
    upper = co[co[:, 2] > 1.0]
    half = float(abs(upper[:, 0]).max()) + 0.005
    trim_box(ob, -half, half, cap_swatch="stone", cap_t=0.45)
    fill_holes(ob)
    C.normalize(ob, C.footprint_scale(ob, entry["footprint"], DEFAULT_FIT))
    return ob


def portal_anchor(ob) -> dict:
    """Centre (model space) and [width, height] of the waygate's opening, for the client's glow."""
    mn, mx = C.bounds(ob)
    y = (mn.y + mx.y) / 2
    right = ob.ray_cast(Vector((0, y, 0.3)), Vector((1, 0, 0)))
    left = ob.ray_cast(Vector((0, y, 0.3)), Vector((-1, 0, 0)))
    up = ob.ray_cast(Vector((0, y, 0.05)), Vector((0, 0, 1)))
    if not (right[0] and left[0] and up[0]):
        raise RuntimeError("waygate: could not measure the opening")
    width, height = right[1].x - left[1].x, up[1].z
    centre = Vector(((right[1].x + left[1].x) / 2, y, height / 2))
    return {"portal": {"center": C.to_model_space(centre), "size": [round(width, 4), round(height, 4)]}}


# Extra anchors beyond size/height/door/top, keyed by output stem.
EXTRA_ANCHORS = {"waygate": portal_anchor}


def build_broadleaf(ref: str, height: float) -> bpy.types.Object:
    """The rounder kit tree, its foliage moved from the conifer teal to the kit's grass green so
    it reads as a leafy tree next to the dark conifers."""
    ob = build_scaled(ref, height / height_of(ref), center="source")
    C.shift_swatch(ob, ["leaf", "leaf_b"], "grass")
    return ob


def build_flag(ref: str, height: float) -> bpy.types.Object:
    """The kit's blue pennant on a slim modelled pole with a gold finial (the kit pole is a plank)."""
    ob = kit(ref)
    C.weld(ob)
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    uv = bm.loops.layers.uv.active
    blue = {C.SWATCH["sky"], C.SWATCH["blue"], C.SWATCH["blue_b"]}

    def cell(f):
        us = [lp_[uv].uv for lp_ in f.loops]
        return C.cell_of_uv(sum(u.x for u in us) / len(us), sum(u.y for u in us) / len(us))

    bmesh.ops.delete(bm, geom=[f for f in bm.faces if cell(f) not in blue], context='FACES')
    bm.to_mesh(ob.data)
    bm.free()
    mn, mx = C.bounds(ob)
    cloth_len = mx.y - mn.y
    k = 0.46 / cloth_len
    # the attached edge (min y) goes to the pole; the cloth then flies toward +x, facing the front
    ob.data.transform(Matrix.Translation((0, 0, height - 0.04 - mx.z * k)) @ Matrix.Rotation(math.radians(-90), 4, 'Z')
                      @ Matrix.Scale(k, 4) @ Matrix.Translation((-(mn.x + mx.x) / 2, -mn.y, 0)))
    lp = C.LowPoly()
    lp.cylinder((0, 0, -0.05), 0.03, 0.024, height + 0.05, 8, "wood", light=0.1, dark=0.8)
    lp.blob((0, 0, height + 0.02), 0.04, "gold", subdiv=1, jitter=0.0, light=0.0, dark=0.6)
    pole = lp.to_object("Pole")
    ob = C.join_parts([ob, pole])
    clear_custom_normals(ob)
    return ob


def build_scaled(ref: str, scale: float, center: str = "bbox", ground: str = "source", rot_x: float = 0.0,
                 drop=()) -> bpy.types.Object:
    ob = kit(ref, drop=drop)
    if rot_x:
        ob.data.transform(Matrix.Rotation(math.radians(rot_x), 4, 'X'))
    if center == "source":
        mn, _ = C.bounds(ob)
        gz = mn.z if ground == "min" else 0.0
        ob.data.transform(Matrix.Scale(scale, 4) @ Matrix.Translation((0, 0, -gz)))
    else:
        C.normalize(ob, scale, ground=ground)
    return ob


def discard(ob) -> None:
    """Delete a probe object together with its mesh data (so no orphan keeps the name 'Mesh')."""
    me = ob.data
    bpy.data.objects.remove(ob, do_unlink=True)
    if me.users == 0:
        bpy.data.meshes.remove(me)


def height_of(ref: str) -> float:
    ob = kit(ref)
    h = C.bounds(ob)[1].z
    discard(ob)
    return h


def extent_of(ref: str, axis: str = "max", rot_x: float = 0.0) -> float:
    ob = kit(ref)
    if rot_x:
        ob.data.transform(Matrix.Rotation(math.radians(rot_x), 4, 'X'))
    mn, mx = C.bounds(ob)
    discard(ob)
    ext = {"x": mx.x - mn.x, "y": mx.y - mn.y, "z": mx.z - mn.z}
    return max(ext["x"], ext["y"]) if axis == "max" else ext[axis]


# --- the model list ---------------------------------------------------------------------------------

def model_table() -> list[tuple[str, callable]]:
    """(output stem, builder) for every static model, in manifest order."""
    table = []
    for e in C.MANIFEST["buildings"]:
        if e["id"] == "farm":
            table.append(("farm", lambda e=e: build_farm(e)))
        elif "variants" in e:
            for i, ref in enumerate(e["variants"]):
                table.append((f"{e['id']}_{i}", lambda e=e, ref=ref, i=i: building(e, ref, f"{e['id']}_{i}")))
        else:
            table.append((e["id"], lambda e=e: building(e, e["source"])))
    for e in C.MANIFEST["construction"]:
        table.append((e["id"], lambda e=e: building(e, e["source"])))
    tools = by_id("tools")
    table += [
        ("lectern", lambda: build_lectern(tools["lectern"])),
        ("quillworks", lambda: build_quillworks(tools["quillworks"])),
        ("forge", lambda: build_forge(tools["forge"])),
        ("rookery", lambda: building(tools["rookery"], MED + "buildings/blue/building_well_blue.gltf")),
        ("archive", lambda: build_archive(tools["archive"])),
        ("waygate", lambda: build_waygate(tools["waygate"])),
    ]
    nature = by_id("nature")
    tree_h = 2.2
    broad_ref = MED + "decoration/nature/tree_single_B.gltf"   # the rounder of the two kit trees
    conifer_ref = MED + "decoration/nature/tree_single_A.gltf"  # the pointed one
    table += [
        ("tree_broadleaf", lambda: build_broadleaf(broad_ref, tree_h)),
        ("tree_conifer", lambda: build_scaled(conifer_ref, tree_h / height_of(conifer_ref), center="source")),
        ("stump", lambda: build_scaled(MED + "decoration/nature/tree_single_B_cut.gltf",
                                       tree_h / height_of(broad_ref), center="source")),
        ("bush_berries", lambda: model_bush(True)),
        ("bush_bare", lambda: model_bush(False)),
    ]
    for i, ref in enumerate(nature["rock"]["variants"]):
        table.append((f"rock_{i}", lambda e=nature["rock"], ref=ref, i=i: building(e, ref, f"rock_{i}")))
    for i, ref in enumerate(nature["cloud"]["variants"]):
        table.append((f"cloud_{i}", lambda ref=ref: build_scaled(ref, 3.0, ground="min")))
    for i, ref in enumerate(nature["mountain"]["variants"]):
        table.append((f"mountain_{i}", lambda ref=ref: build_scaled(ref, 12.0 / extent_of(ref))))
    props = by_id("props")
    lumber = props["carry_wood"]["source"]
    sack_ref = props["carry_food"]["source"]
    table += [
        ("carry_wood", lambda: build_scaled(lumber, 0.35 / extent_of(lumber, "x"))),
        ("carry_food", lambda: build_scaled(sack_ref, 0.3 / extent_of(sack_ref, "z", rot_x=90), rot_x=90, ground="min")),
        ("carry_scroll", lambda: model_scroll()),
        ("wood_pile", lambda: build_scaled(lumber, 0.8 / extent_of(lumber, "x"))),
        ("stone_pile", lambda: build_scaled(props["stone_pile"]["source"], KIT_SCALE)),
        ("barrel", lambda: build_scaled(props["barrel"]["source"], KIT_SCALE)),
        ("crates", lambda: build_scaled(props["crates"]["source"], KIT_SCALE)),
        ("flag_blue", lambda: build_flag(props["flag_blue"]["source"], 1.1)),
        ("stake", lambda: model_stake()),
    ]
    return table


def build_one(stem: str, builder) -> dict:
    C.reset_scene()
    ob = builder()
    for o in list(bpy.data.objects):
        if o is not ob:
            bpy.data.objects.remove(o, do_unlink=True)
    for me in list(bpy.data.meshes):
        if me.users == 0:
            bpy.data.meshes.remove(me)
    ob.name = "Mesh"
    ob.data.name = "Mesh"
    if ob.name != "Mesh" or ob.data.name != "Mesh":
        raise RuntimeError(f"{stem}: could not name the object and mesh 'Mesh'")
    C.set_single_material(ob, C.atlas_material())
    dest = C.OUT_MODELS / f"{stem}.glb"
    C.export_glb([ob], dest, external_images={C.ATLAS_NAME: C.ATLAS_NAME + ".png"})
    info = C.anchors(ob, DOOR_X.get(stem, 0.0))
    if stem in EXTRA_ANCHORS:
        info.update(EXTRA_ANCHORS[stem](ob))
    C.log(f"{stem:15s} tris={C.tri_count(ob):6d} size={info['size']} -> {dest.name} ({dest.stat().st_size // 1024} KB)")
    return info


def main() -> None:
    wanted = set(C.script_args())
    table = model_table()
    C.write_shared_atlas(C.OUT_MODELS)
    unknown = wanted - {s for s, _ in table}
    if unknown:
        raise SystemExit(f"unknown model stems: {sorted(unknown)}")
    anchors = {}
    if C.OUT_ANCHORS.exists():
        anchors = json.loads(C.OUT_ANCHORS.read_text(encoding="utf-8"))
    for stem, builder in table:
        if wanted and stem not in wanted:
            continue
        anchors[stem] = build_one(stem, builder)
    valid = {s for s, _ in table}
    anchors = {k: v for k, v in anchors.items() if k in valid}
    C.write_json_atomic(anchors, C.OUT_ANCHORS)
    C.log(f"anchors.json: {len(anchors)} models")


if __name__ == "__main__":
    main()
