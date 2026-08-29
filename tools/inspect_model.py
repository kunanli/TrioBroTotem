#!/usr/bin/env python3
"""檢查 Meshy（或任何來源）匯出的 glTF/GLB，看它能不能進 TrioBroTotem 的管線。

只用標準函式庫，不需要 Blender、不需要 Godot、不需要 pip install。

    python3 tools/inspect_model.py assets/source
    python3 tools/inspect_model.py assets/source/Pig_Warrior/pig.glb
    python3 tools/inspect_model.py assets/source/Pig_Warrior/pig.glb --map bone_map.json

給資料夾就遞迴檢查底下所有 .glb / .gltf。

檢查依據：
  docs/12-art-pipeline.md   資產規格（T-pose、5,000-15,000 三角面）
  docs/13-tech-decisions.md TD-07（骨骼命名採 SkeletonProfileHumanoid）
"""

import argparse
import json
import re
import struct
import sys
from pathlib import Path

# --- 規格 -------------------------------------------------------------------

TRI_MIN, TRI_MAX = 5_000, 15_000

# Godot SkeletonProfileHumanoid 的核心骨骼。手指與眼睛是選配，
# 缺了不擋 retarget，所以不列進必要清單。
REQUIRED_BONES = [
    "Hips", "Spine", "Chest", "Neck", "Head",
    "LeftUpperArm", "LeftLowerArm", "LeftHand",
    "RightUpperArm", "RightLowerArm", "RightHand",
    "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
    "RightUpperLeg", "RightLowerLeg", "RightFoot",
]
OPTIONAL_BONES = [
    "Root", "UpperChest", "LeftShoulder", "RightShoulder",
    "LeftToes", "RightToes", "LeftEye", "RightEye", "Jaw",
]

# 來源命名 -> 標準名。key 已經過 _normalise()，所以不必列大小寫與分隔符變體。
ALIASES = {
    "hips": "Hips", "hip": "Hips", "pelvis": "Hips", "bip01pelvis": "Hips",
    "spine": "Spine", "spine01": "Spine",
    "chest": "Chest", "spine02": "Chest", "spine1": "Chest",
    "upperchest": "UpperChest", "spine03": "UpperChest", "spine2": "UpperChest",
    "neck": "Neck", "neck01": "Neck",
    "head": "Head",
    "jaw": "Jaw",
    "root": "Root", "armature": "Root", "reference": "Root",
}
# 有左右之分的骨骼：正規化後會被拆成 (側邊, 部位)
SIDED_ALIASES = {
    "shoulder": "Shoulder", "clavicle": "Shoulder",
    "arm": "UpperArm", "upperarm": "UpperArm", "armupper": "UpperArm",
    "forearm": "LowerArm", "lowerarm": "LowerArm", "armlower": "LowerArm",
    "hand": "Hand",
    "upleg": "UpperLeg", "upperleg": "UpperLeg", "thigh": "UpperLeg",
    "lowerleg": "LowerLeg", "calf": "LowerLeg", "shin": "LowerLeg", "leg": "LowerLeg",
    "foot": "Foot", "ankle": "Foot",
    "toebase": "Toes", "toe": "Toes", "toes": "Toes", "ball": "Toes",
    "eye": "Eye",
}
FINGERS = {"thumb": "Thumb", "index": "Index", "middle": "Middle", "ring": "Ring", "pinky": "Little", "little": "Little"}


## FBX 匯出器會替每條骨鏈補上葉端骨骼（LeftHand_end 之類）。
## 它們不參與蒙皮也不參與 retarget，混在「角色專屬骨鏈」裡只會製造雜訊。
LEAF_SUFFIXES = ("_end", "_tip", ".end", "_leaf")


def is_leaf_bone(name):
    return name.lower().endswith(LEAF_SUFFIXES)


def _normalise(name):
    """mixamorig:LeftForeArm -> ('left', 'forearm')；thigh_R -> ('right', 'thigh')"""
    n = name.split(":")[-1]
    n = re.sub(r"^(mixamorig|bip01|bone|def|org|ctrl)[-_.]?", "", n, flags=re.I)
    side = None
    # 尾綴形式：_L / .R / _left
    m = re.search(r"[-_. ](l|r|left|right)$", n, flags=re.I)
    if m:
        side = "left" if m.group(1).lower()[0] == "l" else "right"
        n = n[: m.start()]
    else:
        # 前綴形式：LeftArm / R_Hand
        m = re.match(r"^(left|right|l|r)[-_. ]?(?=[A-Z0-9])", n, flags=re.I)
        if m:
            side = "left" if m.group(1).lower()[0] == "l" else "right"
            n = n[m.end():]
    return side, re.sub(r"[^a-z0-9]", "", n.lower())


