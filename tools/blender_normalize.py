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
from mathutils import Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
from inspect_model import (  # noqa: E402
    gltf_skeleton_height, guess_standard_name, is_leaf_bone,
)

TRI_MAX = 15_000

## 檔名關鍵字 → 遊戲裡用的動畫名稱。
## Meshy 的動畫名稱長這樣：Armature|Armature|Armature|walking_man|baselayer
## 直接拿去 Godot 端寫死會很脆弱，統一在管線這一層正規化掉。
ANIMATION_NAMES = [
    ("idle", ("idle", "stand", "breath")),
    ("walk", ("walk",)),
    ("run", ("run", "sprint", "jog")),
    ("jump", ("jump",)),
    ("fall", ("fall", "air")),
    ("attack", ("attack", "punch", "slash", "swing", "kick", "hit_")),
    ("hurt", ("hurt", "damage", "impact", "flinch", "gethit")),
    ("death", ("death", "die", "dead")),
    ("carry", ("carry", "lift", "hold")),
    ("victory", ("victory", "win", "cheer", "dance")),
]


def parse_args(argv):
    if "--" in argv:
        argv = argv[argv.index("--") + 1:]
    else:
        argv = [a for a in argv[1:] if not a.endswith(".py")]
    parser = argparse.ArgumentParser(description="正規化 Meshy 匯出的角色模型")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--animation", type=Path, action="append", default=[],
                        help="額外的動畫檔（可重複）。共用同一套 rig 時動作會併進來")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--map", type=Path, help="骨骼改名對照表 JSON；不給就自動推導")
    parser.add_argument("--tri-max", type=int, default=TRI_MAX, help=f"面數上限（預設 {TRI_MAX}）")
    parser.add_argument("--no-decimate", action="store_true", help="面數超標時只警告，不 decimate")
    parser.add_argument("--target-height", type=float, default=0.0,
                        help="把角色縮放到這個高度（公尺）。0 = 維持原尺寸。"
                             "Meshy 的匯出單位不固定，量到的尺寸不合理時用這個修")
    parser.add_argument("--texture-size", type=int, default=1024,
                        help="貼圖邊長上限（預設 1024，0 表示不縮）")
    parser.add_argument("--texture-format", default="AUTO", choices=["AUTO", "JPEG", "WEBP"],
                        help="內嵌貼圖的編碼。AUTO 維持 PNG；WEBP 通常再小一半以上，"
                             "但法線貼圖用有損格式會出現色塊")
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


def animation_name(source, fallback):
    """從檔名推出動畫名稱。認不出來就用 fallback。"""
    lowered = source.lower()
    for name, keywords in ANIMATION_NAMES:
        if any(k in lowered for k in keywords):
            return name
    return fallback


def collect_animations(armature, extra_files):
    """把其他檔案裡的動作併進這個骨架。

    Meshy 一個檔案只帶一支動畫，所以「走路 + 攻擊 + 待機」會是三個匯出檔。
    它們共用同一套 rig，骨骼名稱一致，動作可以直接轉掛到同一個骨架上。
    匯入帶進來的多餘物件用完就刪，只留動作本身。
    """
    merged = []
    for path in extra_files:
        before = set(bpy.data.actions)
        keep = set(bpy.data.objects)
        try:
            import_model(path)
        except Exception as error:
            print(f"! 匯入 {path.name} 失敗：{error}")
            continue
        added = [a for a in bpy.data.actions if a not in before]
        for action in added:
            action.name = animation_name(path.stem, action.name)
            action.use_fake_user = True  # 沒有物件用它時才不會在存檔時被丟掉
            merged.append(action.name)
        for obj in [o for o in bpy.data.objects if o not in keep]:
            bpy.data.objects.remove(obj, do_unlink=True)
    return merged


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


def spine_chain(armature):
    """Hips 到 Neck 之間的骨骼，由下往上排序。

    脊椎不能靠名稱判斷。Meshy 的 Spine / Spine01 / Spine02 會有兩個以上
    對到同一個標準名，而且不同來源的編號方向還不一樣（有的由下往上、
    有的相反）。位置是唯一可靠的依據：Hips 之上第一節就是 Spine，
    第二節是 Chest，第三節是 UpperChest。
    """
    bones = armature.data.bones
    hips = next((b for b in bones if guess_standard_name(b.name) == "Hips"), None)
    neck = next((b for b in bones if guess_standard_name(b.name) == "Neck"), None)
    if hips is None or neck is None:
        return []
    chain = []
    cursor = neck.parent
    while cursor is not None and cursor != hips:
        chain.append(cursor)
        cursor = cursor.parent
    if cursor != hips:
        return []  # Neck 不在 Hips 的子樹裡，結構不是預期的樣子
    chain.reverse()
    return chain


