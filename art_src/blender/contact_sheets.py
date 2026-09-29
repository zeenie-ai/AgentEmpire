"""Renders labelled QA contact sheets of the exported art into out/art/*.png.

    blender --background --factory-startup --python art_src/blender/contact_sheets.py -- [category ...]

Categories: buildings construction tools nature props characters icons (default: all).
Every tile re-imports the exported GLB (not the Blender build scene), stands it on a grid of
1-unit tiles (its footprint in light green, a one-tile margin in dark green) and, for scale,
places townsfolk_a at the front-left corner. Camera: orthographic, yaw 45, pitch 30, the same
studio lighting as the icons.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ beside the scripts
sys.path.insert(0, str(Path(__file__).resolve().parent))

import bpy  # noqa: E402
import numpy as np  # noqa: E402

import common as C  # noqa: E402

TILE = 320
LABEL_H = 44
COLS = 5
BG = np.array([0.105, 0.098, 0.094, 1.0], dtype=np.float32)
TILE_BG = np.array([0.80, 0.82, 0.84, 1.0], dtype=np.float32)
GREEN = [(0.47, 0.60, 0.33), (0.43, 0.56, 0.30)]
GREEN_DARK = [(0.30, 0.40, 0.22), (0.27, 0.37, 0.20)]


def section_stems() -> dict[str, list[tuple[str, tuple[int, int] | None]]]:
    """category -> [(model stem, footprint or None)] in manifest order."""
    out: dict[str, list] = {}
    for section in ("buildings", "construction", "tools", "nature", "props"):
        items = []
        for e in C.MANIFEST[section]:
            fp = tuple(e["footprint"]) if "footprint" in e else None
            if "variants" in e:
                items += [(f"{e['id']}_{i}", fp) for i in range(len(e["variants"]))]
            else:
                items.append((e["id"], fp))
        out[section] = items
    return out


def material(name: str, rgb) -> bpy.types.Material:
    mat = bpy.data.materials.get(name)
    if mat is None:
        mat = bpy.data.materials.new(name)
        bsdf = next(n for n in mat.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')
        bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
        bsdf.inputs["Roughness"].default_value = 0.9
    return mat


def ground_grid(fx: int, fz: int, margin: int = 1) -> bpy.types.Object:
    """Checkerboard of 1-unit tiles: footprint light, margin dark; top surface at z = 0."""
    import bmesh
    bm = bmesh.new()
    mats = [material("g0", GREEN[0]), material("g1", GREEN[1]),
            material("d0", GREEN_DARK[0]), material("d1", GREEN_DARK[1])]
    x0, y0 = -fx / 2 - margin, -fz / 2 - margin
    for i in range(fx + 2 * margin):
        for j in range(fz + 2 * margin):
            inside = margin <= i < fx + margin and margin <= j < fz + margin
            idx = (0 if inside else 2) + ((i + j) % 2)
            xa, ya = x0 + i, y0 + j
            vs = [bm.verts.new((xa + dx, ya + dy, -0.002)) for dx, dy in ((0, 0), (1, 0), (1, 1), (0, 1))]
            f = bm.faces.new(vs)
            f.material_index = idx
    me = bpy.data.meshes.new("Ground")
    bm.to_mesh(me)
    bm.free()
    for m in mats:
        me.materials.append(m)
    ob = bpy.data.objects.new("Ground", me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def import_model(path: Path) -> list[bpy.types.Object]:
    objs = C.import_gltf(path)
    return objs


def pose_idle(objs, frame: int = 1) -> None:
    for ob in objs:
        if ob.type == 'ARMATURE':
            act = bpy.data.actions.get("Idle")
            if act is not None:
                ad = ob.animation_data or ob.animation_data_create()
                ad.action = act
                if hasattr(ad, "action_slot") and act.slots:
                    ad.action_slot = act.slots[0]
    bpy.context.scene.frame_set(frame)


def mesh_points(objs) -> np.ndarray:
    pts = [C.world_coords(o, evaluated=True) for o in objs if o.type == 'MESH' and o.visible_get()]
    return np.concatenate(pts) if pts else np.zeros((1, 3))


def render_tile(objs_focus, extra_frame=None, yaw=45.0, pitch=30.0, fill=0.86, size=TILE) -> np.ndarray:
    pts = mesh_points(objs_focus)
    if extra_frame is not None:
        pts = np.concatenate([pts, extra_frame])
    C.aim_camera(pts, yaw, pitch, fill=fill)
    tmp = C.tmp_path("tile.png")
    C.render_to(tmp)
    arr = C.load_png(tmp)
    tmp.unlink()
    bg = np.empty_like(arr)
    bg[:] = TILE_BG
    C.over(bg, arr, 0, 0)
    return bg


def label_tile(img: np.ndarray, title: str, sub: str = "") -> np.ndarray:
    h, w = img.shape[:2]
    out = np.empty((h + LABEL_H, w, 4), dtype=np.float32)
    out[:] = BG
    out[:h] = img
    C.over(out, C.text_image(title, w, 24, 17, (0.96, 0.9, 0.78, 1)), 0, h + 2)
    if sub:
        C.over(out, C.text_image(sub, w, 18, 12, (0.7, 0.68, 0.64, 1)), 0, h + 24)
    return out


def compose(tiles: list[np.ndarray], title: str, cols: int = COLS) -> np.ndarray:
    th = max(t.shape[0] for t in tiles)
    tw = max(t.shape[1] for t in tiles)
    gap, head = 10, 56
    rows = math.ceil(len(tiles) / cols)
    sheet = np.empty((head + rows * (th + gap) + gap, cols * (tw + gap) + gap, 4), dtype=np.float32)
    sheet[:] = BG
    C.over(sheet, C.text_image(title, sheet.shape[1], 40, 26, (0.93, 0.78, 0.42, 1)), 0, 8)
    for k, t in enumerate(tiles):
        r, c = divmod(k, cols)
        C.over(sheet, t, gap + c * (tw + gap), head + r * (th + gap))
    return sheet


def reference_villager() -> Path | None:
    p = C.OUT_CHARACTERS / "townsfolk_a.glb"
    return p if p.exists() else None


def sheet_models(category: str, items) -> None:
    tiles = []
    villager = reference_villager()
    for stem, fp in items:
        path = C.OUT_MODELS / f"{stem}.glb"
        if not path.exists():
            C.log(f"sheet {category}: missing {path.name}")
            continue
        C.clear_objects()
        objs = import_model(path)
        meshes = [o for o in objs if o.type == 'MESH']
        mn, mx = C.bounds(meshes)
        if fp is None:
            fp = (max(1, math.ceil(mx.x - mn.x - 1e-3)), max(1, math.ceil(mx.y - mn.y - 1e-3)))
        big = max(fp) >= 8
        ground_grid(*fp, margin=0 if big else 1)
        focus = list(meshes)
        if villager is not None and not stem.startswith(("cloud", "mountain")):
            vobjs = import_model(villager)
            rig = next(o for o in vobjs if o.type == 'ARMATURE')
            rig.location = (-fp[0] / 2 - 0.3, -fp[1] / 2 + 0.25, 0)
            pose_idle(vobjs)
            focus += [o for o in vobjs if o.type == 'MESH']
        # frame the footprint too, so the grid (and sinking/floating) stays in view
        corners = np.array([[sx * (fp[0] / 2 + 0.2), sy * (fp[1] / 2 + 0.2), 0] for sx in (-1, 1) for sy in (-1, 1)])
        img = render_tile(focus, corners)
        mesh = meshes[0]
        tris = sum(C.tri_count(o) for o in meshes)
        size = f"{mx.x - mn.x:.2f} x {mx.z - mn.z:.2f} x {mx.y - mn.y:.2f}"
        names = ",".join(sorted(o.name for o in meshes))
        tiles.append(label_tile(img, stem, f"{size}  {tris} tris  [{names}] fp {fp[0]}x{fp[1]}"))
    if tiles:
        dest = C.OUT_SHEETS / f"{category}.png"
        C.save_png(compose(tiles, f"Aurelhaven - {category}"), dest)
        C.log(f"wrote {dest}")


def sheet_characters() -> None:
    tiles = []
    for e in C.MANIFEST["characters"]:
        path = C.OUT_CHARACTERS / f"{e['id']}.glb"
        if not path.exists():
            C.log(f"sheet characters: missing {path.name}")
            continue
        C.clear_objects()
        ground_grid(1, 1)
        objs = import_model(path)
        pose_idle(objs)
        meshes = [o for o in objs if o.type == 'MESH']
        img = render_tile(meshes, yaw=30, pitch=14, fill=0.8)
        pts = mesh_points(meshes)
        clips = sorted(a.name for a in bpy.data.actions)
        tiles.append(label_tile(img, e["id"], f"h {pts[:, 2].max():.2f}  {len(clips)} clips  [{','.join(sorted(o.name for o in meshes))}]"))
    # line-up: every character in front of a cottage, for relative scale
    cottage = C.OUT_MODELS / "cottage_0.glb"
    if cottage.exists():
        C.clear_objects()
        ground_grid(6, 3, margin=0)
        C.import_gltf(cottage)
        for k, e in enumerate(C.MANIFEST["characters"]):
            path = C.OUT_CHARACTERS / f"{e['id']}.glb"
            if not path.exists():
                continue
            objs = import_model(path)
            rig = next(o for o in objs if o.type == 'ARMATURE')
            rig.location = (-2.6 + k * 0.65, -1.2, 0)
        pose_idle([o for o in bpy.data.objects])
        meshes = [o for o in bpy.data.objects if o.type == 'MESH' and o.name != "Ground"]
        bpy.context.scene.render.resolution_x = TILE * 2 + 10
        img = render_tile(meshes, yaw=20, pitch=12, fill=0.9, size=TILE * 2 + 10)
        bpy.context.scene.render.resolution_x = TILE
        tiles.append(label_tile(img, "line-up with cottage_0", "townsfolk 0.85, agents 0.95 (head top); cottage_0 about 2.0"))
    if tiles:
        # pad the wide line-up tile into the grid by splitting columns
        normal = [t for t in tiles if t.shape[1] == TILE]
        wide = [t for t in tiles if t.shape[1] != TILE]
        sheet = compose(normal, "Aurelhaven - characters")
        if wide:
            w = wide[0]
            extra = np.empty((w.shape[0] + 10, sheet.shape[1], 4), dtype=np.float32)
            extra[:] = BG
            C.over(extra, w, 10, 0)
            sheet = np.concatenate([sheet, extra], axis=0)
        dest = C.OUT_SHEETS / "characters.png"
        C.save_png(sheet, dest)
        C.log(f"wrote {dest}")


def sheet_icons() -> None:
    icons = sorted(C.OUT_ICONS.glob("*.png"))
    tiles = []
    panel = np.array([0.16, 0.12, 0.09, 1.0], dtype=np.float32)
    for p in icons:
        img = C.load_png(p)
        tile = np.empty((img.shape[0] + 16, img.shape[1] + 16, 4), dtype=np.float32)
        tile[:] = panel
        C.over(tile, img, 8, 8)
        tiles.append(label_tile(tile, p.stem, f"{img.shape[1]}x{img.shape[0]}"))
    if tiles:
        dest = C.OUT_SHEETS / "icons.png"
        C.save_png(compose(tiles, "Aurelhaven - icons", cols=7), dest)
        C.log(f"wrote {dest}")


def main() -> None:
    global TILE
    args = C.script_args()
    only = set()
    if "--only" in args:  # debugging: --only stem [stem ...] renders just those tiles
        i = args.index("--only")
        only = set(args[i + 1:])
        args = args[:i]
    if "--tile" in args:
        i = args.index("--tile")
        TILE = int(args[i + 1])
        args = args[:i] + args[i + 2:]
    wanted = args or ["buildings", "construction", "tools", "nature", "props", "characters", "icons"]
    C.reset_scene()
    C.setup_studio(TILE, TILE, transparent=True, samples=32)
    stems = section_stems()
    for cat in wanted:
        if cat in stems:
            items = [it for it in stems[cat] if not only or it[0] in only]
            sheet_models(cat if not only else f"debug_{cat}", items)
        elif cat == "characters":
            sheet_characters()
        elif cat == "icons":
            sheet_icons()
        else:
            raise SystemExit(f"unknown category {cat}")


if __name__ == "__main__":
    main()
