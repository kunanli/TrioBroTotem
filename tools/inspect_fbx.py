#!/usr/bin/env python3
"""用 Blender 檢查 FBX。inspect_model.py 只讀得懂 glTF/GLB，FBX 要靠引擎。

    blender --background --python tools/inspect_fbx.py -- assets/source/knight
    blender --background --python tools/inspect_fbx.py -- assets/source

給資料夾就遞迴找底下所有 .fbx，給檔案就只看那一個。

檢查項目與 inspect_model.py 相同：面數、骨架、對 SkeletonProfileHumanoid
的覆蓋率、動畫數量。差別只在讀檔的方式。

**能給 GLB 就給 GLB**——inspect_model.py 不需要 Blender，跑起來快得多，
而且 Meshy 兩種格式都能匯出。
"""

import sys
from pathlib import Path

import bpy

sys.path.insert(0, str(Path(__file__).resolve().parent))
from inspect_model import (  # noqa: E402
    REQUIRED_BONES, TRI_MAX, TRI_MIN, guess_standard_name, is_leaf_bone,
)


def targets(argv):
    if "--" in argv:
        argv = argv[argv.index("--") + 1:]
    else:
        argv = [a for a in argv[1:] if not a.endswith(".py")]
    if not argv:
        raise SystemExit("用法：blender --background --python tools/inspect_fbx.py -- <檔案或資料夾>")
    found = []
    for arg in argv:
        path = Path(arg)
        if path.is_dir():
            found.extend(sorted(path.rglob("*.fbx")))
        elif path.exists():
            found.append(path)
        else:
            print(f"找不到：{path}")
    return found


def inspect(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    try:
        bpy.ops.import_scene.fbx(filepath=str(path))
    except Exception as error:
        print(f"  匯入失敗：{type(error).__name__}: {error}")
        return False

    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    armatures = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    tris = sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in meshes)

    print(f"  {len(meshes)} 個網格、{tris:,} 三角面、{len(bpy.data.actions)} 個動作")
    print(f"  材質 {len(bpy.data.materials)}、貼圖 {len(bpy.data.images)}")

    ok = True
    if tris > TRI_MAX:
        print(f"  ✗ 面數超過上限 {TRI_MAX:,}（{tris / TRI_MAX:.1f} 倍）"
              f"——要在 Meshy 生成時就控制，事後 decimate 會吃掉關節的 edge loop")
        ok = False
    elif tris < TRI_MIN:
        print(f"  ! 面數低於下限 {TRI_MIN:,}，關節處可能缺少 edge loop")

    if not armatures:
        print("  ✗ 沒有骨架——這是靜態模型。要先在 Meshy 跑 Rigging")
        return False

    bones = [b.name for b in armatures[0].data.bones]
    mapped = {}
    for bone in bones:
        guess = guess_standard_name(bone)
        if guess:
            mapped[guess] = bone
    missing = [b for b in REQUIRED_BONES if b not in mapped]
    extras = [b for b in bones if guess_standard_name(b) is None]
    leaves = [b for b in extras if is_leaf_bone(b)]
    print(f"  骨骼 {len(bones)} 根，必要骨骼 {len(REQUIRED_BONES) - len(missing)}/{len(REQUIRED_BONES)}")
    if len(extras) > len(leaves):
        print(f"  角色專屬骨鏈：{'、'.join(b for b in extras if not is_leaf_bone(b))}")
    if leaves:
        print(f"  葉端骨骼 {len(leaves)} 根（FBX 匯出常見，無害）")
    if missing:
        print(f"  ✗ 對不上：{'、'.join(missing)}")
        ok = False
    return ok


def main():
    files = targets(sys.argv)
    failed = 0
    for path in files:
        print(f"\n### {path.name}（{path.stat().st_size / 1e6:.0f} MB）")
        if not inspect(path):
            failed += 1
    print(f"\n共 {len(files)} 個檔案，{failed} 個沒過。")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
