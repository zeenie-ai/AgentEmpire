"""Shared helpers for the AgentEmpire art pipeline (Blender 5.1, run headless).

Every build script is run as
    blender --background --factory-startup --python art_src/blender/<script>.py -- [args]
and imports this module from its own directory.

Model-space conventions (art_src/manifest.json): 1 unit = 1 tile, +Y up, the front faces +Z, and the
origin sits at the centre of the footprint on the ground. Blender itself is +Z up with the front
facing -Y; the glTF exporter maps Blender (x, y, z) to glTF (x, z, -y). All geometry work here is
done in Blender axes and converted only where model-space numbers are written (anchors.json).
"""
from __future__ import annotations

import json
import math
import os
import random
import sys
import time
from pathlib import Path

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector

BLENDER_DIR = Path(__file__).resolve().parent
ART_SRC = BLENDER_DIR.parent
REPO = ART_SRC.parent
MANIFEST = json.loads((ART_SRC / "manifest.json").read_text(encoding="utf-8"))


def source_root(rel: str) -> Path:
    """A vendored source root (manifest source_roots) under the repo. The vendor folder is
    git-ignored, so a git worktree (for example .wt/<name> inside the main checkout) has none
    of its own: the nearest ancestor that has it is used instead."""
    here = REPO / rel
    if here.exists():
        return here
    for parent in REPO.parents:
        if (parent / rel).exists():
            return parent / rel
    return here

OUT_MODELS = REPO / MANIFEST["outputs"]["models"]
OUT_CHARACTERS = REPO / MANIFEST["outputs"]["characters"]
OUT_ICONS = REPO / MANIFEST["outputs"]["icons"]
OUT_ANCHORS = REPO / MANIFEST["outputs"]["anchors"]
OUT_SHEETS = REPO / MANIFEST["outputs"]["contact_sheets"]
# Temporary files live under out/ (git-ignored, same volume as client/) so a rename is atomic
# and the Godot editor never sees a half-written .glb or .png inside client/.
TMP_DIR = REPO / "out" / "art" / ".tmp"

MEDIEVAL_ROOT = source_root(MANIFEST["source_roots"]["medieval"])
ATLAS_NAME = "hexagons_medieval"
ATLAS_PATH = MEDIEVAL_ROOT.parent.parent / "Textures" / "hexagons_medieval.png"
ATLAS_GRID = (8, 4)  # columns x rows of gradient swatches in every KayKit atlas

# Named swatches of the medieval atlas: (column, row), row 0 at the top of the image.
# Each swatch is a vertical gradient, light at the top and dark at the bottom.
SWATCH = {
    "ink": (0, 0), "white": (1, 0), "stone": (2, 0), "iron": (3, 0), "charcoal": (4, 0),
    "terracotta": (5, 0), "wood": (6, 0), "ember": (7, 0),
    "sky": (0, 1), "blue": (1, 1), "wood_b": (2, 1), "gold": (3, 1), "grass": (4, 1),
    "sand": (5, 1), "taupe": (6, 1), "earth": (7, 1),
    "olive": (0, 2), "leaf": (1, 2), "stone_b": (2, 2), "sand_b": (3, 2), "sand_c": (4, 2),
    "parchment": (5, 2), "flame": (6, 2), "coral": (7, 2),
    "blue_b": (0, 3), "red": (1, 3), "amber": (2, 3), "leaf_b": (3, 3), "orange": (4, 3),
    "linen": (5, 3), "taupe_b": (6, 3), "umber": (7, 3),
}


# --- arguments, logging, files --------------------------------------------------------------

def script_args() -> list[str]:
    """Arguments after the '--' separator on the Blender command line."""
    return sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def log(msg: str) -> None:
    print(f"[art] {msg}", flush=True)


def src_path(ref: str) -> Path:
    """'medieval:buildings/red/x.gltf' -> absolute path inside the fetched kit."""
    root_key, rel = ref.split(":", 1)
    path = source_root(MANIFEST["source_roots"][root_key]) / rel
    if not path.exists():
        raise FileNotFoundError(f"{ref} -> {path} (run: node scripts/fetch-assets.mjs)")
    return path


def tmp_path(name: str) -> Path:
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    return TMP_DIR / f"{os.getpid()}_{name}"


