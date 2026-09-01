#!/usr/bin/env python3
"""在不開 Godot 的情況下檢查 trio-project 有沒有明顯壞掉。

    python3 tools/check_project.py

一律會做（只要有 Python）：
  - project.godot 的 autoload 與 main_scene 指到的檔案存在
  - 每個 .tscn 的 ext_resource 路徑存在
  - .tscn 裡引用的 SubResource / ExtResource id 都有定義
  - .tscn 的 parent 路徑指得到實際節點
  - .gd 檔案縮排一致（不混用 tab 與空白）
  - 接線（見 check_wiring.py）：節點路徑、autoload 成員、RPC 標註、訊號、群組

有裝下面的工具時額外做（pip install "gdtoolkit==4.*" godot-parser）：
  - gdparse：GDScript 語法
  - gdlint：風格與常見錯誤
  - godot-parser：.tscn 結構

找得到 Godot 執行檔時做最重要的一項——**用引擎自己編譯一次**：
  - 型別推導錯誤、不存在的常數或成員、資源載入失敗

  gdparse 只驗語法，抓不到 `Color.WEBGRAY`（常數不存在）或
  `var x := obj.unknown_method()`（推不出型別）這一類。只有引擎抓得到。

  Godot 不在 PATH 上時，用環境變數指路：
      set GODOT=C:\path\to\Godot_v4.7.2-stable_win64.exe   (Windows CMD)
      export GODOT=/path/to/godot                             (Linux/macOS)

exit code 非 0 表示有問題，可以直接掛進 CI。
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "trio-project"

problems = []
notes = []


def res_to_path(res):
    """res://a/b.gd -> trio-project/a/b.gd"""
    return PROJECT / res.removeprefix("res://")


def check_project_settings():
    settings = PROJECT / "project.godot"
    if not settings.exists():
        problems.append("找不到 trio-project/project.godot")
        return
    text = settings.read_text(encoding="utf-8")

    main_scene = re.search(r'run/main_scene="([^"]+)"', text)
    if not main_scene:
        problems.append("project.godot 沒有設定 run/main_scene")
    elif not res_to_path(main_scene.group(1)).exists():
        problems.append(f"main_scene 指到不存在的檔案：{main_scene.group(1)}")

    autoloads = re.findall(r'^(\w+)="\*?(res://[^"]+)"', text, re.M)
    for name, res in autoloads:
        if not res_to_path(res).exists():
            problems.append(f"autoload {name} 指到不存在的檔案：{res}")
    if autoloads:
        notes.append(f"autoload {len(autoloads)} 項全部存在")


def check_scenes():
    scenes = sorted(PROJECT.glob("scenes/**/*.tscn"))
    if not scenes:
        problems.append("scenes/ 底下沒有任何 .tscn")
        return
    for scene in scenes:
        text = scene.read_text(encoding="utf-8")
        rel = scene.relative_to(ROOT)

        for res in re.findall(r'^\[ext_resource[^\]]*path="([^"]+)"', text, re.M):
            if not res_to_path(res).exists():
                problems.append(f"{rel}: ext_resource 指到不存在的檔案：{res}")

        declared = re.match(r"\[gd_scene load_steps=(\d+)", text)
        if declared:
            actual = (len(re.findall(r"^\[ext_resource ", text, re.M))
                      + len(re.findall(r"^\[sub_resource ", text, re.M)) + 1)
            if int(declared.group(1)) != actual:
                problems.append(
                    f"{rel}: load_steps 宣告 {declared.group(1)}，實際 {actual}"
                    "（手動編輯 .tscn 後常忘了改）"
                )

        defined = set(re.findall(r'^\[(?:ext|sub)_resource[^\]]*id="([^"]+)"', text, re.M))
        used = set(re.findall(r'(?:SubResource|ExtResource)\("([^"]+)"\)', text))
        for missing in sorted(used - defined):
            problems.append(f"{rel}: 引用了未定義的資源 id：{missing}")

        known = {"."}
        for match in re.finditer(r'^\[node name="([^"]+)"(?:[^\]]*?parent="([^"]*)")?', text, re.M):
            name, parent = match.group(1), match.group(2)
            if parent is None:
                continue
            if parent not in known:
                problems.append(f"{rel}: 節點 {name} 的 parent 路徑不存在：{parent}")
            known.add(name if parent == "." else f"{parent}/{name}")
    notes.append(f"檢查了 {len(scenes)} 個場景")