def guess_standard_name(name):
    """回傳建議的標準骨骼名，猜不出來回傳 None。已經是標準名的直接回傳原名。"""
    if name in REQUIRED_BONES or name in OPTIONAL_BONES:
        return name
    side, core = _normalise(name)
    if core in ALIASES and side is None:
        return ALIASES[core]
    if side:
        prefix = "Left" if side == "left" else "Right"
        if core in SIDED_ALIASES:
            return prefix + SIDED_ALIASES[core]
        finger_core = core[4:] if core.startswith("hand") else core
        for key, part in FINGERS.items():
            if finger_core.startswith(key):
                tail = finger_core[len(key):]
                segment = {"1": "Proximal", "2": "Intermediate", "3": "Distal", "4": "Distal", "": "Proximal"}.get(tail)
                if segment:
                    if part == "Thumb":
                        segment = {"Proximal": "Metacarpal", "Intermediate": "Proximal", "Distal": "Distal"}[segment]
                    return f"{prefix}{part}{segment}"
    return None


# --- glTF / GLB 讀取 ---------------------------------------------------------

def load_gltf(path):
    data = path.read_bytes()
    if data[:4] == b"glTF":
        version, _length = struct.unpack_from("<II", data, 4)
        if version != 2:
            raise ValueError(f"只支援 glTF 2.0，這個檔是版本 {version}")
        offset, gltf = 12, None
        while offset + 8 <= len(data):
            chunk_len, chunk_type = struct.unpack_from("<I4s", data, offset)
            body = data[offset + 8: offset + 8 + chunk_len]
            if chunk_type == b"JSON":
                gltf = json.loads(body.decode("utf-8"))
            offset += 8 + chunk_len + (-chunk_len % 4)
        if gltf is None:
            raise ValueError("GLB 裡找不到 JSON chunk")
        return gltf
    return json.loads(data.decode("utf-8"))


def triangle_count(gltf):
    total = 0
    accessors = gltf.get("accessors", [])
    for mesh in gltf.get("meshes", []):
        for prim in mesh.get("primitives", []):
            if prim.get("mode", 4) != 4:
                continue
            if "indices" in prim:
                total += accessors[prim["indices"]]["count"] // 3
            elif "POSITION" in prim.get("attributes", {}):
                total += accessors[prim["attributes"]["POSITION"]]["count"] // 3
    return total


def _compose(node):
    """節點的區域 4x4 矩陣（列主序的巢狀 list）。"""
    if "matrix" in node:
        m = node["matrix"]  # glTF 是行主序
        return [[m[0], m[4], m[8], m[12]],
                [m[1], m[5], m[9], m[13]],
                [m[2], m[6], m[10], m[14]],
                [m[3], m[7], m[11], m[15]]]
    tx, ty, tz = node.get("translation", (0.0, 0.0, 0.0))
    x, y, z, w = node.get("rotation", (0.0, 0.0, 0.0, 1.0))
    sx, sy, sz = node.get("scale", (1.0, 1.0, 1.0))
    rot = [
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ]
    scale = (sx, sy, sz)
    return [[rot[r][c] * scale[c] for c in range(3)] + [(tx, ty, tz)[r]] for r in range(3)] + \
           [[0.0, 0.0, 0.0, 1.0]]


def _multiply(a, b):
    return [[sum(a[r][k] * b[k][c] for k in range(4)) for c in range(4)] for r in range(4)]