def replace_into_place(tmp: Path, dest: Path) -> None:
    """Atomically move a finished temporary file over its destination (retrying while locked)."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    if os.path.splitdrive(str(tmp.resolve()))[0].lower() != os.path.splitdrive(str(dest.resolve()))[0].lower():
        # a rename cannot cross volumes: stage a copy beside the destination, then rename that
        import shutil
        staged = dest.with_name(dest.name + ".part")
        shutil.copyfile(tmp, staged)
        tmp.unlink()
        tmp = staged
    for attempt in range(40):
        try:
            os.replace(tmp, dest)
            return
        except PermissionError:
            time.sleep(0.25)
    raise RuntimeError(f"could not replace {dest}: file stays locked")


def write_json_atomic(data, dest: Path) -> None:
    tmp = tmp_path(dest.name)
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    replace_into_place(tmp, dest)


def to_model_space(v) -> list[float]:
    """Blender (x, y, z) -> model space (x, y, z) as the glTF exporter writes it."""
    return [round(float(v[0]), 4), round(float(v[2]), 4), round(float(-v[1]), 4)]


# --- scene -----------------------------------------------------------------------------------

def reset_scene() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)


def clear_objects(keep_types=("CAMERA", "LIGHT")) -> None:
    """Remove every object except cameras and lights, all actions, and the data left orphaned."""
    for ob in list(bpy.data.objects):
        if ob.type not in keep_types:
            bpy.data.objects.remove(ob, do_unlink=True)
    for act in list(bpy.data.actions):
        bpy.data.actions.remove(act)
    for coll in (bpy.data.meshes, bpy.data.armatures, bpy.data.curves, bpy.data.materials, bpy.data.images):
        for block in list(coll):
            if block.users == 0:
                coll.remove(block)


def import_gltf(path) -> list[bpy.types.Object]:
    """Import a glTF/GLB file and return the objects it created."""
    before = set(bpy.data.objects)
    # disable_bone_shape: otherwise the importer adds an 'Icosphere' display shape for bones
    bpy.ops.import_scene.gltf(filepath=str(path), disable_bone_shape=True)
    return [o for o in bpy.data.objects if o not in before]


def select_only(objs) -> None:
    bpy.context.view_layer.update()
    for o in bpy.context.view_layer.objects:
        if o is not None:
            o.select_set(False)
    for o in objs:
        o.select_set(True)
    if objs:
        bpy.context.view_layer.objects.active = objs[0]


def apply_transforms(objs) -> None:
    """Bake location, rotation and scale into the mesh data of `objs` (parents are cleared first)."""
    meshes = [o for o in objs if o.type == 'MESH']
    bpy.context.view_layer.update()  # matrix_world is stale until the depsgraph re-evaluates
    for o in meshes:
        mw = o.matrix_world.copy()
        o.parent = None
        o.matrix_world = mw
        if o.data.users > 1:
            o.data = o.data.copy()
    select_only(meshes)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


def join_parts(objs, name: str = "Mesh", material=None) -> bpy.types.Object:
    """Join the mesh parts in `objs` into ONE object `name` with one atlas material.

    Transforms are applied first, non-mesh objects (empties) are deleted, UV layers are unified to
    'UVMap' and every face ends up on material slot 0.
    """
    meshes = [o for o in objs if o.type == 'MESH']
    others = [o for o in objs if o.type != 'MESH']
    if not meshes:
        raise ValueError("join_parts: no mesh objects")
    for o in meshes:
        if o.data.uv_layers:
            o.data.uv_layers[0].name = "UVMap"
            while len(o.data.uv_layers) > 1:
                o.data.uv_layers.remove(o.data.uv_layers[-1])
    apply_transforms(meshes)
    select_only(meshes)
    if len(meshes) > 1:
        bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    for o in others:
        bpy.data.objects.remove(o, do_unlink=True)
    ob.name = name
    ob.data.name = name
    set_single_material(ob, material or atlas_material())
    return ob


def set_single_material(ob, mat) -> None:
    me = ob.data
    me.polygons.foreach_set("material_index", np.zeros(len(me.polygons), dtype=np.int32))
    me.materials.clear()
    me.materials.append(mat)
    me.update()


# --- atlas material and images -----------------------------------------------------------------

def atlas_image() -> bpy.types.Image:
    img = bpy.data.images.get(ATLAS_NAME)
    if img is None or not img.get("aurel_atlas"):
        if img is not None:
            img.name = ATLAS_NAME + "_imported"
        img = bpy.data.images.load(str(ATLAS_PATH))
        img.name = ATLAS_NAME
        img["aurel_atlas"] = True
    return img


def make_texture_material(name: str, image: bpy.types.Image, roughness: float = 0.5) -> bpy.types.Material:
    """A Principled material with `image` as base colour (metallic 0), as the KayKit files use."""
    mat = bpy.data.materials.new(name)
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED')
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = roughness
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = image
    tex.interpolation = 'Linear'
    tex.location = (-400, 200)
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


def atlas_material() -> bpy.types.Material:
    """The one shared material of every static model: the medieval kit atlas, as in the kit."""
    mat = bpy.data.materials.get(ATLAS_NAME)
    if mat is not None and mat.get("aurel_atlas"):
        return mat
    if mat is not None:
        mat.name = ATLAS_NAME + "_imported"
    mat = make_texture_material(ATLAS_NAME, atlas_image())
    mat.name = ATLAS_NAME
    mat["aurel_atlas"] = True
    return mat


def image_to_array(img: bpy.types.Image) -> np.ndarray:
    """Pixels as float32 (H, W, 4), row 0 at the BOTTOM (Blender order), values as stored (sRGB)."""
    w, h = img.size
    px = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    return px.reshape(h, w, 4)


def swatch_rect(img_size, cell, grid=ATLAS_GRID):
    """Pixel rectangle (x0, x1, y0, y1) of swatch `cell`=(col,row) in Blender's bottom-up order."""
    w, h = img_size
    col, row = cell
    x0, x1 = col * w // grid[0], (col + 1) * w // grid[0]
    y0, y1 = h - (row + 1) * h // grid[1], h - row * h // grid[1]
    return x0, x1, y0, y1


