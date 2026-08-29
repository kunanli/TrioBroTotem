#!/usr/bin/env python3
"""把 Meshy 匯出的模型正規化成 TrioBroTotem 的管線資產。

做四件事，全部是 Blender GUI 裡點起來很煩、又必須每隻動物重做一次的雜事：

  1. 骨骼改名成 SkeletonProfileHumanoid（TD-07），連帶更新頂點群組與動作曲線
  2. 套用 scale 與 rotation（Meshy 常帶著 0.01 倍的根節點 scale，
     不套用的話 ragdoll 的碰撞體尺寸會全錯）
  3. 面數超標時 decimate 到規格內
  4. 匯出乾淨的 GLB

用法（兩種都可以）：

    blender --background --python tools/blender_normalize.py -- \\
        --input assets/source/pig.glb --output assets/source/pig_normalised.glb

    python3 tools/blender_normalize.py --input pig.glb --output pig_normalised.glb

改名對照表預設由 tools/inspect_model.py 的同一套規則自動推導。
有猜不出來的骨骼時，先跑 inspect_model.py --map 產出 JSON，手動補完再用 --map 餵進來。

版本相容：在 Blender 5.0（bpy 模組）上實測跑通。兩處會因版本而異的地方已經處理——
匯出參數依當前版本過濾，動作曲線同時支援 4.4 之前的 action.fcurves
與 4.4 之後的 slotted actions。
"""

import argparse
import json
import sys
from pathlib import Path

import bpy

sys.path.insert(0, str(Path(__file__).resolve().parent))
from inspect_model import guess_standard_name  # noqa: E402

TRI_MAX = 15_000


def parse_args(argv):
    if "--" in argv:
        argv = argv[argv.index("--") + 1:]
    else:
        argv = [a for a in argv[1:] if not a.endswith(".py")]
    parser = argparse.ArgumentParser(description="正規化 Meshy 匯出的角色模型")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--map", type=Path, help="骨骼改名對照表 JSON；不給就自動推導")
    parser.add_argument("--tri-max", type=int, default=TRI_MAX, help=f"面數上限（預設 {TRI_MAX}）")
    parser.add_argument("--no-decimate", action="store_true", help="面數超標時只警告，不 decimate")
    return parser.parse_args(argv)


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def import_model(path):
    suffix = path.suffix.lower()
    if suffix in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=str(path))
    elif suffix == ".fbx":
        bpy.ops.import_scene.fbx(filepath=str(path))
    else:
        raise SystemExit(f"不支援的格式：{suffix}（請用 .glb / .gltf / .fbx）")


def find_armature():
    armatures = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    if not armatures:
        raise SystemExit("檔案裡沒有骨架。這是靜態模型，要先在 Meshy 跑 rigging。")
    if len(armatures) > 1:
        print(f"! 有 {len(armatures)} 個骨架，只處理第一個：{armatures[0].name}")
    return armatures[0]


def character_meshes(armature):
    """只認綁在這個骨架上的網格。

    匯入檔常夾帶不屬於角色的東西——道具、空物件、匯入器自己產生的殘留。
    把它們一起算面數會誤判、一起匯出會進遊戲，所以整條流程只認這一組。
    """
    found = []
    for obj in bpy.data.objects:
        if obj.type != "MESH":
            continue
        bound = obj.parent is armature or any(
            m.type == "ARMATURE" and m.object is armature for m in obj.modifiers
        )
        if bound:
            found.append(obj)
    return found


def drop_strays(keep):
    """刪掉不屬於角色的物件，避免它們被一起匯出。"""
    strays = [o for o in bpy.data.objects if o not in keep]
    names = [o.name for o in strays]
    for obj in strays:
        bpy.data.objects.remove(obj, do_unlink=True)
    if strays:
        print(f"移除 {len(strays)} 個與角色無關的物件：{', '.join(names)}")
    return strays


def build_mapping(armature, map_path):
    if map_path:
        mapping = json.loads(map_path.read_text(encoding="utf-8"))
        print(f"使用 {map_path}（{len(mapping)} 項）")
        return mapping
    mapping = {}
    for bone in armature.data.bones:
        guess = guess_standard_name(bone.name)
        if guess and guess != bone.name:
            mapping[bone.name] = guess
    print(f"自動推導出 {len(mapping)} 項改名")
    return mapping


def iter_fcurves(action):
    """走訪動作裡的所有曲線。

    Blender 4.4 引入 slotted actions，5.0 移除了 action.fcurves。
    兩種擺法都要能走，否則腳本會依 Blender 版本而定地爆掉——
    這正是骨骼改名最容易漏掉的地方：骨骼改好了，動作曲線還指著舊名字，
    動畫就整個不動了，而且不會有任何錯誤訊息。
    """
    legacy = getattr(action, "fcurves", None)
    if legacy is not None:
        yield from legacy
        return
    for layer in getattr(action, "layers", []):
        for strip in getattr(layer, "strips", []):
            for bag in getattr(strip, "channelbags", []):
                yield from bag.fcurves