def check_indentation():
    scripts = sorted(PROJECT.glob("scripts/**/*.gd"))
    for script in scripts:
        for number, line in enumerate(script.read_text(encoding="utf-8").split("\n"), 1):
            if re.match(r"^ +\S", line) or re.match(r"^\t+ +\S", line):
                problems.append(f"{script.relative_to(ROOT)}:{number} 縮排混用 tab 與空白")
    notes.append(f"檢查了 {len(scripts)} 個腳本的縮排")
    return scripts


def run_optional(scripts):
    if shutil.which("gdparse"):
        bad = [s for s in scripts
               if subprocess.run(["gdparse", str(s)], capture_output=True).returncode != 0]
        for script in bad:
            problems.append(f"{script.relative_to(ROOT)}: GDScript 語法錯誤（gdparse）")
        notes.append(f"gdparse：{len(scripts) - len(bad)}/{len(scripts)} 通過")
    else:
        notes.append('gdparse 未安裝，跳過語法檢查（pip install "gdtoolkit==4.*"）')

    if shutil.which("gdlint"):
        result = subprocess.run(["gdlint", str(PROJECT / "scripts")], capture_output=True, text=True)
        if result.returncode != 0:
            # 語法錯誤時 gdlint 會吐一整段追蹤，逐行報會蓋掉真正的問題，所以整段當一則。
            lines = [ln.strip() for ln in (result.stdout + result.stderr).split("\n")
                     if ln.strip() and not ln.startswith("Failure")]
            findings = [ln for ln in lines if re.search(r":\d+: Error:", ln)]
            if findings:
                problems.extend(f"gdlint: {ln}" for ln in findings)
            else:
                problems.append("gdlint 無法完成（多半是上面的語法錯誤造成）")
        else:
            notes.append("gdlint：無問題")

    try:
        from godot_parser import GDFile
    except ImportError:
        notes.append("godot-parser 未安裝，跳過場景結構檢查（pip install godot-parser）")
        return
    for scene in sorted(PROJECT.glob("scenes/**/*.tscn")):
        try:
            GDFile.parse(scene.read_text(encoding="utf-8"))
        except Exception as error:
            problems.append(f"{scene.relative_to(ROOT)}: 場景解析失敗 — {error}")
    notes.append("godot-parser：場景全部解析成功")


def check_materials():
    """scenes/world/materials/*.tres 必須是 palette.gd 產生出來的。

    兩份寫著同一組顏色遲早會有人只改一邊。跟 check_wiring 對
    characters.json ↔ character_roster.gd 身高的做法一樣，這裡也用比對擋住。
    """
    import sync_materials

    for line in sync_materials.run(check_only=True):
        problems.append(line)
    notes.append(f"共用材質：{len(sync_materials.WANTED)} 份與 palette.gd 一致")


# docs/07 第一章的尺寸表。**這些數字是從實測的移動能力反推出來的**
# （單人跳 1.51／兩層疊高 3.11／三層疊高 4.51），改任何一個之前要先重新量。
#
# 這張表存在是因為 docs/07 寫著「有斷言擋著」——在此之前那句話是假的：
# 上一輪的檢查寫在用完就刪的探針裡，repo 裡一個 assert 都沒有。
DIMENSIONS = [
    ("scenes/world/vine_wall.tscn", "BoxShape3D_vine", (4, 8, 0.6), "藤蔓牆（寬 4 受 HIT_RANGE 2.6 限制）"),
    ("scenes/world/test_arena.tscn", "BoxShape3D_stump", (5, 2.4, 5), "樹樁台（2.4：跳不上去，兩層疊高上得去）"),
    ("scenes/world/test_arena.tscn", "BoxShape3D_goalplat", (7, 3.6, 7), "終點台（3.6：兩層構不著，只有三層上得去）"),
    ("scenes/world/test_arena.tscn", "BoxShape3D_wall", (1, 8, 56), "走廊（56 公尺）"),
    ("scenes/world/log.tscn", "BoxShape3D_log", (1.2, 0.7, 9), "原木（9：斷崖 7 加兩端各壓 1）"),
    # 前廳（第一章往東長出來的那一段）。**這是補表不是改表**——上面五項一個字沒動。
    ("scenes/world/test_arena.tscn", "BoxShape3D_landing", (16, 1, 14), "出生高台（頂面 +0.6，全關第一個高低差）"),
    ("scenes/world/test_arena.tscn", "BoxShape3D_hall", (48, 1, 14), "前廳地面（可走寬度 14，跟走廊一樣）"),
    ("scenes/world/test_arena.tscn", "BoxShape3D_shelf", (5, 2.4, 3.6), "遠岸的台（2.4：沿用樹樁的高度，不發明第八個尺寸）"),
    ("scenes/world/test_arena.tscn", "BoxShape3D_pillar", (4, 3.6, 4), "凹室的柱子（3.6：沿用終點台的高度）"),
    ("scenes/world/gate.tscn", "BoxShape3D_gate", (15, 8, 0.6), "門（8：三層疊高跳到 4.51，翻不過去，同藤蔓牆）"),
    ("scenes/world/test_arena.tscn", "BoxShape3D_seeppool", (8, 0.85, 14), "毒池（8：橫越 1.33 秒＝16 HP。高 0.85：感應區上緣 0.55 低於墊子頂面 0.7，站在島上不中毒）"),
]