def hex_to_rgb(hexcolor: str) -> np.ndarray:
    hexcolor = hexcolor.lstrip("#")
    return np.array([int(hexcolor[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], dtype=np.float32)


def srgb_to_linear(c):
    c = np.asarray(c, dtype=np.float32)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(np.asarray(c, dtype=np.float32), 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def recolor_swatches(image: bpy.types.Image, cells: dict, name: str | None = None) -> bpy.types.Image:
    """Return a recoloured COPY of an atlas: each listed swatch is re-dyed to a target colour.

    `cells` maps (col, row) -> '#rrggbb' (the mid tone of the new swatch). The swatch keeps its
    light-to-dark gradient and any inner detail strips: every pixel keeps its luminance ratio to
    the swatch mean (in linear light), applied to the target colour. Other swatches (skin, hair,
    eyes, metal) are untouched.
    """
    out = image.copy()
    out.name = name or (image.name + "_recolor")
    px = image_to_array(image).copy()
    lum_w = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
    for cell, hexcolor in cells.items():
        x0, x1, y0, y1 = swatch_rect(image.size, cell)
        region = px[y0:y1, x0:x1, :3]
        lin = srgb_to_linear(region)
        lum = lin @ lum_w
        ratio = lum / max(float(lum.mean()), 1e-4)
        target = srgb_to_linear(hex_to_rgb(hexcolor))
        # Compress the gradient for bright targets so the top of the swatch does not clip.
        peak = float(ratio.max())
        if peak > 1.0:
            k = min(1.0, (1.0 / max(float(target.max()), 1e-4) - 1.0) / (peak - 1.0))
            ratio = 1.0 + (ratio - 1.0) * k
        new = target[None, None, :] * ratio[..., None]
        px[y0:y1, x0:x1, :3] = linear_to_srgb(new)
    out.pixels.foreach_set(px.ravel())
    out.pack()
    return out


# --- colour matching onto the medieval atlas ----------------------------------------------------

def _oklab(rgb_srgb: np.ndarray) -> np.ndarray:
    lin = srgb_to_linear(rgb_srgb)
    m1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                   [0.2119034982, 0.6806757152, 0.1073833058],
                   [0.0883024619, 0.2817188376, 0.6299787005]], dtype=np.float32)
    m2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                   [1.9779984951, -2.4285922050, 0.4505937099],
                   [0.0259040371, 0.7827717662, -0.8086757660]], dtype=np.float32)
    lms = np.cbrt(lin @ m1.T)
    return lms @ m2.T


_PALETTE = None


def atlas_palette(samples: int = 48):
    """(colours_oklab [32, samples, 3], uv [32, samples, 2]) sampled down each swatch's centre."""
    global _PALETTE
    if _PALETTE is None:
        img = atlas_image()
        px = image_to_array(img)
        w, h = img.size
        cols, uvs = [], []
        for row in range(ATLAS_GRID[1]):
            for col in range(ATLAS_GRID[0]):
                x0, x1, y0, y1 = swatch_rect(img.size, (col, row))
                xs = (x0 + x1) // 2
                ys = np.linspace(y1 - 3, y0 + 2, samples).astype(int)  # top -> bottom
                cols.append(_oklab(px[ys, xs, :3]))
                uvs.append(np.stack([np.full(samples, (xs + 0.5) / w), (ys + 0.5) / h], axis=1))
        _PALETTE = (np.array(cols, dtype=np.float32), np.array(uvs, dtype=np.float32))
    return _PALETTE