def skeleton_extent(gltf, joints, parents):
    """骨架在世界空間的尺寸。

    只看根節點的 scale 會誤判：Blender 的 glTF 匯出器慣例是把骨骼寫成
    公分等級的位移，再用根節點 scale 0.01 換算回公尺——那是正常的，
    不是待修的問題。真正要驗的是兩者相乘之後的實際尺寸。
    """
    nodes = gltf.get("nodes", [])
    cache = {}

    def world(index):
        if index in cache:
            return cache[index]
        local = _compose(nodes[index])
        parent = parents.get(index)
        matrix = local if parent is None else _multiply(world(parent), local)
        cache[index] = matrix
        return matrix

    points = [(world(j)[0][3], world(j)[1][3], world(j)[2][3]) for j in joints]
    if not points:
        return 0.0, (0.0, 0.0, 0.0)
    size = tuple(max(p[i] for p in points) - min(p[i] for p in points) for i in range(3))
    return max(size), size


def gltf_skeleton_height(path):
    """直接從 GLB 檔算骨架高度（公尺，Y-up）。

    給正規化流程驗收用：Blender 場景裡量到的尺寸不等於匯出結果，
    唯一可靠的是回頭讀產出的檔案。
    """
    gltf = load_gltf(Path(path))
    skins = gltf.get("skins", [])
    if not skins:
        return 0.0
    joints = skins[0].get("joints", [])
    _, size = skeleton_extent(gltf, joints, build_parents(gltf))
    return size[1]


def build_parents(gltf):
    parents = {}
    for index, node in enumerate(gltf.get("nodes", [])):
        for child in node.get("children", []):
            parents[child] = index
    return parents


def animation_length(gltf, anim):
    longest = 0.0
    accessors = gltf.get("accessors", [])
    for sampler in anim.get("samplers", []):
        acc = accessors[sampler["input"]]
        if "max" in acc and acc["max"]:
            longest = max(longest, float(acc["max"][0]))
    return longest


# --- 報告 -------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="檢查 glTF/GLB 是否符合 TrioBroTotem 的資產規格")
    parser.add_argument("model", type=Path, help="模型檔或含有模型的資料夾")
    parser.add_argument("--map", type=Path, help="把猜到的骨骼改名對照表寫成 JSON")
    args = parser.parse_args()

    if not args.model.exists():
        sys.exit(f"找不到：{args.model}")

    if args.model.is_dir():
        return inspect_folder(args.model)
    return inspect_one(args.model, args.map)


def inspect_folder(folder):
    models = sorted(folder.rglob("*.glb")) + sorted(folder.rglob("*.gltf"))
    fbx = sorted(folder.rglob("*.fbx"))
    if not models and not fbx:
        sys.exit(f"{folder} 底下找不到任何模型檔（.glb / .gltf / .fbx）")

    failed = 0
    for model in models:
        print("=" * 60)
        if inspect_one(model, None) != 0:
            failed += 1
    if fbx:
        print("=" * 60)
        print(f"\n另外有 {len(fbx)} 個 .fbx，這支工具讀不了（二進位私有格式）：")
        for path in fbx:
            print(f"  {path}")
        print("\n下次匯出請選 GLB。現有的 FBX 要驗貨得動用 Blender：")
        print(f"  blender --background --python tools/inspect_fbx.py -- {folder}")
    if models:
        print(f"\n共 {len(models)} 個 glTF 檔，{failed} 個沒過。")
    return 1 if (failed or (fbx and not models)) else 0