## 相鄰的兩塊地板：兩者的頂面要等高，而且沿著接縫不能有空隙。
##
## 尺寸表擋不掉這一類：凹室的地板 (12,1,10) 與前廳的地板 (48,1,14) 各自都是對的，
## 但一個在 z 17…27、一個從 z 28.5 才開始，中間**一公尺半沒有地板**。截圖上
## 那是門口一條亮黃色的帶子（看到的是前廳地板被太陽照到的側面），走過去會掉下去。
ADJACENT_FLOORS = [
    ("GroundAlcove", "BoxShape3D_alcove", "GroundHall", "BoxShape3D_hall", "z", "凹室接前廳"),
    ("GroundCorner", "BoxShape3D_corner", "GroundHall", "BoxShape3D_hall", "z", "轉角接前廳"),
    ("GroundStart", "BoxShape3D_start", "GroundCorner", "BoxShape3D_corner", "z", "走廊接轉角"),
]


def _box_sizes(text):
    """{sub_resource id: (x, y, z)}"""
    out = {}
    for block in re.split(r"^\[sub_resource ", text, flags=re.M)[1:]:
        head = block.split("]", 1)[0]
        name = re.search(r'id="([^"]+)"', head)
        size = re.search(r"size = Vector3\(([-\d., ]+)\)", block)
        if name and size:
            out[name.group(1)] = tuple(float(v) for v in size.group(1).split(","))
    return out


def _node_origin(text, node_name):
    """節點 transform 的位移，(x, y, z)。找不到回傳 None。"""
    block = re.search(
        r'\[node name="%s"[^\]]*\]\n(?:(?!\n\[node ).)*' % node_name, text, re.S
    )
    if block is None:
        return None
    origin = re.search(r"transform = Transform3D\((?:[-\d.e]+, ){9}([-\d.e]+), ([-\d.e]+), ([-\d.e]+)\)", block.group(0))
    if origin is None:
        return None
    return tuple(float(origin.group(i)) for i in (1, 2, 3))


def _node_z(text, node_name):
    """節點 transform 的 z 位移。"""
    origin = _node_origin(text, node_name)
    return None if origin is None else origin[2]


def check_floor_gaps():
    """相鄰的兩塊地板：頂面等高、接縫不能有空隙。"""
    arena = (PROJECT / "scenes/world/test_arena.tscn").read_text(encoding="utf-8")
    sizes = _box_sizes(arena)
    axis_index = {"x": 0, "z": 2}
    for near_name, near_id, far_name, far_id, axis, why in ADJACENT_FLOORS:
        near, far = _node_origin(arena, near_name), _node_origin(arena, far_name)
        if near is None or far is None or near_id not in sizes or far_id not in sizes:
            problems.append(f"test_arena.tscn: 量不到 {near_name} 與 {far_name} 的接縫（{why}）")
            continue
        index = axis_index[axis]
        near_top = near[1] + sizes[near_id][1] / 2
        far_top = far[1] + sizes[far_id][1] / 2
        if abs(near_top - far_top) > 0.001:
            problems.append(
                f"test_arena.tscn: {near_name} 頂面 {near_top:.2f}、{far_name} 頂面 {far_top:.2f}"
                f"，接在一起的地板要等高（{why}）"
            )
        low, high = sorted((near, far), key=lambda o: o[index])
        low_id = near_id if low is near else far_id
        high_id = far_id if low is near else near_id
        gap = (high[index] - sizes[high_id][index] / 2) - (low[index] + sizes[low_id][index] / 2)
        if gap > 0.001:
            problems.append(
                f"test_arena.tscn: {near_name} 與 {far_name} 中間有 {gap:.2f} 公尺沒有地板"
                f"（{why}）——走過去會掉下去"
            )
    notes.append(f"地板接縫：檢查了 {len(ADJACENT_FLOORS)} 處")