def remap_uvs_to_atlas(ob: bpy.types.Object, src_image: bpy.types.Image) -> None:
    """Re-point the UVs of a part textured with another kit's atlas onto the medieval atlas.

    Each face picks the medieval swatch whose gradient best matches the colours it showed, and
    each corner then takes the closest shade inside that swatch, so the part keeps its look while
    sharing the one atlas material.
    """
    pal, pal_uv = atlas_palette()
    src = image_to_array(src_image)
    sh, sw = src.shape[:2]
    me = ob.data
    uv_layer = me.uv_layers.active.data
    n_loops = len(me.loops)
    uv = np.empty(n_loops * 2, dtype=np.float32)
    uv_layer.foreach_get("uv", uv)
    uv = uv.reshape(-1, 2)
    xs = np.clip((uv[:, 0] % 1.0) * sw, 0, sw - 1).astype(int)
    ys = np.clip((uv[:, 1] % 1.0) * sh, 0, sh - 1).astype(int)
    lab = _oklab(src[ys, xs, :3])  # (loops, 3)
    new_uv = uv.copy()
    for poly in me.polygons:
        idx = np.arange(poly.loop_start, poly.loop_start + poly.loop_total)
        d = ((lab[idx][:, None, None, :] - pal[None, :, :, :]) ** 2).sum(-1)  # loops x cells x samples
        best_cell = int(d.min(axis=2).sum(axis=0).argmin())
        best_s = d[:, best_cell, :].argmin(axis=1)
        new_uv[idx] = pal_uv[best_cell, best_s]
    uv_layer.foreach_set("uv", new_uv.ravel())
    me.update()


def cell_of_uv(u: float, v: float) -> tuple[int, int]:
    """(column, row) of the atlas swatch containing a UV (row 0 at the top of the image)."""
    col = int(min(max(u % 1.0, 0.0) * ATLAS_GRID[0], ATLAS_GRID[0] - 1))
    row = int(min(max(1.0 - v % 1.0, 0.0) * ATLAS_GRID[1], ATLAS_GRID[1] - 1))
    return col, row


def shift_swatch(ob, from_cells, to_cell, face_filter=None) -> int:
    """Move every face textured from one of `from_cells` onto `to_cell`, keeping each corner's
    relative position inside the swatch (so the gradient is preserved). Returns faces moved."""
    me = ob.data
    uv_layer = me.uv_layers.active.data
    to_col, to_row = SWATCH[to_cell] if isinstance(to_cell, str) else to_cell
    froms = {SWATCH[c] if isinstance(c, str) else tuple(c) for c in from_cells}
    moved = 0
    for poly in me.polygons:
        if face_filter is not None and not face_filter(poly):
            continue
        idx = range(poly.loop_start, poly.loop_start + poly.loop_total)
        u = sum(uv_layer[i].uv[0] for i in idx) / poly.loop_total
        v = sum(uv_layer[i].uv[1] for i in idx) / poly.loop_total
        col, row = cell_of_uv(u, v)
        if (col, row) not in froms:
            continue
        for i in idx:
            uu, vv = uv_layer[i].uv
            fu = uu * ATLAS_GRID[0] - col
            fv = (1.0 - vv) * ATLAS_GRID[1] - row
            uv_layer[i].uv = ((to_col + fu) / ATLAS_GRID[0], 1.0 - (to_row + fv) / ATLAS_GRID[1])
        moved += 1
    me.update()
    return moved


def paint_faces(ob, swatch, t: float, face_filter=None, jitter: float = 0.0, seed: int = 1) -> int:
    """Point every corner of the matching faces at one shade of a swatch (flat colour per face)."""
    rng = random.Random(seed)
    me = ob.data
    uv_layer = me.uv_layers.active.data
    n = 0
    for poly in me.polygons:
        if face_filter is not None and not face_filter(poly):
            continue
        uv = atlas_uv(swatch, t + rng.uniform(-jitter, jitter))
        for i in range(poly.loop_start, poly.loop_start + poly.loop_total):
            uv_layer[i].uv = uv
        n += 1
    me.update()
    return n


def weld(ob, dist: float = 1e-4) -> None:
    """Merge coincident vertices (the glTF importer splits them along UV and normal seams)."""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=dist)
    bm.to_mesh(ob.data)
    bm.free()
    ob.data.update()


def atlas_uv(swatch: str | tuple, t: float) -> tuple[float, float]:
    """UV of a point in a medieval swatch; t = 0 at the light top of the gradient, 1 at the dark bottom."""
    col, row = SWATCH[swatch] if isinstance(swatch, str) else swatch
    u = (col + 0.5) / ATLAS_GRID[0]
    t = min(max(t, 0.0), 1.0)
    v = 1.0 - (row + 0.04 + 0.92 * t) / ATLAS_GRID[1]
    return u, v


# --- geometry queries ------------------------------------------------------------------------------

def world_coords(ob: bpy.types.Object, evaluated: bool = False) -> np.ndarray:
    """(N, 3) world-space vertex positions of a mesh object (optionally after modifiers/armature)."""
    if evaluated:
        dg = bpy.context.evaluated_depsgraph_get()
        oe = ob.evaluated_get(dg)
        me = oe.to_mesh()
        co = np.empty(len(me.vertices) * 3, dtype=np.float64)
        me.vertices.foreach_get("co", co)
        mw = np.array(oe.matrix_world)
        oe.to_mesh_clear()
    else:
        me = ob.data
        co = np.empty(len(me.vertices) * 3, dtype=np.float64)
        me.vertices.foreach_get("co", co)
        mw = np.array(ob.matrix_world)
    co = co.reshape(-1, 3)
    return co @ mw[:3, :3].T + mw[:3, 3]