def inspect_one(model_path, map_path):
    args_map = map_path
    gltf = load_gltf(model_path)
    args = type("Args", (), {"model": model_path, "map": args_map})()
    nodes = gltf.get("nodes", [])
    parents = build_parents(gltf)
    problems, warnings = [], []

    print(f"# {args.model.name}（{args.model.stat().st_size / 1e6:.1f} MB）")
    generator = gltf.get("asset", {}).get("generator", "未標示")
    print(f"產生器：{generator}")

    tris = triangle_count(gltf)
    print(f"\n## 面數\n{tris:,} 三角面（規格 {TRI_MIN:,}–{TRI_MAX:,}）")
    if tris > TRI_MAX:
        problems.append(f"面數 {tris:,} 超過上限 {TRI_MAX:,}，需要 decimate。分屏要渲染兩次，這個上限不是建議值。")
    elif tris < TRI_MIN:
        warnings.append(f"面數 {tris:,} 低於下限 {TRI_MIN:,}，關節處可能沒有足夠的 edge loop，變形會壓扁。")

    skins = gltf.get("skins", [])
    print(f"\n## 骨架\n{len(skins)} 個 skin")
    if not skins:
        problems.append("這個檔案沒有 skin——它是靜態模型，還沒綁骨。要先在 Meshy 跑 rigging。")
        joints = []
    else:
        if len(skins) > 1:
            warnings.append(f"有 {len(skins)} 個 skin，共用骨架的前提是只有一個。")
        joints = skins[0].get("joints", [])
        print(f"{len(joints)} 根骨骼\n")
        joint_set = set(joints)

        def show(joint, depth):
            raw = nodes[joint].get("name", f"<node {joint}>")
            guess = guess_standard_name(raw)
            if guess is None:
                mark = "  ← 葉端" if is_leaf_bone(raw) else "  ← 不在 profile 內"
            elif guess == raw:
                mark = ""
            else:
                mark = f"  -> {guess}"
            print(f"{'  ' * depth}{raw}{mark}")
            for child in nodes[joint].get("children", []):
                if child in joint_set:
                    show(child, depth + 1)

        for joint in joints:
            if parents.get(joint) not in joint_set:
                show(joint, 0)

    mapping = {}
    for joint in joints:
        raw = nodes[joint].get("name", "")
        guess = guess_standard_name(raw)
        if guess and guess != raw:
            mapping[raw] = guess

    mapped = set(mapping.values()) | {nodes[j].get("name", "") for j in joints}
    missing = [b for b in REQUIRED_BONES if b not in mapped]
    print("\n## 對 SkeletonProfileHumanoid 的覆蓋率（TD-07）")
    print(f"必要骨骼 {len(REQUIRED_BONES) - len(missing)}/{len(REQUIRED_BONES)}")
    if missing and joints:
        problems.append("對不上的必要骨骼：" + "、".join(missing) + "。缺這些就無法 retarget 現成人形動畫。")
    optional_hit = [b for b in OPTIONAL_BONES if b in mapped]
    if optional_hit:
        print("選配骨骼：" + "、".join(optional_hit))

    extras = [nodes[j].get("name", "") for j in joints
              if guess_standard_name(nodes[j].get("name", "")) is None
              and nodes[j].get("name", "") not in REQUIRED_BONES + OPTIONAL_BONES]
    leaves = [b for b in extras if is_leaf_bone(b)]
    unmapped = [b for b in extras if not is_leaf_bone(b)]
    if unmapped:
        print(f"\n## 角色專屬骨鏈（{len(unmapped)} 根）")
        print("、".join(unmapped))
        print("這些不參與 retarget，掛在 profile 之外由角色專屬動畫驅動（例如長頸鹿的脖子）。")
    if leaves:
        print(f"\n## 葉端骨骼（{len(leaves)} 根，FBX 匯出常見，無害）")
        print("、".join(leaves))

    animations = gltf.get("animations", [])
    print(f"\n## 動畫\n{len(animations)} 支")
    for anim in animations:
        print(f"  {anim.get('name', '<未命名>')} — {animation_length(gltf, anim):.2f}s，{len(anim.get('channels', []))} 條軌")
    if not animations:
        warnings.append("沒有內嵌動畫。骨架若對得上 profile，可以用外部人形動畫庫 retarget（TD-07 選這套命名就是為了這個）。")

    if joints:
        _, size = skeleton_extent(gltf, joints, parents)
        # glTF 是 Y-up：X 寬、Y 高、Z 深。
        height = size[1]
        print(f"\n## 尺寸\n骨架 寬 {size[0]:.4g} × 高 {height:.4g} × 深 {size[2]:.4g} 公尺")
        print("（骨架的範圍，會略小於含網格的外框）")
        if height < 0.1 or height > 100.0:
            problems.append(
                f"骨架高度 {height:.4g} 公尺，明顯不合理。Meshy 的匯出單位不固定，"
                f"正規化時加 --target-height 指定身高即可。"
            )

    print("\n" + "=" * 60)
    if problems:
        print(f"\n## 擋住管線的問題（{len(problems)}）")
        for i, p in enumerate(problems, 1):
            print(f"{i}. {p}")
    if warnings:
        print(f"\n## 要注意的（{len(warnings)}）")
        for i, w in enumerate(warnings, 1):
            print(f"{i}. {w}")
    if not problems and not warnings:
        print("\n沒有發現問題。")

    if args.map:
        args.map.write_text(json.dumps(mapping, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\n改名對照表已寫入 {args.map}（{len(mapping)} 項）")

    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