def check_dimensions():
    """docs/07 那七個從實測移動能力反推的尺寸，一格都不能動。"""
    for rel, sub_id, wanted, why in DIMENSIONS:
        path = PROJECT / rel
        if not path.exists():
            problems.append(f"{rel} 不見了（docs/07 的尺寸表指著它）")
            continue
        sizes = _box_sizes(path.read_text(encoding="utf-8"))
        if sub_id not in sizes:
            problems.append(f"{rel}: 找不到 {sub_id}（docs/07：{why}）")
            continue
        got = sizes[sub_id]
        if any(abs(a - b) > 0.001 for a, b in zip(got, wanted)):
            problems.append(
                f"{rel}: {sub_id} 是 {got}，docs/07 要求 {wanted} — {why}。"
                "改尺寸要先重新量移動能力，並且更新 docs/07 的表"
            )

    # 斷崖寬度是**兩塊地板中間的空隙**，不是任何一個盒子的尺寸，所以要另外算。
    arena = (PROJECT / "scenes/world/test_arena.tscn").read_text(encoding="utf-8")
    sizes = _box_sizes(arena)
    near_z, far_z = _node_z(arena, "GroundStart"), _node_z(arena, "GroundFar")
    if None in (near_z, far_z) or "BoxShape3D_start" not in sizes or "BoxShape3D_far" not in sizes:
        problems.append("test_arena.tscn: 量不到斷崖寬度（GroundStart/GroundFar 的盒子或位移不見了）")
    else:
        gap = (near_z - sizes["BoxShape3D_start"][2] / 2) - (far_z + sizes["BoxShape3D_far"][2] / 2)
        if abs(gap - 7.0) > 0.001:
            problems.append(
                f"test_arena.tscn: 斷崖寬 {gap:.3f}，docs/07 要求 7.0"
                "（跳不過去的 5.95 與架橋的 9.0 都靠這個數字）"
            )
    notes.append(f"docs/07 尺寸：比對 {len(DIMENSIONS)} 項 ＋ 斷崖寬度")


def find_godot():
    """找 Godot 執行檔。Godot 通常是一個獨立的 exe，很少在 PATH 上。"""
    import glob
    import os

    direct = os.environ.get("GODOT")
    if direct and Path(direct).is_file():
        return direct
    for name in ("godot", "godot4", "Godot"):
        found = shutil.which(name)
        if found:
            return found

    patterns = []
    if sys.platform == "win32":
        home = os.environ.get("USERPROFILE", "")
        patterns = [
            "C:/Program Files/Godot*/*.exe",
            "C:/Program Files (x86)/Steam/steamapps/common/Godot Engine/*.exe",
            f"{home}/AppData/Local/Programs/Godot*/*.exe",
            f"{home}/AppData/Local/Godot*/*.exe",
        ]
    elif sys.platform == "darwin":
        patterns = ["/Applications/Godot.app/Contents/MacOS/Godot"]
    else:
        patterns = ["/usr/local/bin/godot*", "/opt/godot*/godot*"]

    matches = []
    for pattern in patterns:
        matches += [m for m in glob.glob(pattern) if Path(m).is_file()]
    if not matches:
        return None
    # 多版本並存時取檔名排序最大的，通常就是最新版。
    return sorted(matches)[-1]


def check_with_godot():
    """用 Godot 自己匯入一次專案。這是唯一抓得到型別錯誤的檢查。"""
    import os

    godot = find_godot()
    if not godot:
        notes.append("找不到 Godot 執行檔，跳過引擎編譯檢查"
                     "（設定 GODOT 環境變數指到 .exe 即可啟用）")
        return

    # --import 會匯入所有資源並結束，順便編譯每一支腳本。
    # 舊版沒有這個旗標，退回 --editor --quit。
    for flags in (["--import"], ["--editor", "--quit"]):
        result = subprocess.run(
            [godot, "--headless", "--path", str(PROJECT), *flags],
            capture_output=True, text=True, timeout=300,
        )
        output = result.stdout + result.stderr
        if "Unknown main loop type" in output or "unknown argument" in output.lower():
            continue
        # `SCRIPT ERROR:` 自己就算數，**不要求同一行有 res://**。
        #
        # Godot 把檔案路徑印在**下一行**（`at: GDScript::reload (res://...)`），
        # 所以舊的 `and "res://" in line` 會把
        # `SCRIPT ERROR: Parse Error: Function "x()" not found in base self.`
        # 整條濾掉——腳本根本編不過，這裡卻報「無問題」。實際踩過一次。
        errors = [
            line.strip() for line in output.split("\n")
            if "SCRIPT ERROR" in line or ("ERROR" in line and "res://" in line)
        ]
        for error in dict.fromkeys(errors):
            problems.append(f"Godot: {error}")
        notes.append(f"Godot 匯入檢查：{'無問題' if not errors else f'{len(errors)} 個錯誤'}")
        check_scripts_compile(godot)
        check_reach(godot)
        check_beats(godot)
        return
    notes.append("Godot 執行檔無法用 --import 或 --editor --quit 執行，跳過")