def bounds(objs, evaluated: bool = False) -> tuple[Vector, Vector]:
    if not isinstance(objs, (list, tuple, set)):
        objs = [objs]
    pts = np.concatenate([world_coords(o, evaluated) for o in objs if o.type == 'MESH'])
    return Vector(pts.min(axis=0)), Vector(pts.max(axis=0))


def tri_count(ob) -> int:
    ob.data.calc_loop_triangles()
    return len(ob.data.loop_triangles)


# --- normalisation -------------------------------------------------------------------------------

def footprint_scale(ob, footprint, fit: float) -> float:
    """Uniform scale that makes the ground bounds of `ob` fit footprint * fit (x by model z)."""
    mn, mx = bounds(ob)
    sx, sy = mx.x - mn.x, mx.y - mn.y
    fx, fz = footprint
    return min(fx * fit / sx, fz * fit / sy)


def normalize(ob, scale: float, ground: str = "source") -> None:
    """Scale uniformly and move the origin to the centre of the ground bounds.

    ground='source' keeps the kit's ground plane (z = 0 in the source, so trunks and fence posts
    that sink below it stay sunk); ground='min' puts the lowest vertex on the ground.
    """
    mn, mx = bounds(ob)
    cx, cy = (mn.x + mx.x) / 2, (mn.y + mx.y) / 2
    gz = mn.z if ground == "min" else 0.0
    ob.data.transform(Matrix.Scale(scale, 4) @ Matrix.Translation((-cx, -cy, -gz)))
    ob.data.update()


def face_front(ob, yaw_degrees: float) -> None:
    """Rotate about the up axis so the model's front faces +Z in model space (-Y in Blender)."""
    if yaw_degrees:
        ob.data.transform(Matrix.Rotation(math.radians(yaw_degrees), 4, 'Z'))
        ob.data.update()


def anchors(ob, door_x: float = 0.0) -> dict:
    """Model-space anchors: bounding size, height, door (front surface at door_x) and top point."""
    co = world_coords(ob)
    mn, mx = co.min(axis=0), co.max(axis=0)
    height = float(mx[2])
    probe_z = min(0.12, max(height * 0.25, 0.01))
    hit, loc, _normal, _index = ob.ray_cast(Vector((door_x, mn[1] - 1.0, probe_z)), Vector((0, 1, 0)))
    # a ray through an opening (the farm's fence gap) would hit the far side: use the front edge
    front_y = loc.y if hit and loc.y < (mn[1] + mx[1]) / 2 else float(mn[1])
    top = co[co[:, 2].argmax()]
    return {
        "size": [round(float(mx[0] - mn[0]), 4), round(float(mx[2] - mn[2]), 4), round(float(mx[1] - mn[1]), 4)],
        "height": round(height, 4),
        "door": to_model_space((door_x, front_y, 0.0)),
        "top": to_model_space(top),
    }


# --- low-poly modelling onto the atlas ----------------------------------------------------------