def apply_renames(armature, meshes, pairs):
    """分兩階段改名，先全部改成暫時名稱再改成目標名稱。

    直接改名時，只要目標名稱已經被別的骨骼佔著就會失敗或被跳過，
    留下半改名的骨架——那正是脊椎順序錯掉的原因，而且不會有任何錯誤訊息。
    """
    bones = armature.data.bones
    staged = []
    for index, (old, new) in enumerate(pairs):
        if old == new or old not in bones:
            continue
        temporary = f"__trio_tmp_{index}"
        bones[old].name = temporary
        staged.append((old, temporary, new))

    for _, temporary, new in staged:
        bones[temporary].name = new

    for old, _, new in staged:
        for obj in meshes:
            group = obj.vertex_groups.get(old)
            if group and not obj.vertex_groups.get(new):
                group.name = new

    for action in bpy.data.actions:
        for curve in iter_fcurves(action):
            for old, _, new in staged:
                token = f'pose.bones["{old}"]'
                if token in curve.data_path:
                    curve.data_path = curve.data_path.replace(token, f'pose.bones["{new}"]')
    return len(staged)


def rename_bones(armature, meshes, mapping):
    """改名骨骼。Blender 會連帶更新頂點群組與動作曲線，但不保證每個版本都做，
    所以下面再明確補一次——已經改好的會被跳過。"""
    # 脊椎依階層位置指定，覆蓋名稱猜測的結果。
    spine_names = ["Spine", "Chest", "UpperChest"]
    chain = spine_chain(armature)
    if chain:
        print(f"脊椎鏈（由下往上）：{' → '.join(b.name for b in chain)}")
        if len(chain) > len(spine_names):
            print(f"! 脊椎有 {len(chain)} 節，profile 只定義 {len(spine_names)} 節，多的維持原名")
        for bone, name in zip(chain, spine_names):
            mapping[bone.name] = name
        for bone in chain[len(spine_names):]:
            mapping.pop(bone.name, None)
    else:
        print("! 找不到 Hips→Neck 的脊椎鏈，脊椎維持名稱猜測的結果")

    renamed = apply_renames(armature, meshes, list(mapping.items()))
    print(f"改名 {renamed} 根骨骼")
    return renamed


def fmt(value):
    """小數點後三位會把 0.0002 印成 0.000，看起來像量不到——
    尺寸出問題時那正是最需要看清楚的數字，所以一律用有效位數。"""
    return f"{value:.4g}"


def measure(meshes):
    """角色的世界空間尺寸 (寬, 深, 高)。

    只有在 rotation 套用之後呼叫才正確——Blender 的世界是 Z-up，
    但 FBX 進來時物件常帶著一層旋轉，沒套用之前 Z 不一定是「上」。
    """
    corners = [obj.matrix_world @ Vector(c) for obj in meshes for c in obj.bound_box]
    if not corners:
        return (0.0, 0.0, 0.0)
    return tuple(
        max(c[i] for c in corners) - min(c[i] for c in corners)
        for i in range(3)
    )


def scale_rig(armature, meshes, factor):
    """把整組角色縮放 factor 倍——直接改資料，不動物件的 transform。

    為什麼不能用 bpy.ops.object.transform_apply(scale=True)：它只把縮放
    烤進網格頂點，骨架的骨骼資料原封不動。而 glTF 匯出器的骨架是讀骨骼
    資料、不是讀物件 scale，結果就是網格 1.6 公尺、骨架還停在 0.015——
    Blender 場景裡看起來完全正常，匯出後才發現角色只有一公分半。

    要同時改三個地方，缺一不可：骨骼的 head/tail、網格頂點、
    動作裡的位移曲線（骨骼位移沒跟著縮放，動畫會把角色扯散）。
    """
    if abs(factor - 1.0) < 1e-9:
        return

    bpy.context.view_layer.objects.active = armature
    bpy.ops.object.mode_set(mode="EDIT")
    for bone in armature.data.edit_bones:
        bone.head = bone.head * factor
        bone.tail = bone.tail * factor
    bpy.ops.object.mode_set(mode="OBJECT")

    for obj in meshes:
        for vertex in obj.data.vertices:
            vertex.co = vertex.co * factor
        obj.data.update()

    for action in bpy.data.actions:
        for curve in iter_fcurves(action):
            if not curve.data_path.endswith(".location"):
                continue
            for point in curve.keyframe_points:
                point.co.y *= factor
                point.handle_left.y *= factor
                point.handle_right.y *= factor


def normalise_transforms(armature, meshes, target_height):
    """套用 rotation 與 scale，並在指定 target_height 時把角色縮放到該高度。

    Meshy 匯出的單位不固定（公尺、公分、任意值都遇過），而 FBX 的單位轉換
    在匯入／套用／匯出三個環節各有一次機會出錯。與其猜來源用什麼單位，
    不如量出實際尺寸再縮到要的高度——這是唯一不依賴任何慣例的做法。

    不動 location：位移套用會把角色的原點搬走。
    """
    targets = [armature] + meshes

    def select_all():
        bpy.ops.object.select_all(action="DESELECT")
        for obj in targets:
            obj.select_set(True)
        bpy.context.view_layer.objects.active = armature

    # 先只套用 rotation。量測必須在這之後，Z 才確定是「上」。
    select_all()
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)

    width, depth, height = measure(meshes)
    print(f"角色尺寸：寬 {fmt(width)} × 深 {fmt(depth)} × 高 {fmt(height)} 公尺")

    if target_height > 0.0 and height > 0.0:
        factor = target_height / height
        scale_rig(armature, meshes, factor)
        print(f"高度正規化：{fmt(height)} → {fmt(target_height)}（係數 {fmt(factor)}）")
    elif target_height > 0.0:
        print("! 量不到高度，跳過高度正規化")

    # 物件層級殘留的 scale 還是要清掉，但真正的縮放已經由 scale_rig 做完。
    select_all()
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)

    width, depth, height = measure(meshes)
    print(f"最終尺寸：寬 {fmt(width)} × 深 {fmt(depth)} × 高 {fmt(height)} 公尺")
    if height < 0.1 or height > 100.0:
        print(f"! 高度 {fmt(height)} 公尺明顯不合理。Meshy 的匯出單位不固定，"
              f"用 --target-height 指定身高即可。")
    return height


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