def check_reach(godot):
    """每一個要打的東西，真的有地方站得到嗎？

    跑 `scenes/tools/reach_probe.tscn`：它把關卡整個載起來、對每一個
    `breakables`／`log_sockets` 的成員在周圍地面上找立足點，然後用 host 判定
    時真正呼叫的那一支 `CombatSystem.reach()` 量距離。

    這一關的由來是一次很難看的失誤：藤蔓牆加高之後打不破、第一章通不了關，
    而當時的驗證直接呼叫 `take_hit()`、**繞過了整條攻擊路徑**，所以什麼都沒測到。
    純靜態檢查抓不到這一類——要有碰撞形狀真的進了物理空間才量得出來。
    """
    result = subprocess.run(
        [godot, "--headless", "--path", str(PROJECT),
         "res://scenes/tools/reach_probe.tscn"],
        capture_output=True, text=True, timeout=300,
    )
    lines = [
        line.strip() for line in (result.stdout + result.stderr).split("\n")
        if "[Reach]" in line
    ]
    if not lines:
        notes.append("打得到檢查：探針沒有輸出，跳過")
        return
    for line in lines:
        if "打不到" in line and "個打不到" not in line or "：" in line and "公尺" in line:
            problems.append(line.replace("[Reach] ", ""))
    summary = [line for line in lines if "檢查了" in line]
    notes.append(summary[-1].replace("[Reach] ", "打得到檢查：") if summary else "打得到檢查：跑過了")


def check_beats(godot):
    """第一章的機關真的照規則跑嗎。

    跑 `scenes/tools/beat_probe.tscn`：開一個 host、把真的木箱放上板子、
    讓真的玩家站上去再倒地，一路走真的程式碼。

    `check_reach` 驗的是靜態的東西（門接得到、門檻抬得動），這一支驗行為。
    這些規則沒有一條看得出來壞了——秤錯重量的板子看起來完全正常，只是永遠
    踩不開；毒池的感應區高兩公分，站在池中央石頭上的人就會莫名其妙掉血。
    """
    result = subprocess.run(
        [godot, "--headless", "--path", str(PROJECT),
         "res://scenes/tools/beat_probe.tscn"],
        capture_output=True, text=True, timeout=300,
    )
    lines = [
        line.strip() for line in (result.stdout + result.stderr).split("\n")
        if "[Beat]" in line
    ]
    if not lines:
        notes.append("機關檢查：探針沒有輸出，跳過")
        return
    for line in lines:
        if "條規則" not in line:
            problems.append(line.replace("[Beat] ", "機關："))
    summary = [line for line in lines if "條規則" in line]
    notes.append(summary[-1].replace("[Beat] ", "機關：") if summary else "機關：跑過了")