class LowPoly:
    """Accumulates flat-shaded low-poly primitives into one bmesh, UV-mapped onto atlas swatches.

    Each primitive takes a swatch name and a gradient range (light, dark): the part's highest
    vertices sample `light` and its lowest `dark`, so shading reads like the kit's gradients.
    """

    def __init__(self, seed: int = 7):
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.new("UVMap")
        self.rng = random.Random(seed)

    def _new_faces(self, verts):
        vset = set(verts)
        return [f for f in self.bm.faces if all(v in vset for v in f.verts)]

    def _paint(self, faces, swatch, light: float, dark: float, axis: Vector | None = None):
        axis = axis or Vector((0, 0, 1))
        hs = [v.co.dot(axis) for f in faces for v in f.verts]
        h0, h1 = min(hs), max(hs)
        span = max(h1 - h0, 1e-6)
        for f in faces:
            f.smooth = False
            for loop in f.loops:
                k = (loop.vert.co.dot(axis) - h0) / span  # 0 bottom .. 1 top
                loop[self.uv].uv = atlas_uv(swatch, dark + (light - dark) * k)

    def box(self, center, size, swatch, light=0.15, dark=0.7, rot: Matrix | None = None):
        m = Matrix.Translation(center) @ (rot or Matrix()).to_4x4() @ Matrix.Diagonal((*size, 1.0))
        res = bmesh.ops.create_cube(self.bm, size=1.0, matrix=m)
        faces = self._new_faces(res["verts"])
        self._paint(faces, swatch, light, dark)
        return faces

    def cylinder(self, base, radius_bottom, radius_top, height, segments, swatch, light=0.15, dark=0.7,
                 rot: Matrix | None = None, cap=True):
        """Cylinder or cone frustum standing on `base` (bottom centre), along +Z before `rot`."""
        m = Matrix.Translation(base) @ (rot or Matrix()).to_4x4() @ Matrix.Translation((0, 0, height / 2))
        res = bmesh.ops.create_cone(self.bm, cap_ends=cap, cap_tris=False, segments=segments,
                                    radius1=radius_bottom, radius2=radius_top, depth=height, matrix=m)
        faces = self._new_faces(res["verts"])
        axis = (rot or Matrix()).to_3x3() @ Vector((0, 0, 1))
        self._paint(faces, swatch, light, dark, axis)
        return faces

    def blob(self, center, radius, swatch, scale=(1, 1, 1), subdiv=1, jitter=0.12, light=0.1, dark=0.8,
             flatten_bottom: float | None = None):
        """A lumpy icosphere; `flatten_bottom` clamps vertices below that height (a flat base)."""
        res = bmesh.ops.create_icosphere(self.bm, subdivisions=subdiv, radius=radius)
        verts = res["verts"]
        for v in verts:
            j = 1.0 + self.rng.uniform(-jitter, jitter)
            v.co = Vector((v.co.x * scale[0] * j, v.co.y * scale[1] * j, v.co.z * scale[2] * j)) + Vector(center)
            if flatten_bottom is not None and v.co.z < flatten_bottom:
                v.co.z = flatten_bottom
        faces = self._new_faces(verts)
        self._paint(faces, swatch, light, dark)
        return faces

    def to_object(self, name: str = "Mesh") -> bpy.types.Object:
        me = bpy.data.meshes.new(name)
        bmesh.ops.remove_doubles(self.bm, verts=self.bm.verts, dist=1e-6)
        self.bm.normal_update()
        self.bm.to_mesh(me)
        self.bm.free()
        ob = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(ob)
        me.materials.append(atlas_material())
        for p in me.polygons:
            p.use_smooth = False
        return ob


# --- export -------------------------------------------------------------------------------------

_GLTF_PROPS = None


def _gltf_export_props() -> set:
    global _GLTF_PROPS
    if _GLTF_PROPS is None:
        _GLTF_PROPS = {p.identifier for p in bpy.ops.export_scene.gltf.get_rna_type().properties}
    return _GLTF_PROPS


def export_glb(objs, dest: Path, animations: bool = False, external_images: dict | None = None, **extra) -> Path:
    """Export `objs` (and nothing else) as a GLB to a temporary file, then rename it into place.

    `external_images` maps image names to relative URIs: those images are stored beside the GLB
    and referenced instead of embedded (see externalize_images).
    """
    opts = dict(
        export_format='GLB', use_selection=True, export_apply=not animations, export_yup=True,
        export_texcoords=True, export_normals=True, export_tangents=False, export_materials='EXPORT',
        export_image_format='AUTO', export_cameras=False, export_lights=False, export_extras=False,
        export_animations=animations, export_skins=animations, export_morph=False,
        export_vertex_color='NONE', export_attributes=False,
    )
    opts.update(extra)
    valid = _gltf_export_props()
    dropped = [k for k in opts if k not in valid]
    if dropped:
        log(f"export_glb: exporter has no option(s) {dropped}; ignored")
    opts = {k: v for k, v in opts.items() if k in valid}
    select_only(list(objs))
    tmp = tmp_path(dest.stem + ".glb")
    bpy.ops.export_scene.gltf(filepath=str(tmp), **opts)
    if not tmp.exists():
        raise RuntimeError(f"glTF exporter wrote nothing for {dest.name}")
    if external_images:
        externalize_images(tmp, external_images)
    replace_into_place(tmp, dest)
    return dest


def read_glb(path: Path) -> tuple[dict, bytes]:
    """(JSON dict, BIN chunk bytes) of a GLB file."""
    import struct
    data = path.read_bytes()
    magic, _version, _length = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67:
        raise ValueError(f"{path} is not a GLB")
    json_len, _ = struct.unpack_from("<II", data, 12)
    gj = json.loads(data[20:20 + json_len].decode("utf-8"))
    off = 20 + json_len
    binbuf = b""
    if off < len(data):
        bin_len, _ = struct.unpack_from("<II", data, off)
        binbuf = data[off + 8:off + 8 + bin_len]
    return gj, binbuf


def write_glb(path: Path, gj: dict, binbuf: bytes) -> None:
    import struct
    js = json.dumps(gj, separators=(",", ":")).encode("utf-8")
    js += b" " * (-len(js) % 4)
    binbuf = bytes(binbuf) + b"\0" * (-len(binbuf) % 4)
    total = 12 + 8 + len(js) + (8 + len(binbuf) if binbuf else 0)
    out = bytearray(struct.pack("<III", 0x46546C67, 2, total))
    out += struct.pack("<II", len(js), 0x4E4F534A) + js
    if binbuf:
        out += struct.pack("<II", len(binbuf), 0x004E4942) + binbuf
    path.write_bytes(bytes(out))


