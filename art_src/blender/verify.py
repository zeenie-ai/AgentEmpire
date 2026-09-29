"""Re-imports every exported asset into a fresh Blender scene and checks it against the manifest.

    blender --background --factory-startup --python-exit-code 1 --python art_src/blender/verify.py

Static models: one object and one mesh, both named 'Mesh'; one material whose image is the shared
client/art/models/hexagons_medieval.png (referenced by URI, not embedded); ground
bounds inside footprint * fit and centred; nothing floating (lowest point at or below the ground);
anchors.json entry present and matching. Characters: one armature with handslot.r/l, skinned 'Mesh'
(plus Prop_* meshes), a material with an image, exactly the manifest clips, height near the target.
Icons: 256x256 RGBA with transparent corners. Writes out/art/verify_report.json; raises on failure.
"""
from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ beside the scripts
sys.path.insert(0, str(Path(__file__).resolve().parent))

import bpy  # noqa: E402
import numpy as np  # noqa: E402

import common as C  # noqa: E402
import build_models as BM  # noqa: E402
import render_icons as RI  # noqa: E402

EPS = 0.006


def glb_json(path: Path) -> dict:
    data = path.read_bytes()
    magic, _version, _length = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67:
        raise ValueError(f"{path.name} is not a GLB")
    chunk_len, chunk_type = struct.unpack_from("<II", data, 12)
    return json.loads(data[20:20 + chunk_len].decode("utf-8"))


def footprints() -> dict[str, tuple]:
    """stem -> (footprint, fit, centre_mode) for models whose ground bounds are constrained."""
    out = {}
    for section in ("buildings", "construction", "tools"):
        for e in C.MANIFEST[section]:
            fit = e.get("fit", BM.DEFAULT_FIT if section != "construction" else 1.0)
            fp = tuple(e["footprint"])
            if "variants" in e:
                for i in range(len(e["variants"])):
                    out[f"{e['id']}_{i}"] = (fp, fit)
            else:
                out[e["id"]] = (fp, fit)
    rock = next(e for e in C.MANIFEST["nature"] if e["id"] == "rock")
    for i in range(len(rock["variants"])):
        out[f"rock_{i}"] = (tuple(rock["footprint"]), BM.DEFAULT_FIT)
    return out


def material_image(mat) -> bpy.types.Image | None:
    if mat is None or mat.node_tree is None:
        return None
    for n in mat.node_tree.nodes:
        if n.type == 'TEX_IMAGE' and n.image is not None and n.outputs["Color"].is_linked:
            return n.image
    return None


