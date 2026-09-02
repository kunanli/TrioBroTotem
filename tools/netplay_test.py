#!/usr/bin/env python3
"""兩個 peer 真的連起來跑一趟，然後比對兩端的狀態。

    python3 tools/netplay_test.py                # 0 ms 與 80 ms／1% 兩檔都跑
    python3 tools/netplay_test.py --only=80      # 只跑驗收那一檔

**這是這個專案第一次同時跑兩個 peer。** README 的進度表從第一天起就寫著
「已寫，未在引擎驗證」，TD-10 的延遲驗收是空的 ⬜——不是因為做不到，是因為
沒有人按下去。`scripts/net/lag_peer.gd` 早就寫好而且量過（TD-10 有實測表），
`main.gd` 早就吃 `--lag=`／`--loss=`，缺的只有「跑完之後拿什麼跟什麼比」。

**兩檔都要跑。** 只跑延遲那一檔的話，分不出「本來就壞」與「延遲之下才壞」。

這支**證不到 M0 的驗收標準**（那條是「三台機器疊高走動 30 秒」，要真人）。
它證的是必要條件：兩個 peer 連得起來、跑得完、兩端對世界的認知一致、
而且兩邊都沒有噴錯。
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "trio-project"

## 跑多久（秒）。要夠久讓客戶端連上、進任務、世界載完、同步器跑好幾輪。
SOAK_SECONDS = 14

## host 拍完指紋之後再多待幾秒才退出。理由見 run_profile。
HOST_LINGER = 6

## 位置容差（公尺）。位置是 20 Hz 同步再插值出來的，本來就不會逐位元組相同。
## 標準是「看起來在同一個地方」，不是「一模一樣」。
POSITION_TOLERANCE = 1.5

PROFILES = [
    ("0", ["--lag=0"], "區網基準"),
    ("80", ["--lag=80", "--loss=0.01"], "TD-10 的驗收檔位"),
]


def find_godot():
    direct = os.environ.get("GODOT")
    if direct and Path(direct).is_file():
        return direct
    found = shutil.which("godot")
    if found:
        return found
    sys.exit("找不到 Godot。設定 GODOT 環境變數指到執行檔。")


def launch(godot, role_args, dump, extra, linger):
    command = [
        godot, "--headless", "--path", str(PROJECT), "--",
        "--soak=%d" % SOAK_SECONDS, "--dump=%s" % dump, "--linger=%d" % linger,
    ] + role_args + extra
    return subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def errors_in(output):
    """真正的錯誤。ALSA 與 pulseaudio 的抱怨是容器沒有音效裝置，跟遊戲無關。"""
    out = []
    for line in output.splitlines():
        if "ALSA" in line or "pulse" in line or "V-Sync" in line:
            continue
        if "SCRIPT ERROR" in line or ("ERROR" in line and "res://" in line):
            out.append(line.strip())
    return out


def compare(host, client):
    """兩端的指紋。旗標與數值要完全一致，位置給容差。"""
    problems = []
    if host.get("world") != client.get("world"):
        problems.append("兩端在不同的世界：host=%s client=%s" % (host.get("world"), client.get("world")))

    beats_h, beats_c = host.get("beats", {}), client.get("beats", {})
    if set(beats_h) != set(beats_c):
        only_h = sorted(set(beats_h) - set(beats_c))
        only_c = sorted(set(beats_c) - set(beats_h))
        problems.append("兩端看到的機關不一樣：只有 host 有 %s、只有 client 有 %s" % (only_h, only_c))
    for name in sorted(set(beats_h) & set(beats_c)):
        for key in sorted(set(beats_h[name]) | set(beats_c[name])):
            a, b = beats_h[name].get(key), beats_c[name].get(key)
            if isinstance(a, float) and isinstance(b, float):
                if abs(a - b) > 0.01:
                    problems.append("%s.%s：host %.2f、client %.2f" % (name, key, a, b))
            elif a != b:
                problems.append("%s.%s：host %s、client %s" % (name, key, a, b))

    players_h, players_c = host.get("players", {}), client.get("players", {})
    if set(players_h) != set(players_c):
        problems.append("兩端的隊伍不一樣：host %s、client %s"
                        % (sorted(players_h), sorted(players_c)))
    for slot in sorted(set(players_h) & set(players_c)):
        a, b = players_h[slot], players_c[slot]
        if abs(a["health"] - b["health"]) > 0.01:
            problems.append("slot %s 血量：host %.1f、client %.1f" % (slot, a["health"], b["health"]))
        if a["downed"] != b["downed"]:
            problems.append("slot %s 倒地狀態：host %s、client %s" % (slot, a["downed"], b["downed"]))
        gap = sum((x - y) ** 2 for x, y in zip(a["position"], b["position"])) ** 0.5
        if gap > POSITION_TOLERANCE:
            problems.append("slot %s 位置差 %.2f 公尺（容差 %.1f）" % (slot, gap, POSITION_TOLERANCE))
    return problems


def run_profile(godot, name, sim, label):
    print("\n=== %s：%s ===" % (name, label))
    work = Path(tempfile.mkdtemp(prefix="netplay-"))
    host_dump, client_dump = work / "host.json", work / "client.json"
    # **兩端同時拍照，host 拍完多待一會兒再走。**
    #
    # 兩件事都踩過：host 先退出的話，客戶端會收到斷線、被踢回開始畫面、世界
    # 拆光，然後才拍到一張空的；而讓 host 單純多跑幾秒的話，兩張照片就差了
    # 五秒，場上還在動的 AI 當然對不起來（實測差 3.7 公尺，看起來像同步壞了）。
    host = launch(godot, ["--host"], host_dump, sim, HOST_LINGER)
    # host 要先把 port 開起來，客戶端才連得上。
    time.sleep(2.0)
    client = launch(godot, ["--join=127.0.0.1"], client_dump, sim, 0)

    timeout = SOAK_SECONDS + HOST_LINGER + 40
    host_out = host.communicate(timeout=timeout)[0]
    client_out = client.communicate(timeout=timeout)[0]

    problems = []
    for who, output in (("host", host_out), ("client", client_out)):
        for line in errors_in(output):
            problems.append("%s 噴錯：%s" % (who, line))
    for who, path in (("host", host_dump), ("client", client_dump)):
        if not path.exists():
            problems.append("%s 沒有寫出指紋——它可能根本沒跑完" % who)
    if not problems or (host_dump.exists() and client_dump.exists()):
        if host_dump.exists() and client_dump.exists():
            problems += compare(
                json.loads(host_dump.read_text()), json.loads(client_dump.read_text())
            )
            fingerprint = json.loads(host_dump.read_text())
            print("   host 看到 %d 拍、%d 個角色"
                  % (len(fingerprint["beats"]), len(fingerprint["players"])))
    shutil.rmtree(work, ignore_errors=True)

    if problems:
        for line in problems:
            print("   ✗ %s" % line)
    else:
        print("   ✓ 兩端一致，零錯誤")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", default=None, help="只跑某一檔（0 或 80）")
    args = parser.parse_args()

    godot = find_godot()
    failed = 0
    for name, sim, label in PROFILES:
        if args.only and args.only != name:
            continue
        failed += len(run_profile(godot, name, sim, label))

    print()
    if failed:
        print("兩個 peer 對不起來，共 %d 項。" % failed)
        return 1
    print("兩個 peer 連得起來、跑得完、兩端一致。")
    print("**這不等於 M0 過關**——M0 的標準是三台機器疊成三層走動 30 秒，那要真人。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