def externalize_images(path: Path, uris: dict) -> None:
    """Replace embedded images named in `uris` with relative-URI references (glTF 2.0 allows a GLB
    to point at external images) and drop their bytes from the BIN chunk. Every static model then
    shares one atlas file, which Godot imports once instead of extracting a copy per model."""
    gj, binbuf = read_glb(path)
    dropped = set()
    for img in gj.get("images", []):
        if img.get("name") in uris and "bufferView" in img:
            dropped.add(img.pop("bufferView"))
            img["uri"] = uris[img["name"]]
    if not dropped:
        raise RuntimeError(f"{path.name}: none of the images {sorted(uris)} found to externalize")
    remap, views, new_bin = {}, [], bytearray()
    for i, view in enumerate(gj["bufferViews"]):
        if i in dropped:
            continue
        start = view.get("byteOffset", 0)
        new_bin += b"\0" * (-len(new_bin) % 4)
        view = dict(view, byteOffset=len(new_bin))
        new_bin += binbuf[start:start + view["byteLength"]]
        remap[i] = len(views)
        views.append(view)
    gj["bufferViews"] = views
    for acc in gj.get("accessors", []):
        if "bufferView" in acc:
            acc["bufferView"] = remap[acc["bufferView"]]
        for key in ("indices", "values"):
            if key in acc.get("sparse", {}):
                acc["sparse"][key]["bufferView"] = remap[acc["sparse"][key]["bufferView"]]
    for img in gj.get("images", []):
        if "bufferView" in img:
            img["bufferView"] = remap[img["bufferView"]]
    new_bin += b"\0" * (-len(new_bin) % 4)
    gj["buffers"][0]["byteLength"] = len(new_bin)
    write_glb(path, gj, bytes(new_bin))


def write_shared_atlas(dest_dir: Path) -> Path:
    """Copy the kit atlas beside the static models (the file their GLBs reference)."""
    dest = dest_dir / (ATLAS_NAME + ".png")
    tmp = tmp_path(dest.name)
    tmp.write_bytes(ATLAS_PATH.read_bytes())
    replace_into_place(tmp, dest)
    return dest


# --- rendering: one studio setup for icons and contact sheets --------------------------------------

KEY_DIR = (-0.55, -0.85, 1.05)   # key light arrives from front-left-top (Blender axes)
FILL_DIR = (0.9, -0.2, 0.35)     # fill from the right
RIM_DIR = (0.3, 1.0, 0.8)        # rim from behind


def _sun(name, direction, energy, color, angle_deg, shadow=True):
    light = bpy.data.lights.new(name, 'SUN')
    light.energy = energy
    light.color = color
    light.angle = math.radians(angle_deg)
    light.use_shadow = shadow
    ob = bpy.data.objects.new(name, light)
    bpy.context.scene.collection.objects.link(ob)
    d = Vector(direction).normalized()
    ob.rotation_euler = (-d).to_track_quat('-Z', 'Y').to_euler()  # light travels along -d
    return ob


def setup_studio(width: int, height: int, transparent: bool = True, samples: int = 48) -> bpy.types.Scene:
    """EEVEE, orthographic, soft key light + fill + rim over a warm sky; identical for every render."""
    sc = bpy.context.scene
    sc.render.engine = 'BLENDER_EEVEE'
    sc.render.resolution_x, sc.render.resolution_y = width, height
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = transparent
    sc.render.image_settings.file_format = 'PNG'
    sc.render.image_settings.color_mode = 'RGBA'
    sc.render.image_settings.color_depth = '8'
    sc.render.filter_size = 1.2
    ee = sc.eevee
    for attr, val in (("taa_render_samples", samples), ("use_shadows", True), ("shadow_ray_count", 2),
                      ("shadow_step_count", 8), ("use_fast_gi", True), ("fast_gi_distance", 1.5),
                      ("use_raytracing", False), ("horizon_quality", 0.5)):
        if hasattr(ee, attr):
            try:
                setattr(ee, attr, val)
            except (TypeError, AttributeError):
                pass
    sc.view_settings.view_transform = 'Standard'
    sc.view_settings.look = 'None'
    sc.view_settings.exposure = 0.0
    sc.view_settings.gamma = 1.0
    world = bpy.data.worlds.get("Studio") or bpy.data.worlds.new("Studio")
    sc.world = world
    nt = world.node_tree
    bg = next(n for n in nt.nodes if n.type == 'BACKGROUND')
    bg.inputs["Color"].default_value = (0.62, 0.66, 0.74, 1.0)
    bg.inputs["Strength"].default_value = 0.55
    for ob in [o for o in bpy.data.objects if o.type == 'LIGHT']:
        bpy.data.objects.remove(ob, do_unlink=True)
    _sun("Key", KEY_DIR, 3.6, (1.0, 0.93, 0.84), 8.0, True)
    _sun("Fill", FILL_DIR, 0.9, (0.78, 0.85, 1.0), 20.0, False)
    _sun("Rim", RIM_DIR, 1.4, (1.0, 0.96, 0.9), 10.0, False)
    cam = bpy.data.objects.get("Camera")
    if cam is None:
        cam = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera"))
        sc.collection.objects.link(cam)
    cam.data.type = 'ORTHO'
    cam.data.clip_start = 0.01
    cam.data.clip_end = 1000.0
    sc.camera = cam
    return sc


