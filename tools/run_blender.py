#!/usr/bin/env python3
"""替美術管線的 Blender 腳本找到 Blender 並代為執行。

Blender 的安裝路徑很少在 PATH 上，尤其 Windows。與其每次打一長串路徑，
不如讓工具自己找：

    python tools/run_blender.py inspect assets/source
    python tools/run_blender.py normalize --input a.fbx --output b.glb

等同於手打：

    blender --background --python tools/inspect_fbx.py -- assets/source

尋找順序：BLENDER 環境變數 → PATH → 各平台的常見安裝位置（多版本取最新）。
找不到時會列出所有找過的地方，而不是只說「找不到」。
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parent

COMMANDS = {
    "inspect": "inspect_fbx.py",
    "normalize": "blender_normalize.py",
}

## normalize-all 的預設路徑：assets/source/<角色>/ 的模型 → 這裡的 <角色>.glb
SOURCE_DIR = TOOLS.parent / "assets" / "source"
OUTPUT_DIR = TOOLS.parent / "trio-project" / "assets" / "characters"
HEIGHTS = SOURCE_DIR / "characters.json"

# Blender 輸出的雜訊。預設濾掉，--raw 可以保留。
NOISE = re.compile(r"^\d{2}:\d{2}:\d{2} \| (INFO|WARNING)|^(Info|Warning|FBX|Blender quit)")


def candidate_paths():
    yield os.environ.get("BLENDER")
    yield shutil.which("blender")
    yield shutil.which("blender.exe")

    if sys.platform == "win32":
        for base in ("C:/Program Files", "C:/Program Files (x86)"):
            root = Path(base) / "Blender Foundation"
            if root.is_dir():
                # 多版本並存時取版本號最大的那個。
                for folder in sorted(root.iterdir(), key=lambda p: p.name, reverse=True):
                    yield str(folder / "blender.exe")
        yield "C:/Program Files (x86)/Steam/steamapps/common/Blender/blender.exe"
    elif sys.platform == "darwin":
        yield "/Applications/Blender.app/Contents/MacOS/Blender"
    else:
        yield "/usr/bin/blender"
        yield "/snap/bin/blender"
        yield "/usr/local/bin/blender"


def find_blender():
    tried = []
    for candidate in candidate_paths():
        if not candidate:
            continue
        tried.append(candidate)
        path = Path(candidate)
        if path.is_file() and os.access(path, os.X_OK):
            return str(path), tried
    return None, tried


def run(blender, script, extra, raw):
    command = [blender, "--background", "--python", str(script), "--", *extra]
    # 子行程的輸出一律當 UTF-8 讀。Windows 預設會用系統編碼（cp1252）解碼，
    # 而管線的腳本印的是中文——一撞到中文位元組就 UnicodeDecodeError，
    # 接著 stdout 變成 None，錯誤訊息會離真正的原因非常遠。
    # PYTHONIOENCODING 讓 Blender 內嵌的 Python 也用 UTF-8 寫出。
    environment = dict(os.environ, PYTHONIOENCODING="utf-8")
    result = subprocess.run(
        command,
        capture_output=not raw,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=environment,
    )
    if not raw:
        output = (result.stdout or "") + (result.stderr or "")
        for line in output.split("\n"):
            if line.strip() and not NOISE.match(line):
                print(line)
    return result.returncode


def normalize_all(blender, args):
    """assets/source/<角色>/ 的第一個模型 → trio-project/assets/characters/<角色>.glb

    每個角色跑一次獨立的 Blender，不共用場景——批次處理最容易出的錯
    就是前一個角色的殘留資料混進下一個。
    """
    if not SOURCE_DIR.is_dir():
        print(f"找不到 {SOURCE_DIR}", file=sys.stderr)
        return 1

    heights = {}
    if HEIGHTS.exists():
        heights = {
            k: v for k, v in json.loads(HEIGHTS.read_text(encoding="utf-8")).items()
            if not k.startswith("_")
        }
        print(f"身高設定：{HEIGHTS.name}（{len(heights)} 筆）")

    script = TOOLS / COMMANDS["normalize"]
    failed = 0
    handled = 0
    for folder in sorted(p for p in SOURCE_DIR.iterdir() if p.is_dir()):
        models = sorted(folder.rglob("*.fbx")) + sorted(folder.rglob("*.glb"))
        if not models:
            continue
        # Meshy 一個檔案一支動畫。第一個當底模，其餘只取動作併進來。
        base, animations = models[0], models[1:]
        output = OUTPUT_DIR / f"{folder.name.lower()}.glb"
        print(f"\n{'=' * 60}\n{folder.name} → {output.relative_to(TOOLS.parent)}")
        if animations:
            print(f"底模 {base.name}，另外併入 {len(animations)} 支動畫")
        extra = ["--input", str(base), "--output", str(output)]
        for path in animations:
            extra += ["--animation", str(path)]
        # 命令列給的 --target-height 優先於設定檔。
        height = heights.get(output.stem)
        if height and "--target-height" not in args.rest:
            extra += ["--target-height", str(height)]
        extra += args.rest
        if run(blender, script, extra, args.raw) != 0:
            failed += 1
        handled += 1

    print(f"\n共 {handled} 個角色，{failed} 個失敗。")
    if handled and not failed:
        print(f"接著驗貨：python tools/inspect_model.py {OUTPUT_DIR.relative_to(TOOLS.parent)}")
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(
        description="找到 Blender 並執行美術管線腳本",
        epilog="指令：" + "、".join(COMMANDS),
    )
    parser.add_argument(
        "command",
        choices=sorted(list(COMMANDS) + ["normalize-all"]),
        help="要跑哪一支腳本；normalize-all 會處理 assets/source 底下每個角色資料夾",
    )
    parser.add_argument("--raw", action="store_true", help="保留 Blender 的完整輸出")
    parser.add_argument("rest", nargs=argparse.REMAINDER, help="傳給該腳本的參數")
    args = parser.parse_args()

    blender, tried = find_blender()
    if blender is None:
        print("找不到 Blender。找過這些地方：", file=sys.stderr)
        for path in tried:
            print(f"  {path}", file=sys.stderr)
        print(
            "\n裝好之後若還是找不到，直接指路：\n"
            '  Windows：$env:BLENDER = "C:\\Program Files\\Blender Foundation\\Blender 5.0\\blender.exe"\n'
            "  其他：export BLENDER=/path/to/blender",
            file=sys.stderr,
        )
        return 1

    print(f"Blender：{blender}\n")
    if args.command == "normalize-all":
        return normalize_all(blender, args)

    script = TOOLS / COMMANDS[args.command]
    command = [blender, "--background", "--python", str(script), "--", *args.rest]

    return run(blender, script, args.rest, args.raw)


if __name__ == "__main__":
    sys.exit(main())