def check_scripts_compile(godot):
    """逐支腳本跑 Godot 的 `--check-only`，也就是真的編一次。

    **為什麼需要這一關**：`--import` 不編腳本。一支呼叫了不存在的函式的腳本
    在它眼裡完全乾淨——實際踩過一次：scenery.gd 少了一個函式，check_project
    報「無問題」，直到跑起遊戲才看到 `Parse Error: Function not found`。
    gdparse 也擋不住，它只驗語法、不解析呼叫。

    **這一關的死角要講清楚**：`--check-only --script X` 是把 X 單獨編一次，
    **autoload 沒有註冊**，所以任何用到 NetworkService、DownSystem…的腳本
    會停在「Identifier not found」而編不下去。那些檔案這裡驗不到，
    只能靠 check_wiring 的 autoload 成員比對與實際跑起來。
    這裡只回報「真的編過而且過了幾支」，不假裝全部都驗了。
    """
    import subprocess

    settings = (PROJECT / "project.godot").read_text(encoding="utf-8")
    block = re.search(r"\[autoload\](.*?)(?:\n\[|\Z)", settings, re.S)
    autoloads = set(re.findall(r"^(\w+)=", block.group(1), re.M)) if block else set()

    scripts = sorted(PROJECT.glob("scripts/**/*.gd"))
    broken, skipped = [], 0
    for script in scripts:
        res = "res://" + str(script.relative_to(PROJECT)).replace("\\", "/")
        try:
            result = subprocess.run(
                [godot, "--headless", "--path", str(PROJECT), "--check-only", "--script", res],
                capture_output=True, text=True, timeout=120,
            )
        except (OSError, subprocess.SubprocessError) as error:
            notes.append(f"Godot 腳本編譯檢查跑不起來，跳過（{error}）")
            return
        lines = [
            line.strip() for line in (result.stdout + result.stderr).split("\n")
            if "SCRIPT ERROR" in line or "Parse Error" in line
        ]
        blocked = any(
            f"Identifier not found: {name}" in line for line in lines for name in autoloads
        )
        if blocked:
            skipped += 1
            continue
        for line in lines:
            broken.append(f"{script.relative_to(ROOT)}: {line}")
    for line in dict.fromkeys(broken):
        problems.append(line)
    notes.append(
        f"Godot 腳本編譯：{len(scripts) - skipped}/{len(scripts)} 支編過"
        f"（{skipped} 支用到 autoload，單獨編不了，靠 check_wiring 與實際執行擋）"
    )


def check_model_sizes():
    """名冊寫的身高 vs GLB 裡骨架的真實高度。

    這是 2026-08 那次「連上線但看不到人物」漏掉的關卡：模型被匯出成 1.5 公分高，
    程式照樣判定載入成功、把膠囊備援收起來，畫面上只剩名字標籤浮在空中。
    引擎端現在會縮放補救並警告，但錯誤的資產不該進 repo，所以在這裡也擋一次。
    """
    roster = PROJECT / "scripts/core/character_roster.gd"
    if not roster.exists():
        return
    try:
        from inspect_model import gltf_skeleton_height
    except ImportError:
        notes.append("inspect_model.py 不在同一個資料夾，跳過模型尺寸檢查")
        return

    text = roster.read_text(encoding="utf-8")
    entries = re.findall(
        r'"model":\s*"([^"]+)".*?"height":\s*([0-9.]+)', text, re.DOTALL
    )
    if not entries:
        notes.append("character_roster.gd 裡沒有讀到角色，跳過模型尺寸檢查")
        return

    checked = 0
    for res, height in entries:
        model = res_to_path(res)
        if not model.exists():
            problems.append(f"名冊指到的模型不存在：{res}")
            continue
        try:
            actual = gltf_skeleton_height(model)
        except Exception as error:  # 壞掉的 GLB 也是問題，但要說得清楚
            problems.append(f"{model.relative_to(ROOT)} 讀不出骨架高度：{error}")
            continue
        wanted = float(height)
        if actual <= 0.0:
            notes.append(f"{model.name} 沒有骨架，跳過尺寸比對")
            continue
        if abs(actual - wanted) > wanted * 0.3:
            problems.append(
                f"{model.relative_to(ROOT)} 骨架高 {actual:.4f} 公尺，"
                f"名冊寫 {wanted:.2f} 公尺。重跑美術管線："
                f"python tools/run_blender.py normalize-all"
            )
        checked += 1
    if checked:
        notes.append(f"比對了 {checked} 個角色模型的尺寸")


def check_wiring():
    """接線檢查（節點路徑、autoload 成員、RPC 標註、訊號、群組）。"""
    try:
        import check_wiring
    except ImportError:
        notes.append("check_wiring.py 不在同一個資料夾，跳過接線檢查")
        return
    found, extra = check_wiring.run(ROOT)
    problems.extend(found)
    notes.extend(extra)


def main():
    check_project_settings()
    check_scenes()
    run_optional(check_indentation())
    check_materials()
    check_dimensions()
    check_floor_gaps()
    check_model_sizes()
    check_wiring()
    check_with_godot()

    for note in notes:
        print(f"  {note}")
    if problems:
        print(f"\n發現 {len(problems)} 個問題：")
        for index, problem in enumerate(problems, 1):
            print(f"{index}. {problem}")
        return 1
    print("\n沒有發現問題。這不代表遊戲跑得起來——只代表沒有明顯壞掉。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
