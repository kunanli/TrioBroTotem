#!/usr/bin/env python3
"""關卡截圖：在無顯示卡的機器上把兩張關卡各拍幾張，存成 PNG。

    python3 tools/shoot_level.py                 # 兩關都拍
    python3 tools/shoot_level.py camp            # 只拍營地
    python3 tools/shoot_level.py --out /some/dir # 指定輸出位置

為什麼做得到：這台機器沒有 GPU，但 Xvfb 提供 X11、Mesa 的 llvmpipe 提供
軟體 OpenGL 4.5，而關卡是一堆方塊不是蒙皮網格，畫得出來。

**用的是 Forward+ ＋ Vulkan，跟遊戲實際跑的渲染器完全一樣**，所以 SSAO、
glow、色調映射看到的就是真的。軟體 Vulkan 來自 Mesa 的 lavapipe。

一開始是走 Compatibility（OpenGL）的，那條路**平行光完全不會亮**——整個世界
只剩環境光與霧，而且不會有任何警告。當時差點照著那個畫面把太陽的角度調成
另一個樣子，實際上根本沒有太陽。要是哪天 lavapipe 不見了退回 OpenGL，
記得這件事：畫面整個變平、方塊沒有亮暗面，那是渲染器的問題，不是你的燈。
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "trio-project"

WORLDS = {
    "arena": "res://scenes/world/test_arena.tscn",
    "camp": "res://scenes/world/camp.tscn",
}


def find_godot() -> str:
    """Godot 執行檔。環境變數優先，其次 PATH。"""
    env = os.environ.get("GODOT")
    if env and Path(env).exists():
        return env
    found = shutil.which("godot")
    if found:
        return found
    sys.exit("找不到 Godot。設定 GODOT 環境變數指到執行檔。")


def shoot(godot: str, name: str, world: str, out_root: Path) -> bool:
    out_dir = out_root / name
    command = [
        "xvfb-run",
        "-a",
        "-s",
        "-screen 0 1280x720x24",
        godot,
        "--path",
        str(PROJECT),
        # **Forward+ ＋ Vulkan，跟遊戲實際跑的完全一樣。**
        # 這台機器沒有 GPU，但 Mesa 的 lavapipe 提供軟體 Vulkan（apt install
        # mesa-vulkan-drivers），Godot 認得，所以連 SSAO 都畫得出來。
        "--rendering-method",
        "forward_plus",
        "--rendering-driver",
        "vulkan",
        "--resolution",
        "1280x720",
        "res://scenes/tools/level_probe.tscn",
        "--",
        "--world=%s" % world,
        "--out=%s" % out_dir,
    ]
    print("拍 %s ..." % name)
    result = subprocess.run(command, capture_output=True, text=True, timeout=600)
    # Godot 在這種環境下一定會噴一堆 ALSA 與 pulseaudio 的抱怨（容器沒有音效
    # 裝置），那跟畫面無關，濾掉才看得到真正的問題。
    for line in (result.stdout + result.stderr).splitlines():
        if "ALSA" in line or "pulse" in line or "V-Sync" in line:
            continue
        if line.startswith("[Probe]") or "ERROR" in line or "SCRIPT ERROR" in line:
            print("   " + line)
    shots = sorted(out_dir.glob("*.png")) if out_dir.exists() else []
    print("   %d 張 -> %s" % (len(shots), out_dir))
    return len(shots) > 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("world", nargs="?", choices=sorted(WORLDS), help="只拍其中一關")
    parser.add_argument("--out", default=None, help="輸出資料夾（預設 ../shots）")
    args = parser.parse_args()

    if shutil.which("xvfb-run") is None:
        sys.exit("需要 xvfb-run（apt install xvfb）。")

    godot = find_godot()
    out_root = Path(args.out) if args.out else ROOT.parent / "shots"
    names = [args.world] if args.world else sorted(WORLDS)

    ok = True
    for name in names:
        ok = shoot(godot, name, WORLDS[name], out_root) and ok
    if not ok:
        print("\n有關卡一張都沒拍出來。")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