def rename_bones(armature, meshes, mapping):
    """改名骨骼。Blender 會連帶更新頂點群組與動作曲線，但不保證每個版本都做，
    所以下面再明確補一次——已經改好的會被跳過。"""
    bones = armature.data.bones
    renamed, skipped = 0, []

    for old, new in mapping.items():
        if old not in bones:
            skipped.append(old)
            continue
        if new in bones and bones[new].name != bones[old].name:
            print(f"! '{new}' 已存在，跳過 '{old}' 的改名")
            skipped.append(old)
            continue
        bones[old].name = new
        renamed += 1

    for obj in meshes:
        for old, new in mapping.items():
            group = obj.vertex_groups.get(old)
            if group and not obj.vertex_groups.get(new):
                group.name = new

    for action in bpy.data.actions:
        for curve in iter_fcurves(action):
            for old, new in mapping.items():
                token = f'pose.bones["{old}"]'
                if token in curve.data_path:
                    curve.data_path = curve.data_path.replace(token, f'pose.bones["{new}"]')

    print(f"改名 {renamed} 根骨骼" + (f"（{len(skipped)} 根跳過：{', '.join(skipped)}）" if skipped else ""))
    return renamed


def apply_transforms(targets):
    """套用 scale 與 rotation，不動 location——位移套用會把角色的原點搬走。"""
    if not targets:
        return
    bpy.ops.object.select_all(action="DESELECT")
    for obj in targets:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = targets[0]
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    print(f"已套用 {len(targets)} 個物件的 rotation 與 scale")


def triangle_count(meshes):
    return sum(sum(len(p.vertices) - 2 for p in obj.data.polygons) for obj in meshes)


def decimate_to(meshes, limit):
    current = triangle_count(meshes)
    if current <= limit:
        return current
    ratio = limit / current
    print(f"面數 {current:,} 超過上限 {limit:,}，以 ratio {ratio:.3f} decimate")
    for obj in meshes:
        bpy.context.view_layer.objects.active = obj
        modifier = obj.modifiers.new(name="TrioDecimate", type="DECIMATE")
        modifier.ratio = ratio
        # 移到修改器堆疊最前面再套用。留在 Armature 之後套用會被 Blender
        # 警告順序不對，而且語意上我們要減的是 rest pose 網格，不是變形後的。
        if obj.modifiers.find(modifier.name) != 0:
            obj.modifiers.move(obj.modifiers.find(modifier.name), 0)
        bpy.ops.object.modifier_apply(modifier=modifier.name)
    return triangle_count(meshes)


def export_glb(path):
    """匯出參數依版本過濾，避免在不同 Blender 上因為多一個參數就整個失敗。"""
    wanted = {
        "filepath": str(path),
        "export_format": "GLB",
        "export_apply": True,
        "export_animations": True,
        "export_skins": True,
        "export_yup": True,
    }
    supported = bpy.ops.export_scene.gltf.get_rna_type().properties.keys()
    kwargs = {k: v for k, v in wanted.items() if k in supported}
    dropped = set(wanted) - set(kwargs)
    if dropped:
        print(f"! 這個 Blender 版本不認得的匯出參數，已略過：{', '.join(sorted(dropped))}")
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(**kwargs)


def main():
    args = parse_args(sys.argv)
    if not args.input.exists():
        raise SystemExit(f"找不到檔案：{args.input}")

    reset_scene()
    import_model(args.input)
    armature = find_armature()
    meshes = character_meshes(armature)
    if not meshes:
        raise SystemExit(f"骨架 '{armature.name}' 底下沒有綁定的網格。")
    drop_strays([armature] + meshes)

    print(f"\n骨架 '{armature.name}'：{len(armature.data.bones)} 根骨骼、"
          f"{len(meshes)} 個網格、{triangle_count(meshes):,} 三角面、"
          f"{len(bpy.data.actions)} 個動作")

    mapping = build_mapping(armature, args.map)
    rename_bones(armature, meshes, mapping)

    unmapped = [b.name for b in armature.data.bones if guess_standard_name(b.name) is None]
    if unmapped:
        print(f"未對應到 profile 的骨骼（角色專屬骨鏈，正常）：{', '.join(unmapped)}")

    apply_transforms([armature] + meshes)

    final_tris = triangle_count(meshes) if args.no_decimate else decimate_to(meshes, args.tri_max)
    if args.no_decimate and final_tris > args.tri_max:
        print(f"! 面數 {final_tris:,} 仍超過上限 {args.tri_max:,}（--no-decimate）")

    export_glb(args.output)
    print(f"\n已輸出 {args.output}（{final_tris:,} 三角面）")
    print(f"驗貨：python3 tools/inspect_model.py {args.output}")


if __name__ == "__main__":
    main()
