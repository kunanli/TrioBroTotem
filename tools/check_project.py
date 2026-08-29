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


def check_with_godot():
    """用 Godot 自己匯入一次專案。這是唯一抓得到型別錯誤的檢查。"""
    import os

    godot = os.environ.get("GODOT") or shutil.which("godot") or shutil.which("godot4")
    if not godot:
        notes.append("找不到 Godot 執行檔，跳過引擎編譯檢查（設定 GODOT 環境變數即可啟用）")
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
        errors = [
            line.strip() for line in output.split("\n")
            if ("ERROR" in line or "SCRIPT ERROR" in line) and "res://" in line
        ]
        for error in dict.fromkeys(errors):
            problems.append(f"Godot: {error}")
        notes.append(f"Godot 編譯檢查：{'無問題' if not errors else f'{len(errors)} 個錯誤'}")
        return
    notes.append("Godot 執行檔無法用 --import 或 --editor --quit 執行，跳過")


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
