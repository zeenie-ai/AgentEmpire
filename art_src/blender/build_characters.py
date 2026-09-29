"""Builds the rigged characters into client/art/characters/<id>.glb.

    blender --background --factory-startup --python art_src/blender/build_characters.py -- [id ...]

For each manifest character: drop the weapons and accessories it should not carry, re-dye the
clothing swatches of a COPY of the kit atlas (skin, hair and eyes untouched), keep only the clips
in 'character_animations', scale to the target height and export Skeleton + mesh + animations.

Output layout (Blender names, which the glTF keeps):
  Rig            the armature (Skeleton3D in Godot), 23 bones incl. handslot.r / handslot.l
  Rig/Mesh       the body, one skinned mesh with one material
  Rig/Prop_*     signature props kept for agents, rigidly skinned to their hand bone
The IK/control bones of the kit rig drive nothing once the clips are baked, so they are removed.
A bone report is written to out/art/characters_report.json.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ beside the scripts
sys.path.insert(0, str(Path(__file__).resolve().parent))

import bpy  # noqa: E402
import numpy as np  # noqa: E402
from mathutils import Matrix  # noqa: E402

import common as C  # noqa: E402

ANIMS = list(C.MANIFEST["character_animations"])
# Manifest heights are measured to the top of a bare head in the kit rig (2.2 kit units), so
# every character of the same target height gets the same body scale; hoods, the mage hat and
# the knight helmet rise above it.
REF_HEAD_TOP = 2.2
CONTROL_BONE_PREFIXES = ("kneeIK", "control-", "heelIK", "IK-", "elbowIK", "handIK")
FPS = 30  # the kit clips are authored at 30 fps (every clip length is a whole number of frames)

# Concrete reading of the manifest's 'hide' and 'recolor' notes. Swatch cells are (column, row)
# in the 8x4 character atlas; colours are the new mid tone of the swatch.
ROGUE_WEAPONS = ["Knife_Offhand", "1H_Crossbow", "2H_Crossbow", "Knife", "Throwable"]
BARBARIAN_KIT = ["1H_Axe", "1H_Axe_Offhand", "2H_Axe", "Barbarian_Round_Shield", "Mug"]
PLAN = {
    # Rogue_Hooded: (0,1) tunic and sleeves, (1,1) hood, cape, collar and cuffs.
    "townsfolk_a": dict(remove=ROGUE_WEAPONS, props={}, recolor={(0, 1): "#6e5638", (1, 1): "#c9ab7c"}),
    "townsfolk_c": dict(remove=ROGUE_WEAPONS, props={}, recolor={(0, 1): "#526e8e", (1, 1): "#8e8f8b"}),
    # Barbarian: the bear hat and fur cape go (the worker look); (0,1) tunic, (1,1) sleeves,
    # (2,1) fur trims, (7,1) trousers.
    "townsfolk_b": dict(remove=BARBARIAN_KIT + ["Barbarian_Hat", "Barbarian_Cape"], props={},
                        recolor={(0, 1): "#707245", (1, 1): "#d8cba8", (2, 1): "#e9dfc6", (7, 1): "#8a7a62"}),
    "townsfolk_d": dict(remove=BARBARIAN_KIT + ["Barbarian_Hat", "Barbarian_Cape"], props={},
                        recolor={(0, 1): "#9c4b2e", (1, 1): "#8e4129"}),
    # Agents keep one readable signature loadout; overlapping alternatives in the same hand go.
    "agent_artificer": dict(remove=["2H_Axe", "1H_Axe_Offhand", "Barbarian_Round_Shield", "Mug"],
                            props={"1H_Axe": "Prop_Axe"}, recolor={}),
    "agent_scholar": dict(remove=["1H_Wand", "Spellbook_open"],
                          props={"2H_Staff": "Prop_Staff", "Spellbook": "Prop_Book"}, recolor={}),
    # Mage: (0,1) robe, (1,1) hat, (2,1) cape, (7,1) under-robe, (5,0) orange trims, (1,2) book cover.
    "agent_scribe": dict(remove=["1H_Wand", "2H_Staff", "Spellbook"], props={"Spellbook_open": "Prop_Book"},
                         recolor={(0, 1): "#d9c79c", (1, 1): "#2f3a55", (2, 1): "#2b3654",
                                  (7, 1): "#2a3044", (5, 0): "#7a5230", (1, 2): "#7b3a2c"}),
    "agent_warden": dict(remove=["1H_Sword_Offhand", "2H_Sword", "Rectangle_Shield", "Round_Shield", "Spike_Shield"],
                         props={"1H_Sword": "Prop_Sword", "Badge_Shield": "Prop_Shield"}, recolor={}),
    "agent_herald": dict(remove=ROGUE_WEAPONS, props={}, recolor={}),
}


def iter_fcurves(action):
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                yield bag, list(bag.fcurves)


def bone_of(data_path: str) -> str | None:
    if data_path.startswith('pose.bones["'):
        return data_path.split('"')[1]
    return None


def make_skinned(ob, rig, bone: str | None) -> None:
    """Bake a mesh's rest-pose world transform into its data and bind it to `rig` (object parent,
    Armature modifier). A bone-parented part becomes a vertex group of weight 1 on that bone."""
    if ob.data.users > 1:
        ob.data = ob.data.copy()
    mw = ob.matrix_world.copy()
    ob.data.transform(mw)
    ob.parent = None
    ob.matrix_parent_inverse = Matrix()
    ob.matrix_basis = Matrix()
    ob.parent = rig
    ob.parent_type = 'OBJECT'
    ob.matrix_parent_inverse = rig.matrix_world.inverted()
    if bone is not None:
        for vg in list(ob.vertex_groups):
            ob.vertex_groups.remove(vg)
        vg = ob.vertex_groups.new(name=bone)
        vg.add(list(range(len(ob.data.vertices))), 1.0, 'REPLACE')
    if not any(m.type == 'ARMATURE' for m in ob.modifiers):
        mod = ob.modifiers.new("Armature", 'ARMATURE')
        mod.object = rig


def group_weight_totals(meshes) -> dict[str, float]:
    totals: dict[str, float] = {}
    for ob in meshes:
        names = {vg.index: vg.name for vg in ob.vertex_groups}
        for v in ob.data.vertices:
            for g in v.groups:
                totals[names[g.group]] = totals.get(names[g.group], 0.0) + g.weight
    return totals


def build(entry: dict) -> dict:
    cid = entry["id"]
    plan = PLAN[cid]
    C.reset_scene()
    sc = bpy.context.scene
    sc.render.fps, sc.render.fps_base = FPS, 1.0
    objs = C.import_gltf(C.src_path(entry["source"]))
    rig = next(o for o in objs if o.type == 'ARMATURE')

    # 1. drop the kit's preview sphere and every part this character should not carry
    for o in list(objs):
        if o.type == 'MESH' and (o.name == "Icosphere" or o.name in plan["remove"]):
            bpy.data.objects.remove(o, do_unlink=True)
    meshes = [o for o in bpy.data.objects if o.type == 'MESH']
    loose = [o.name for o in meshes if o.parent_type == 'BONE' and o.parent_bone.startswith("handslot")
             and o.name not in plan["props"]]
    if loose:
        raise RuntimeError(f"{cid}: hand-held parts not planned: {loose}")

    # 2. re-dye the clothing swatches on a copy of the atlas
    src_mat = meshes[0].active_material
    src_img = next(n.image for n in src_mat.node_tree.nodes if n.type == 'TEX_IMAGE' and n.image)
    if plan["recolor"]:
        img = C.recolor_swatches(src_img, plan["recolor"], name=f"{cid}_texture")
        mat = C.make_texture_material(cid, img)
    else:
        mat = src_mat

    # 3. bind every part to the rig as a skinned mesh (in the rest pose)
    rig.data.pose_position = 'REST'
    bpy.context.view_layer.update()
    for ob in meshes:
        make_skinned(ob, rig, ob.parent_bone if ob.parent_type == 'BONE' else None)
        C.set_single_material(ob, mat)

    # 4. body parts -> one 'Mesh'; kept props stay separate so the client can hide them
    props = [o for o in meshes if o.name in plan["props"]]
    body = [o for o in meshes if o not in props]
    C.select_only(body)
    bpy.ops.object.join()
    mesh = bpy.context.view_layer.objects.active
    mesh.name = mesh.data.name = "Mesh"
    for ob in props:
        ob.name = ob.data.name = plan["props"][ob.name]
    parts = [mesh] + props

    # 5. remove the IK/control bones, which carry no weight and drive nothing after baking
    totals = group_weight_totals(parts)
    control = [b.name for b in rig.data.bones if b.name.startswith(CONTROL_BONE_PREFIXES)]
    weighted = [b for b in control if totals.get(b, 0.0) > 1e-6]
    if weighted:
        raise RuntimeError(f"{cid}: control bones carry weights: {weighted}")
    C.select_only([rig])
    bpy.ops.object.mode_set(mode='EDIT')
    for name in control:
        rig.data.edit_bones.remove(rig.data.edit_bones[name])
    bpy.ops.object.mode_set(mode='OBJECT')
    for ob in parts:
        for vg in list(ob.vertex_groups):
            if vg.name in control:
                ob.vertex_groups.remove(vg)

    # 6. keep only the manifest clips, with channels for surviving bones only
    missing = [a for a in ANIMS if a not in bpy.data.actions]
    if missing:
        raise RuntimeError(f"{cid}: source lacks clips {missing}")
    ad = rig.animation_data
    for track in list(ad.nla_tracks):
        ad.nla_tracks.remove(track)
    for act in list(bpy.data.actions):
        if act.name not in ANIMS:
            bpy.data.actions.remove(act)
    bones = {b.name for b in rig.data.bones}
    for act in bpy.data.actions:
        for bag, fcurves in iter_fcurves(act):
            for fc in fcurves:
                b = bone_of(fc.data_path)
                if b is not None and b not in bones:
                    bag.fcurves.remove(fc)
        act.use_fake_user = True

    # 7. bake the uniform scale into bones, meshes and the location keys
    s = entry["height"] / REF_HEAD_TOP
    C.select_only([rig])
    bpy.ops.object.mode_set(mode='EDIT')
    for eb in rig.data.edit_bones:
        eb.head = eb.head * s
        eb.tail = eb.tail * s
    bpy.ops.object.mode_set(mode='OBJECT')
    for ob in parts:
        ob.data.transform(Matrix.Scale(s, 4))
        ob.data.update()
    for act in bpy.data.actions:
        for _bag, fcurves in iter_fcurves(act):
            for fc in fcurves:
                if fc.data_path.endswith(".location"):
                    for kp in fc.keyframe_points:
                        kp.co.y *= s
                        kp.handle_left.y *= s
                        kp.handle_right.y *= s
                    fc.update()
    rig.data.pose_position = 'POSE'
    idle = bpy.data.actions["Idle"]
    ad.action = idle
    if idle.slots:
        ad.action_slot = idle.slots[0]
    sc.frame_set(0)

    # 8. export Skeleton + meshes + clips
    dest = C.OUT_CHARACTERS / f"{cid}.glb"
    C.export_glb([rig] + parts, dest, animations=True,
                 export_animation_mode='ACTIONS', export_anim_single_armature=True,
                 export_force_sampling=True, export_frame_range=False, export_reset_pose_bones=True,
                 export_def_bones=False, export_rest_position_armature=True,
                 export_optimize_animation_size=True, export_anim_slide_to_zero=False,
                 export_all_influences=False, export_leaf_bone=False, export_armature_object_remove=False)
    pts = np.concatenate([C.world_coords(o, evaluated=True) for o in parts])
    info = {
        "file": str(dest.relative_to(C.REPO)).replace("\\", "/"),
        "source": entry["source"],
        "height_idle": round(float(pts[:, 2].max()), 3),
        "scale": round(s, 4),
        "bones": [b.name for b in rig.data.bones],
        "hand_bones": [b.name for b in rig.data.bones if b.name.startswith(("hand", "handslot"))],
        "meshes": [o.name for o in parts],
        "tris": sum(C.tri_count(o) for o in parts),
        "clips": sorted(a.name for a in bpy.data.actions),
        "removed": sorted(plan["remove"]),
        "recolor": {f"{c[0]},{c[1]}": v for c, v in plan["recolor"].items()},
        "kb": dest.stat().st_size // 1024,
    }
    C.log(f"{cid:16s} h={info['height_idle']:.3f} tris={info['tris']} bones={len(info['bones'])} "
          f"clips={len(info['clips'])} meshes={info['meshes']} -> {dest.name} ({info['kb']} KB)")
    return info


def main() -> None:
    wanted = set(C.script_args())
    report_path = C.OUT_SHEETS / "characters_report.json"
    report = json.loads(report_path.read_text(encoding="utf-8")) if report_path.exists() else {}
    for entry in C.MANIFEST["characters"]:
        if wanted and entry["id"] not in wanted:
            continue
        report[entry["id"]] = build(entry)
    C.write_json_atomic(report, report_path)
    hands = sorted({h for r in report.values() for h in r["hand_bones"]})
    C.log(f"hand bones: {hands}")


if __name__ == "__main__":
    main()
