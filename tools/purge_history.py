#!/usr/bin/env python3
"""把模型與貼圖的二進位從 git 歷史裡整個移除。

git 的歷史是永久的：光是刪檔案、加 .gitignore，都不會讓 repo 變小，
因為舊的 blob 還在歷史裡。要真的縮小只能改寫歷史。

    python tools/purge_history.py --dry-run                 先看會刪掉什麼
    python tools/purge_history.py --backup-to ../asset_backup --yes

**這個操作不可逆，而且會改寫已經推上去的歷史。**
只有在「只有你一個人在用這個 repo」時才安全——現在正是。
若有第二份 clone 或 CI，它們跑完之後都要重新 clone。

`git filter-repo` 結束時會做 reset --hard，所以**working tree 裡符合條件的
檔案會一併被刪除**。想留著就用 --backup-to 先複製到 repo 外面。
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GLOBS = ["assets/*.fbx", "assets/*.png"]
# filter-repo 的 glob 用 fnmatch 語意，* 會跨越 /，
# 所以上面兩條同時涵蓋 assets/source/x/y.fbx 與 assets/角色/y.fbx。
MATCH_SUFFIXES = {".fbx", ".png"}


def git(*args, check=True):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=check)


def matched_files():
    listed = git("ls-files", "assets").stdout.split("\n")
    return [ROOT / p for p in listed if p and Path(p).suffix.lower() in MATCH_SUFFIXES]


def main():
    parser = argparse.ArgumentParser(description="從 git 歷史移除模型與貼圖二進位")
    parser.add_argument("--dry-run", action="store_true", help="只顯示會刪掉什麼，不動手")
    parser.add_argument("--backup-to", type=Path, help="動手前先把這些檔案複製到這個資料夾")
    parser.add_argument("--yes", action="store_true", help="確認執行（沒有這個旗標只會 dry run）")
    args = parser.parse_args()

    if not shutil.which("git-filter-repo"):
        sys.exit("找不到 git-filter-repo。先跑：pip install git-filter-repo")

    if git("status", "--porcelain").stdout.strip():
        sys.exit("working tree 不乾淨。先 commit 或 stash，改寫歷史前狀態要單純。")

    ahead = git("rev-list", "--count", "@{u}..HEAD", check=False)
    if ahead.returncode == 0 and ahead.stdout.strip() not in ("0", ""):
        sys.exit(f"還有 {ahead.stdout.strip()} 個 commit 沒推上去。先 push，改寫後就推不上去了。")

    files = matched_files()
    total = sum(f.stat().st_size for f in files if f.exists())
    print(f"符合條件的檔案：{len(files)} 個，共 {total / 1e6:.0f} MB")
    for f in files[:8]:
        print(f"  {f.relative_to(ROOT)}")
    if len(files) > 8:
        print(f"  ...另外 {len(files) - 8} 個")
    print(f"\n目前 repo：{git('count-objects', '-vH').stdout.strip().splitlines()[-1]}")

    if args.dry_run or not args.yes:
        print("\n這是 dry run。確定要執行請加 --yes（建議同時加 --backup-to <repo 外的資料夾>）。")
        return 0

    if args.backup_to:
        destination = args.backup_to.resolve()
        if ROOT in destination.parents or destination == ROOT:
            sys.exit("備份資料夾不能在 repo 裡面——它會被一起清掉。")
        for source in files:
            if not source.exists():
                continue
            target = destination / source.relative_to(ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        print(f"\n已備份 {len(files)} 個檔案到 {destination}")

    remote = git("remote", "get-url", "origin", check=False).stdout.strip()
    print("\n改寫歷史中……")
    command = ["git-filter-repo", "--force", "--invert-paths"]
    for glob in GLOBS:
        command += ["--path-glob", glob]
    result = subprocess.run(command, cwd=ROOT)
    if result.returncode != 0:
        sys.exit("filter-repo 失敗，歷史未變動。")

    if remote:
        # filter-repo 會刻意移除 remote 當作安全機制。
        git("remote", "add", "origin", remote, check=False)
        print(f"已重新加回 remote：{remote}")

    leftover = git("rev-list", "--objects", "--all").stdout
    still_there = [ln for ln in leftover.split("\n") if ln.endswith((".fbx", ".png"))]
    print(f"\n歷史中殘留的模型／貼圖：{len(still_there)} 個（應為 0）")
    print(git("count-objects", "-vH").stdout.strip().splitlines()[-1])

    print("\n最後一步——強制推送（確認上面的數字都對再執行）：")
    print("    git push --force origin main")
    return 0


if __name__ == "__main__":
    sys.exit(main())
