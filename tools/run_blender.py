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


def main():
    parser = argparse.ArgumentParser(
        description="找到 Blender 並執行美術管線腳本",
        epilog="指令：" + "、".join(COMMANDS),
    )
    parser.add_argument("command", choices=sorted(COMMANDS), help="要跑哪一支腳本")
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

    script = TOOLS / COMMANDS[args.command]
    command = [blender, "--background", "--python", str(script), "--", *args.rest]
    print(f"Blender：{blender}\n")

    result = subprocess.run(command, capture_output=not args.raw, text=True)
    if not args.raw:
        for line in (result.stdout + result.stderr).split("\n"):
            if line.strip() and not NOISE.match(line):
                print(line)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