def check_model(stem: str, fp_info, anchors: dict) -> dict:
    path = C.OUT_MODELS / f"{stem}.glb"
    res = {"file": path.name, "ok": True, "errors": []}

    def fail(msg):
        res["ok"] = False
        res["errors"].append(msg)

    if not path.exists():
        fail("missing")
        return res
    res["kb"] = path.stat().st_size // 1024
    images = glb_json(path).get("images", [])
    shared = C.ATLAS_NAME + ".png"
    if [i.get("uri") for i in images] != [shared] or not (C.OUT_MODELS / shared).exists():
        fail(f"expected one image referencing the shared {shared}, got {images}")
    C.clear_objects()
    objs = C.import_gltf(path)
    if len(objs) != 1 or objs[0].type != 'MESH':
        fail(f"expected one mesh object, got {[(o.name, o.type) for o in objs]}")
        return res
    ob = objs[0]
    if ob.name != "Mesh" or ob.data.name != "Mesh":
        fail(f"names object={ob.name} mesh={ob.data.name}")
    mats = [m for m in ob.data.materials]
    if len(mats) != 1 or mats[0] is None or not mats[0].name.startswith(C.ATLAS_NAME):
        fail(f"materials {[m.name if m else None for m in mats]}")
    img = material_image(mats[0] if mats else None)
    if img is None or img.size[0] == 0:
        fail("no base-colour image")
    else:
        res["image"] = f"{img.name} {img.size[0]}x{img.size[1]}"
    if not ob.data.uv_layers:
        fail("no UVs")
    mn, mx = C.bounds(ob)
    res["size"] = [round(mx.x - mn.x, 3), round(mx.z - mn.z, 3), round(mx.y - mn.y, 3)]
    res["tris"] = C.tri_count(ob)
    if mn.z > 0.001:
        fail(f"floating: lowest point {mn.z:.3f}")
    if mn.z < -0.3:
        fail(f"sunk too deep: lowest point {mn.z:.3f}")
    if fp_info is not None:
        (fx, fz), fit = fp_info
        if mx.x - mn.x > fx * fit + EPS or mx.y - mn.y > fz * fit + EPS:
            fail(f"ground bounds {mx.x - mn.x:.3f} x {mx.y - mn.y:.3f} exceed footprint {fx}x{fz} * {fit}")
        if abs(mx.x + mn.x) / 2 > EPS or abs(mx.y + mn.y) / 2 > EPS:
            fail(f"not centred: ({(mx.x + mn.x) / 2:.3f}, {(mx.y + mn.y) / 2:.3f})")
    a = anchors.get(stem)
    if a is None:
        fail("no anchors.json entry")
    else:
        if any(abs(p - q) > 0.01 for p, q in zip(a["size"], res["size"])):
            fail(f"anchors size {a['size']} != measured {res['size']}")
        if abs(a["height"] - mx.z) > 0.01:
            fail(f"anchors height {a['height']} != {mx.z:.3f}")
    return res


def check_character(entry: dict) -> dict:
    path = C.OUT_CHARACTERS / f"{entry['id']}.glb"
    res = {"file": path.name, "ok": True, "errors": []}

    def fail(msg):
        res["ok"] = False
        res["errors"].append(msg)

    if not path.exists():
        fail("missing")
        return res
    res["kb"] = path.stat().st_size // 1024
    gj = glb_json(path)
    clips = sorted(a.get("name", "") for a in gj.get("animations", []))
    res["clips"] = clips
    want = sorted(C.MANIFEST["character_animations"])
    if clips != want:
        fail(f"clips differ: missing {sorted(set(want) - set(clips))}, extra {sorted(set(clips) - set(want))}")
    C.clear_objects()
    objs = C.import_gltf(path)
    rigs = [o for o in objs if o.type == 'ARMATURE']
    meshes = [o for o in objs if o.type == 'MESH']
    if len(rigs) != 1:
        fail(f"expected one armature, got {len(rigs)}")
        return res
    rig = rigs[0]
    bones = [b.name for b in rig.data.bones]
    res["bones"] = len(bones)
    for hb in ("handslot.r", "handslot.l", "hand.r", "hand.l", "head"):
        if hb not in bones:
            fail(f"bone {hb} missing")
    names = sorted(o.name for o in meshes)
    res["meshes"] = names
    if "Mesh" not in names or any(n != "Mesh" and not n.startswith("Prop_") for n in names):
        fail(f"mesh names {names}")
    for o in meshes:
        if not any(m.type == 'ARMATURE' and m.object == rig for m in o.modifiers):
            fail(f"{o.name} is not skinned to the rig")
        if material_image(o.active_material) is None:
            fail(f"{o.name} has no textured material")
    act = bpy.data.actions.get("Idle")
    ad = rig.animation_data or rig.animation_data_create()
    ad.action = act
    if act is not None and hasattr(ad, "action_slot") and act.slots:
        ad.action_slot = act.slots[0]
    bpy.context.scene.frame_set(1)
    body = next(o for o in meshes if o.name == "Mesh")
    pts = C.world_coords(body, evaluated=True)
    top, low = float(pts[:, 2].max()), float(pts[:, 2].min())
    res["height_idle"] = round(top, 3)
    res["tris"] = sum(C.tri_count(o) for o in meshes)
    if not (entry["height"] * 0.95 <= top <= entry["height"] * 1.3):
        fail(f"idle height {top:.3f} vs target {entry['height']}")
    if abs(low) > 0.03:
        fail(f"feet not on the ground: lowest {low:.3f}")
    return res


