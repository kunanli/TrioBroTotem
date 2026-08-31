#!/usr/bin/env python3
"""從 palette.gd 產生 scenes/world/materials/*.tres。

    python3 tools/sync_materials.py           # 寫檔
    python3 tools/sync_materials.py --check   # 只比對，不一致就非零退出

為什麼要兩份：`.tscn` 沒辦法呼叫程式，所以場景裡指的是 `.tres`；但程式生成的
裝飾（scenery.gd）要在程式裡拿到同一份材質，所以顏色也必須在 GDScript 裡。
兩份會漂移，所以由這支腳本負責「一份是另一份產生出來的」，並由
check_project.py 在每次檢查時 --check 一遍。

同樣的手法 check_wiring.py 已經用在 characters.json ↔ character_roster.gd
的身高比對上，理由一模一樣：兩份寫著同一個數字，遲早會有人只改一邊。
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PALETTE = ROOT / "trio-project/scripts/core/palette.gd"
OUT_DIR = ROOT / "trio-project/scenes/world/materials"

# 只有 .tscn 會指到的才需要檔案。程式生成的裝飾直接呼叫 Palette.surface()，
# 那條路徑在 palette.gd 裡會退回 build()，不需要檔案。
WANTED = [
    "turf", "cliff_face", "stone", "wood", "wood_light",
    "crate", "vine_break", "corrupt", "ember", "goal", "rock", "totem", "cliff_deep",
]


def _block(source: str, name: str) -> str:
    match = re.search(r"const %s := \{(.*?)\n\}" % name, source, re.S)
    if match is None:
        sys.exit("palette.gd 裡找不到 const %s" % name)
    return match.group(1)


def read_palette() -> tuple[dict, dict]:
    source = PALETTE.read_text(encoding="utf-8")
    colors = {}
    for key, r, g, b in re.findall(
        r'&"(\w+)": Color\(([\d.]+), ([\d.]+), ([\d.]+)\)', _block(source, "COLORS")
    ):
        colors[key] = (float(r), float(g), float(b))
    extras = {}
    for line in _block(source, "EXTRAS").splitlines():
        head = re.match(r'\s*&"(\w+)": \{(.*)\},', line)
        if head is None:
            continue
        extras[head.group(1)] = dict(re.findall(r'"(\w+)": &?"?([\w.]+)"?', head.group(2)))
    return colors, extras


def _number(value: float) -> str:
    return ("%.6f" % value).rstrip("0").rstrip(".") or "0"


def render(name: str, colors: dict, extras: dict) -> str:
    red, green, blue = colors[name]
    extra = extras.get(name, {})
    lines = ['[gd_resource type="StandardMaterial3D" format=3]', "", "[resource]"]
    alpha = 1.0
    if "alpha" in extra:
        lines.append("transparency = 1")
        alpha = float(extra["alpha"])
    lines.append(
        "albedo_color = Color(%s, %s, %s, %s)"
        % (_number(red), _number(green), _number(blue), _number(alpha))
    )
    if "roughness" in extra:
        lines.append("roughness = %s" % _number(float(extra["roughness"])))
    if "emission" in extra:
        er, eg, eb = colors[extra["emission"]]
        lines.append("emission_enabled = true")
        lines.append("emission = Color(%s, %s, %s, 1)" % (_number(er), _number(eg), _number(eb)))
        lines.append(
            "emission_energy_multiplier = %s" % _number(float(extra.get("energy", 1.0)))
        )
    return "\n".join(lines) + "\n"


def run(check_only: bool) -> list[str]:
    """回傳問題清單。check_only 為 False 時直接把檔案寫成正確內容。"""
    colors, extras = read_palette()
    problems = []
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name in WANTED:
        if name not in colors:
            problems.append("palette.gd 少了顏色 %s（materials/ 需要它）" % name)
            continue
        wanted = render(name, colors, extras)
        path = OUT_DIR / ("%s.tres" % name)
        if check_only:
            if not path.exists():
                problems.append("materials/%s.tres 不存在（跑 tools/sync_materials.py）" % name)
            elif path.read_text(encoding="utf-8") != wanted:
                problems.append(
                    "materials/%s.tres 跟 palette.gd 對不上（跑 tools/sync_materials.py）" % name
                )
        else:
            path.write_text(wanted, encoding="utf-8")
    return problems


def main() -> int:
    check_only = "--check" in sys.argv
    problems = run(check_only)
    for line in problems:
        print("  " + line)
    if not check_only:
        print("寫好 %d 份材質。" % len(WANTED))
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
