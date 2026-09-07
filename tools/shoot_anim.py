#!/usr/bin/env python3
"""角色動畫展示：把 animation_lab 逐幀拍下來，疊成一張 GIF 與一張聯絡表。

    python3 tools/shoot_anim.py                    # 全套（15 fps、整輪播完）
    python3 tools/shoot_anim.py --seconds 6        # 只拍前六秒
    python3 tools/shoot_anim.py --width 960        # 換解析度
    python3 tools/shoot_anim.py --orbit --seconds 8   # 鏡頭繞著轉（檔案大很多）

輸出（預設 ../shots/anim/）：
    frames/0000.png …   逐幀原圖
    animation.gif       疊起來的動畫，給看不到專案的人看
    contact.png         聯絡表：每隔幾幀取一張排成方陣，用來一眼掃過整輪

**為什麼這台沒有顯示卡的機器拍得出角色**：Xvfb 給 X11、Mesa 的 lavapipe 給軟體
Vulkan，蒙皮網格畫得出來。`trio-project/README.md` 裡「llvmpipe 不畫蒙皮網格」
那句話是換成 lavapipe 之前寫的，早就不成立——這支工具就是回頭驗掉它的結果。

**一定要 `--fixed-fps`**。軟體渲染每一幀耗時忽長忽短，不鎖的話每兩張之間隔的
模擬時間都不一樣，疊成 GIF 會一頓一頓；那看起來完全像動畫做壞了，實際上是
取樣壞的。鎖住之後每一幀都正好是 1/fps 秒的模擬時間。

這台機器沒有 ffmpeg，所以 GIF 是用 Pillow 疊的（pip install pillow）。

**鏡頭預設是停住的**，`--orbit` 才會繞。這是檔案大小的問題不是美感問題：
鏡頭一動，每一幀的每一個像素都變了，GIF 的逐幀差分完全失效。實測
800×450／20 fps／21 秒，繞鏡頭的版本是 **44.8 MB**——那沒辦法傳給任何人。
停住之後只有角色在動，同一份內容掉到幾 MB。想要繞鏡頭的版本就自己加
`--orbit`，並且把秒數壓短。
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "trio-project"
SCENE = "res://scenes/tools/animation_lab.tscn"

## 整輪輪播的長度（scripts/tools/animation_lab.gd 的 PLAYLIST 加起來）。
## 這裡多留一點，寧可多拍幾幀也不要在最後一支動作播到一半就停。
DEFAULT_SECONDS = 21.0
DEFAULT_FPS = 15

## 聯絡表的格子數。4×4 剛好夠涵蓋一整輪的十三段。
CONTACT_COLUMNS = 4
CONTACT_ROWS = 4

## GIF 的上限。**PNG 逐幀是全解析度的，只有 GIF 會被降下來**——聯絡表與
## 單張細看都吃原圖，而 GIF 的用途是「傳給看不到專案的人」，傳不出去就沒用。
## 720 寬、15 fps、21 秒的原始素材直接疊出來是 18.6 MB；降到這裡是幾 MB。
GIF_MAX_WIDTH = 560
GIF_MAX_FPS = 12


def find_godot() -> str:
    env = os.environ.get("GODOT")
    if env and Path(env).exists():
        return env
    found = shutil.which("godot")
    if found:
        return found
    sys.exit("找不到 Godot。設定 GODOT 環境變數指到執行檔。")


def shoot(godot: str, out_dir: Path, frames: int, fps: int, width: int, orbit: bool) -> bool:
    height = round(width * 9 / 16)
    command = [
        "xvfb-run",
        "-a",
        "-s",
        "-screen 0 %dx%dx24" % (width, height),
        godot,
        "--path",
        str(PROJECT),
        # 跟遊戲實際跑的渲染器一樣。軟體 Vulkan 來自 Mesa 的 lavapipe。
        "--rendering-method",
        "forward_plus",
        "--rendering-driver",
        "vulkan",
        "--resolution",
        "%dx%d" % (width, height),
        # 見檔頭：不鎖幀率，取樣的間隔就不等長。
        "--fixed-fps",
        str(fps),
        SCENE,
        "--",
        "--out=%s" % out_dir,
        "--frames=%d" % frames,
        "--orbit=%d" % (1 if orbit else 0),
    ]
    print("拍 %d 幀（%d fps、%dx%d）..." % (frames, fps, width, height))
    result = subprocess.run(command, capture_output=True, text=True, timeout=3600)
    # 容器沒有音效裝置，ALSA 與 pulseaudio 一定會抱怨，跟畫面無關。
    for line in (result.stdout + result.stderr).splitlines():
        if "ALSA" in line or "pulse" in line or "V-Sync" in line:
            continue
        if line.startswith("[Lab]") or "ERROR" in line or "WARNING" in line:
            print("   " + line)
    return len(sorted(out_dir.glob("*.png"))) > 0


def build_gif(frames_dir: Path, target: Path, fps: int) -> None:
    from PIL import Image

    shots = sorted(frames_dir.glob("*.png"))
    if not shots:
        return
    # 抽幀降到 GIF_MAX_FPS。整數倍抽，不然節奏會忽快忽慢。
    step = max(1, round(fps / GIF_MAX_FPS))
    shots = shots[::step]
    gif_fps = fps / step

    # 全部共用第一幀量化出來的調色盤：讓每一幀各自量化的話，同一塊背景在
    # 不同幀會被配到不同的色號，逐幀差分完全失效，檔案會大好幾倍，
    # 而且畫面會有一層會呼吸的雜訊。
    first = Image.open(shots[0]).convert("RGB")
    size = first.size
    if size[0] > GIF_MAX_WIDTH:
        size = (GIF_MAX_WIDTH, round(size[1] * GIF_MAX_WIDTH / size[0]))
        first = first.resize(size, Image.LANCZOS)
    palette = first.quantize(colors=128, method=Image.MEDIANCUT)
    pages = [
        Image.open(path).convert("RGB").resize(size, Image.LANCZOS).quantize(palette=palette)
        for path in shots
    ]
    pages[0].save(
        target,
        save_all=True,
        append_images=pages[1:],
        duration=round(1000 / gif_fps),
        loop=0,
        optimize=True,
    )
    print("   GIF %.1f MB -> %s" % (target.stat().st_size / 1048576.0, target))


def build_contact(frames_dir: Path, target: Path) -> None:
    from PIL import Image

    shots = sorted(frames_dir.glob("*.png"))
    if not shots:
        return
    cells = CONTACT_COLUMNS * CONTACT_ROWS
    # 平均取樣整輪，不是取前 16 張——聯絡表的用處是「一眼掃過整輪」。
    picked = [shots[round(index * (len(shots) - 1) / (cells - 1))] for index in range(cells)]
    thumbs = [Image.open(path).convert("RGB") for path in picked]
    width, height = thumbs[0].size
    scale = 480 / width
    size = (round(width * scale), round(height * scale))
    sheet = Image.new("RGB", (size[0] * CONTACT_COLUMNS, size[1] * CONTACT_ROWS))
    for index, thumb in enumerate(thumbs):
        spot = ((index % CONTACT_COLUMNS) * size[0], (index // CONTACT_COLUMNS) * size[1])
        sheet.paste(thumb.resize(size, Image.LANCZOS), spot)
    sheet.save(target)
    print("   聯絡表 -> %s" % target)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=None, help="輸出資料夾（預設 ../shots/anim）")
    parser.add_argument("--seconds", type=float, default=DEFAULT_SECONDS)
    parser.add_argument("--fps", type=int, default=DEFAULT_FPS)
    parser.add_argument("--width", type=int, default=720)
    parser.add_argument("--no-gif", action="store_true", help="只留 PNG，不疊 GIF")
    parser.add_argument(
        "--orbit", action="store_true", help="鏡頭繞著轉（GIF 會大很多，見下）"
    )
    args = parser.parse_args()

    if shutil.which("xvfb-run") is None:
        sys.exit("需要 xvfb-run（apt install xvfb）。")

    out_root = Path(args.out) if args.out else ROOT.parent / "shots" / "anim"
    frames_dir = out_root / "frames"
    if frames_dir.exists():
        shutil.rmtree(frames_dir)

    frames = max(1, round(args.seconds * args.fps))
    if not shoot(find_godot(), frames_dir, frames, args.fps, args.width, args.orbit):
        print("一張都沒拍出來。")
        return 1
    build_contact(frames_dir, out_root / "contact.png")
    if not args.no_gif:
        build_gif(frames_dir, out_root / "animation.gif", args.fps)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
