#!/usr/bin/env python3
"""把遊戲打包出來。

    python3 tools/build.py              # 兩個 preset 都出
    python3 tools/build.py --only=Linux # 只出一個

**以前沒有這支腳本，也沒有任何一份文件寫過怎麼做出那個 exe。**
`build/TrioBroTotem.exe` 一直是手動產出的，而 `export_presets.cfg` 裡其實有
兩個 preset。要打包的人得自己從專案設定裡翻出來——三個月後那就是一件想不起來的事。

Linux 那一版**在開發機上跑得起來**，所以出完會直接開起來跑一下：
只驗「匯出指令回傳 0」是驗不到「exclude_filter 把不該排除的東西排掉了」
這一類問題的——那種 exe 匯得出來，開起來才發現少了東西。
"""

import argparse
import configparser
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "trio-project"
PRESETS = PROJECT / "export_presets.cfg"

## 匯出完之後開起來跑幾幀，確認它真的動得了。
##
## 用 Godot 自己的 `--quit-after`，**不要用 `--soak=`**：`scripts/tools/*` 被
## exclude_filter 排除在正式版之外，所以打包出來的東西根本沒有 soak.gd，
## `--soak=` 會被安靜地忽略，然後那個行程就永遠不會結束。
## （這正是設計要的行為，但拿它當退出條件就會掛在那裡等到逾時。）
SMOKE_FRAMES = 400


def find_godot():
    direct = os.environ.get("GODOT")
    if direct and Path(direct).is_file():
        return direct
    found = shutil.which("godot")
    if found:
        return found
    sys.exit("找不到 Godot。設定 GODOT 環境變數指到執行檔。")


def read_presets():
    """{preset 名稱: 輸出路徑}。路徑是相對於專案資料夾的。"""
    parser = configparser.ConfigParser(strict=False)
    parser.read(PRESETS, encoding="utf-8")
    out = {}
    for section in parser.sections():
        # 區段是 [preset.0] 與 [preset.0.options]，只要前者。
        if section.endswith(".options"):
            continue
        name = parser[section].get("name", "").strip('"')
        path = parser[section].get("export_path", "").strip('"')
        if name and path:
            out[name] = path
    return out


def export(godot, name, path):
    target = (PROJECT / path).resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    print("匯出 %s → %s" % (name, target))
    result = subprocess.run(
        [godot, "--headless", "--path", str(PROJECT), "--export-release", name, str(target)],
        capture_output=True, text=True, timeout=900,
    )
    output = result.stdout + result.stderr
    problems = [
        line.strip() for line in output.splitlines()
        if "ERROR" in line and "ALSA" not in line and "pulse" not in line
    ]
    for line in dict.fromkeys(problems):
        print("   %s" % line)
    if not target.exists():
        print("   ✗ 沒有產出檔案")
        return False
    print("   %.1f MB" % (target.stat().st_size / 1024 / 1024))
    return not problems


def smoke(target):
    """開起來跑幾秒。**這一關才驗得到「打包出來的東西真的動得了」。**"""
    print("   試跑 %s ..." % target.name)
    try:
        result = subprocess.run(
            [str(target), "--headless", "--quit-after", str(SMOKE_FRAMES), "--", "--host"],
            capture_output=True, text=True, timeout=180,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print("   ✗ 跑不起來：%s" % error)
        return False
    output = result.stdout + result.stderr
    bad = [
        line.strip() for line in output.splitlines()
        if ("SCRIPT ERROR" in line or ("ERROR" in line and "res://" in line))
        and "ALSA" not in line and "pulse" not in line
    ]
    for line in dict.fromkeys(bad):
        print("   %s" % line)
    if bad:
        return False
    print("   ✓ 開得起來、開得了房、零錯誤")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", default=None, help="只出這一個 preset")
    args = parser.parse_args()

    if not PRESETS.exists():
        sys.exit("找不到 %s" % PRESETS)
    godot = find_godot()
    presets = read_presets()
    if not presets:
        sys.exit("export_presets.cfg 裡沒有可用的 preset")

    ok = True
    for name, path in presets.items():
        if args.only and args.only != name:
            continue
        if not export(godot, name, path):
            ok = False
            continue
        target = (PROJECT / path).resolve()
        # 只有跑得動的那一個平台才試得了。
        if sys.platform.startswith("linux") and target.suffix != ".exe":
            if not smoke(target):
                ok = False

    print()
    if not ok:
        print("打包有問題。")
        return 1
    print("打包完成。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