def check_icon(icon_id: str) -> dict:
    path = C.OUT_ICONS / f"{icon_id}.png"
    res = {"file": path.name, "ok": True, "errors": []}
    if not path.exists():
        res["ok"] = False
        res["errors"].append("missing")
        return res
    img = C.load_png(path)
    h, w = img.shape[:2]
    a = img[..., 3]
    ys, xs = np.nonzero(a > 0.5)
    cover = (max(xs.max() - xs.min(), ys.max() - ys.min()) + 1) / max(w, h) if len(xs) else 0.0
    res.update(size=f"{w}x{h}", fill=round(float(cover), 2), kb=path.stat().st_size // 1024)
    if (w, h) != (RI.SIZE, RI.SIZE):
        res["ok"] = False
        res["errors"].append(f"size {w}x{h}")
    if max(a[0, 0], a[0, -1], a[-1, 0], a[-1, -1]) > 0.01:
        res["ok"] = False
        res["errors"].append("corners not transparent")
    if not 0.5 <= cover <= 1.0:
        res["ok"] = False
        res["errors"].append(f"subject fills {cover:.2f} of the frame")
    return res


def main() -> None:
    C.reset_scene()
    anchors = json.loads(C.OUT_ANCHORS.read_text(encoding="utf-8")) if C.OUT_ANCHORS.exists() else {}
    fps = footprints()
    report = {"models": {}, "characters": {}, "icons": {}}
    for stem, _builder in BM.model_table():
        report["models"][stem] = check_model(stem, fps.get(stem), anchors)
    for entry in C.MANIFEST["characters"]:
        report["characters"][entry["id"]] = check_character(entry)
    icon_ids = list(RI.model_icons()) + [e["id"] for e in C.MANIFEST["characters"]] + \
        [f"resource_{r}" for r in ("food", "wood", "stone", "gold")]
    for icon_id in icon_ids:
        report["icons"][icon_id] = check_icon(icon_id)
    extra = sorted(set(p.stem for p in C.OUT_MODELS.glob("*.glb")) - set(report["models"]))
    if extra:
        report["unexpected_models"] = extra
    # only the files this pipeline writes (Godot adds .import files and extracted textures beside them)
    ours = {"models": list(C.OUT_MODELS.glob("*.glb")) + [C.OUT_ANCHORS, C.OUT_MODELS / (C.ATLAS_NAME + ".png")],
            "characters": list(C.OUT_CHARACTERS.glob("*.glb")),
            "icons": list(C.OUT_ICONS.glob("*.png"))}
    sizes = {k: sum(p.stat().st_size for p in v if p.exists()) for k, v in ours.items()}
    report["bytes"] = sizes
    C.write_json_atomic(report, C.OUT_SHEETS / "verify_report.json")
    failures = [(cat, k, r["errors"]) for cat in ("models", "characters", "icons") for k, r in report[cat].items() if not r["ok"]]
    for cat in ("models", "characters", "icons"):
        for k, r in report[cat].items():
            detail = {kk: vv for kk, vv in r.items() if kk not in ("ok", "errors", "file", "clips")}
            C.log(f"{'OK  ' if r['ok'] else 'FAIL'} {cat[:-1]:9s} {k:16s} {detail} {r['errors'] if r['errors'] else ''}")
    total = sum(sizes.values())
    C.log(f"client/art sizes: " + ", ".join(f"{k} {v / 1048576:.2f} MB" for k, v in sizes.items()) + f", total {total / 1048576:.2f} MB")
    if extra:
        C.log(f"unexpected model files (not in the manifest): {extra}")
    if failures:
        C.log(f"verify: {len(failures)} failure(s)")
        raise RuntimeError(f"verify: {len(failures)} failure(s): {failures}")
    C.log("verify: all checks passed")


if __name__ == "__main__":
    main()