def aim_camera(points: np.ndarray, yaw_deg: float, pitch_deg: float, fill: float = 0.8,
               anchor: str = "center", ortho: float | None = None) -> None:
    """Point the orthographic camera from yaw/pitch and frame `points` to `fill` of the frame.

    yaw 0 looks at the model's front (from Blender -Y); positive yaw moves the camera to the right.
    anchor='top' keeps the top of the points at the top margin and lets the bottom crop (portraits).
    `ortho` fixes the frame height in model units instead of fitting (consistent portrait zoom).
    The aspect ratio comes from the scene's render resolution.
    """
    sc = bpy.context.scene
    cam = sc.camera
    aspect = sc.render.resolution_x / sc.render.resolution_y
    yaw, pitch = math.radians(yaw_deg), math.radians(pitch_deg)
    d = Vector((math.sin(yaw) * math.cos(pitch), -math.cos(yaw) * math.cos(pitch), math.sin(pitch)))
    rot = (-d).to_track_quat('-Z', 'Y')
    right = rot @ Vector((1, 0, 0))
    up = rot @ Vector((0, 1, 0))
    pr = points @ np.array(right)
    pu = points @ np.array(up)
    w = float(pr.max() - pr.min())
    h = float(pu.max() - pu.min())
    center = Vector(points.mean(axis=0))
    cr = (pr.max() + pr.min()) / 2
    cu = (pu.max() + pu.min()) / 2
    if ortho is not None:
        frame_h = ortho
    else:
        frame_h = max(w / aspect, h) / fill
    scale = frame_h * max(aspect, 1.0)  # Blender's ortho_scale spans the larger render dimension
    if anchor == "top":
        margin = (1.0 - fill) / 2 * frame_h
        cu = float(pu.max()) + margin - frame_h / 2
    c0 = center - right * float(center @ right) - up * float(center @ up)
    target = c0 + right * float(cr) + up * float(cu)
    cam.location = target + d * 50.0
    cam.rotation_euler = rot.to_euler()
    cam.data.ortho_scale = scale


def render_to(path: Path) -> None:
    sc = bpy.context.scene
    sc.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)


# --- 2D images: load, save, labels -----------------------------------------------------------------

def load_png(path: Path) -> np.ndarray:
    """PNG -> float32 RGBA (H, W, 4), row 0 at the TOP."""
    img = bpy.data.images.load(str(path))
    arr = image_to_array(img)[::-1].copy()
    bpy.data.images.remove(img)
    return arr


def save_png(arr: np.ndarray, dest: Path) -> None:
    """float RGBA (row 0 at the top) -> PNG, written to a temp file and renamed into place."""
    h, w = arr.shape[:2]
    img = bpy.data.images.new("save_png_tmp", w, h, alpha=True)
    img.pixels.foreach_set(np.ascontiguousarray(arr[::-1], dtype=np.float32).ravel())
    tmp = tmp_path(dest.name)
    img.filepath_raw = str(tmp)
    img.file_format = 'PNG'
    img.save()
    bpy.data.images.remove(img)
    replace_into_place(tmp, dest)


def text_image(text: str, width: int, height: int, size: int, color=(1, 1, 1, 1)) -> np.ndarray:
    """Render a line of text with Blender's UI font; returns RGBA (row 0 at the top), transparent bg."""
    import blf
    import imbuf
    ib = imbuf.new((width, height))
    with blf.bind_imbuf(0, ib):
        blf.size(0, size)
        blf.color(0, *color)
        tw, th = blf.dimensions(0, text)
        blf.position(0, max(4, (width - tw) / 2), (height - size * 0.72) / 2, 0)
        blf.draw_buffer(0, text)
    tmp = tmp_path("label.png")
    imbuf.write(ib, filepath=str(tmp))
    arr = load_png(tmp)
    os.remove(tmp)
    return arr


def over(dst: np.ndarray, src: np.ndarray, x: int, y: int) -> None:
    """Alpha-composite `src` onto `dst` at (x, y) from the top-left, in place."""
    h, w = src.shape[:2]
    region = dst[y:y + h, x:x + w]
    a = src[..., 3:4]
    region[..., :3] = src[..., :3] * a + region[..., :3] * (1 - a)
    region[..., 3:4] = a + region[..., 3:4] * (1 - a)
