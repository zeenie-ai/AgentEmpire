"""Renders the 256x256 transparent PNG icons into client/art/icons/<id>.png.

    blender --background --factory-startup --python art_src/blender/render_icons.py -- [id ...]

Icons are rendered from the exported GLBs (so they show exactly what the client loads) with the
shared studio lighting of common.setup_studio: EEVEE, orthographic, yaw 45 / pitch 30, subject
filling about 80 percent of the frame. Characters get a head-and-shoulders portrait in their idle
pose from a lower, more frontal angle so the face reads. Resource icons: food (grain sack with
berries), wood (log pile), stone (stone pile), gold (a stack of coins modelled in bpy).
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ beside the scripts
sys.path.insert(0, str(Path(__file__).resolve().parent))

import bpy  # noqa: E402
import numpy as np  # noqa: E402

import common as C  # noqa: E402

SIZE = C.MANIFEST["icons"]["size"]
YAW, PITCH, FILL = 45.0, 30.0, 0.8
PORTRAIT_YAW, PORTRAIT_PITCH, PORTRAIT_FILL = 28.0, 8.0, 0.9
PORTRAIT_FRAME = 0.74  # frame height as a fraction of the character's height (same zoom for all)
# Extra icons for the selectable resource nodes (not required by the manifest, same naming rule).
NATURE_ICONS = {"tree_broadleaf": "tree_broadleaf", "tree_conifer": "tree_conifer",
                "bush_berries": "bush_berries", "rock": "rock_2"}


def model_icons() -> dict[str, str]:
    """icon id -> model stem, for every building and tool (variants use variant 0)."""
    out = {}
    for section in ("buildings", "tools"):
        for e in C.MANIFEST[section]:
            out[e["id"]] = f"{e['id']}_0" if "variants" in e else e["id"]
    out.update(NATURE_ICONS)
    return out


def import_mesh_objects(path: Path) -> list:
    return [o for o in C.import_gltf(path) if o.type == 'MESH']


def points(objs, evaluated=False) -> np.ndarray:
    return np.concatenate([C.world_coords(o, evaluated=evaluated) for o in objs if o.type == 'MESH'])


def render_icon(dest: Path, pts: np.ndarray, yaw=YAW, pitch=PITCH, fill=FILL, anchor="center", ortho=None) -> None:
    C.aim_camera(pts, yaw, pitch, fill=fill, anchor=anchor, ortho=ortho)
    tmp = C.tmp_path(dest.name)
    C.render_to(tmp)
    C.replace_into_place(tmp, dest)
    C.log(f"icon {dest.name}")


def icon_model(icon_id: str, stem: str) -> None:
    C.clear_objects()
    objs = import_mesh_objects(C.OUT_MODELS / f"{stem}.glb")
    render_icon(C.OUT_ICONS / f"{icon_id}.png", points(objs))


def icon_character(entry: dict) -> None:
    """Head-and-shoulders portrait in the idle pose. Every portrait uses the same zoom relative to
    the character's height; the top of the head (or hat) sits just under the top edge and the
    chest crops at the bottom (the tip of a tall hat may crop). Hand-held props are hidden."""
    C.clear_objects()
    objs = C.import_gltf(C.OUT_CHARACTERS / f"{entry['id']}.glb")
    rig = next(o for o in objs if o.type == 'ARMATURE')
    act = bpy.data.actions.get("Idle")
    ad = rig.animation_data or rig.animation_data_create()
    ad.action = act
    if hasattr(ad, "action_slot") and act.slots:
        ad.action_slot = act.slots[0]
    bpy.context.scene.frame_set(1)
    for o in objs:
        if o.type == 'MESH' and o.name.startswith("Prop_"):
            o.hide_render = True
    body = [o for o in objs if o.type == 'MESH' and o.name == "Mesh"]
    pts = points(body, evaluated=True)
    # frame the head region; tall headwear (the mage hat) may crop above 1.12 x height
    h = entry["height"]
    pts = pts[(pts[:, 2] > h * 0.55) & (pts[:, 2] < h * 1.12)]
    render_icon(C.OUT_ICONS / f"{entry['id']}.png", pts, PORTRAIT_YAW, PORTRAIT_PITCH, PORTRAIT_FILL,
                anchor="top", ortho=entry["height"] * PORTRAIT_FRAME)


def icon_resource(res: str) -> None:
    C.clear_objects()
    import build_models as BM
    if res == "food":
        # the kit's open crate of apples, with two apples rolled out in front
        objs = [o for o in C.import_gltf(C.src_path("medieval:decoration/props/crate_open.gltf")) if o.type == 'MESH']
        lp = C.LowPoly(seed=21)
        for x, y, r in ((0.02, -0.14, 0.032), (0.075, -0.12, 0.029)):
            lp.blob((x, y, r * 0.95), r, "red", subdiv=2, jitter=0.02, light=0.05, dark=0.75)
            lp.cylinder((x, y, r * 1.8), 0.004, 0.003, 0.018, 4, "wood", light=0.2, dark=0.6)
        objs.append(lp.to_object("Apples"))
    elif res == "wood":
        objs = import_mesh_objects(C.OUT_MODELS / "wood_pile.glb")
    elif res == "stone":
        objs = import_mesh_objects(C.OUT_MODELS / "stone_pile.glb")
    elif res == "gold":
        objs = [BM.model_coins()]
    else:
        raise ValueError(res)
    render_icon(C.OUT_ICONS / f"resource_{res}.png", points(objs))


def main() -> None:
    wanted = set(C.script_args())
    C.reset_scene()
    C.setup_studio(SIZE, SIZE, transparent=True, samples=64)
    for icon_id, stem in model_icons().items():
        if not wanted or icon_id in wanted:
            icon_model(icon_id, stem)
    for entry in C.MANIFEST["characters"]:
        if not wanted or entry["id"] in wanted:
            icon_character(entry)
    for res in ("food", "wood", "stone", "gold"):
        if not wanted or f"resource_{res}" in wanted:
            icon_resource(res)


if __name__ == "__main__":
    main()