def resize_textures(limit):
    """把過大的貼圖縮到上限之內。

    Meshy 預設輸出 4K，單張就 20 MB 以上。本作是低多邊形卡通風、色塊乾淨
    （docs/09），1024 綽綽有餘；而且分屏要渲染兩次，記憶體頻寬是實際成本。
    不縮的話，內嵌貼圖會讓一隻角色的 GLB 就有 40 MB。
    """
    resized = []
    for image in bpy.data.images:
        width, height = image.size
        if max(width, height) <= limit or width == 0:
            continue
        factor = limit / max(width, height)
        image.scale(max(1, int(width * factor)), max(1, int(height * factor)))
        resized.append(f"{image.name} {width}x{height} → {image.size[0]}x{image.size[1]}")
    for line in resized:
        print(f"貼圖縮圖：{line}")
    return len(resized)


def export_glb(path, image_format="AUTO"):
    """匯出參數依版本過濾，避免在不同 Blender 上因為多一個參數就整個失敗。"""
    wanted = {
        "filepath": str(path),
        "export_format": "GLB",
        "export_image_format": image_format,
        "export_apply": True,
        "export_animations": True,
        "export_animation_mode": "ACTIONS",
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


def export_verified(armature, meshes, path, image_format, target_height):
    """匯出後回頭讀檔量高度，不對就修正係數重匯。

    為什麼要這樣：Blender 場景裡量到 1.7 公尺的模型，匯出後實際是 0.017——
    transform_apply 與 glTF 匯出器之間的交互作用會讓尺寸差 100 倍，
    而場景端完全看不出來。唯一可靠的驗收對象是產出的檔案本身。

    縮放是線性的，所以一次修正就會收斂；仍留第二次當保險。
    """
    for attempt in range(3):
        export_glb(path, image_format)
        height = gltf_skeleton_height(path)
        if height <= 0.0:
            print("! 產出的檔案量不到骨架高度，跳過驗收")
            return
        print(f"產出檔骨架高度：{fmt(height)} 公尺")

        if target_height <= 0.0:
            if height < 0.1 or height > 100.0:
                print(f"! {fmt(height)} 公尺明顯不合理。用 --target-height 指定身高即可。")
            return

        error = abs(height - target_height) / target_height
        if error < 0.02:
            return
        if attempt == 2:
            print(f"! 修正兩次後仍是 {fmt(height)} 公尺，與目標 {fmt(target_height)} 不符")
            return
        correction = target_height / height
        scale_rig(armature, meshes, correction)
        print(f"修正縮放 ×{fmt(correction)} 後重新匯出")


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

    base_action = next(iter(bpy.data.actions), None)
    if base_action is not None:
        base_action.name = animation_name(args.input.stem, base_action.name)
        base_action.use_fake_user = True
        print(f"動畫：{base_action.name}（來自 {args.input.name}）")
    if args.animation:
        merged = collect_animations(armature, args.animation)
        print(f"併入動畫：{'、'.join(merged) if merged else '無'}")

    mapping = build_mapping(armature, args.map)
    rename_bones(armature, meshes, mapping)

    extras = [b.name for b in armature.data.bones if guess_standard_name(b.name) is None]
    leaves = [b for b in extras if is_leaf_bone(b)]
    unmapped = [b for b in extras if not is_leaf_bone(b)]
    if unmapped:
        print(f"未對應到 profile 的骨骼（角色專屬骨鏈，正常）：{', '.join(unmapped)}")
    if leaves:
        print(f"葉端骨骼 {len(leaves)} 根（FBX 匯出常見，無害）")

    normalise_transforms(armature, meshes, args.target_height)

    final_tris = triangle_count(meshes) if args.no_decimate else decimate_to(meshes, args.tri_max)
    if args.no_decimate and final_tris > args.tri_max:
        print(f"! 面數 {final_tris:,} 仍超過上限 {args.tri_max:,}（--no-decimate）")

    if args.texture_size > 0:
        resize_textures(args.texture_size)

    export_verified(armature, meshes, args.output, args.texture_format, args.target_height)
    print(f"\n已輸出 {args.output}（{final_tris:,} 三角面）")
    print(f"驗貨：python3 tools/inspect_model.py {args.output}")


if __name__ == "__main__":
    main()
