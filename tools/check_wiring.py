#!/usr/bin/env python3
"""接線檢查：語法對、路徑存在，但接錯線的那一類問題。

語法檢查抓不到 `$Visaul/CarryAnchor` 這種打錯的節點路徑——它在編輯器裡
要等執行到那一行才炸，而且訊息是「null instance」，離真正的原因很遠。
這裡把這類問題在不開 Godot 的情況下抓出來。

檢查五件事：

  1. 腳本裡的 $NodePath 在掛著該腳本的場景中存在
  2. 用到的 autoload 名稱有在 project.godot 註冊
  3. 呼叫 .rpc() / .rpc_id() 的方法真的有 @rpc 標註
  4. .connect() 的回呼函式與訊號都存在
  5. get_nodes_in_group() 用到的群組名有人 add_to_group

被 check_project.py 呼叫，也可以單獨跑：

    python3 tools/check_wiring.py
"""

import re
import sys
from pathlib import Path

# Node / Object 的常見成員。autoload 上呼叫這些不算錯。
NODE_BUILTINS = {
    "call_deferred", "set_deferred", "connect", "disconnect", "emit_signal",
    "get_node", "get_node_or_null", "get_tree", "get_parent", "add_child",
    "queue_free", "is_inside_tree", "name", "owner", "process_mode",
    "set_multiplayer_authority", "is_multiplayer_authority", "multiplayer",
    "rpc", "rpc_id", "has_method", "get_path", "add_to_group", "is_in_group",
    "new", "free", "get", "set", "call",
}


## Godot 的全域常數。前綴涵蓋大部分，少數單獨列出。
GODOT_PREFIXES = (
    "KEY_", "JOY_", "MOUSE_", "PROPERTY_", "ERR_", "TYPE_", "METHOD_",
    "NOTIFICATION_", "CORNER_", "SIDE_", "HORIZONTAL_", "VERTICAL_", "OP_",
)
GODOT_GLOBALS = {"INF", "NAN", "PI", "TAU", "OK", "FAILED", "TRUE", "FALSE", "SIZE"}


def parse_scene(path):
    """回傳 {節點完整路徑: {'type':…, 'script':…}}，根節點的路徑是 '.'。"""
    text = path.read_text(encoding="utf-8")
    ext = dict(re.findall(r'^\[ext_resource[^\]]*path="([^"]+)"[^\]]*id="([^"]+)"', text, re.M))
    ext_by_id = {v: k for k, v in ext.items()}

    nodes = {}
    for block in re.split(r"^\[node ", text, flags=re.M)[1:]:
        header = block.split("]", 1)[0]
        name = re.search(r'name="([^"]+)"', header)
        if not name:
            continue
        name = name.group(1)
        parent = re.search(r'parent="([^"]*)"', header)
        node_type = re.search(r'type="([^"]+)"', header)
        script_id = re.search(r'script = ExtResource\("([^"]+)"\)', block)

        if parent is None:
            full = "."
        elif parent.group(1) == ".":
            full = name
        else:
            full = f"{parent.group(1)}/{name}"

        nodes[full] = {
            "type": node_type.group(1) if node_type else "(instance)",
            "script": ext_by_id.get(script_id.group(1)) if script_id else None,
        }
    return nodes


def script_members(text):
    """腳本裡定義了哪些名字。"""
    members = set()
    members |= set(re.findall(r"^(?:static\s+)?func\s+(\w+)", text, re.M))
    members |= set(re.findall(r"^(?:@export\s+)?var\s+(\w+)", text, re.M))
    members |= set(re.findall(r"^@export\s+var\s+(\w+)", text, re.M))
    members |= set(re.findall(r"^const\s+(\w+)", text, re.M))
    members |= set(re.findall(r"^enum\s+(\w+)", text, re.M))
    members |= set(re.findall(r"^signal\s+(\w+)", text, re.M))
    return members


def rpc_methods(text):
    """有 @rpc 標註的函式名。"""
    return set(re.findall(r"@rpc\([^)]*\)\s*\n\s*func\s+(\w+)", text))


def signals(text):
    return set(re.findall(r"^signal\s+(\w+)", text, re.M))


def run(root):
    project = root / "trio-project"
    problems, notes = [], []

    settings = (project / "project.godot").read_text(encoding="utf-8")
    autoloads = {
        name: project / res.removeprefix("res://")
        for name, res in re.findall(r'^(\w+)="\*?(res://[^"]+)"', settings, re.M)
    }
    autoload_text = {n: p.read_text(encoding="utf-8") for n, p in autoloads.items() if p.exists()}

    scripts = sorted(project.glob("scripts/**/*.gd"))
    script_text = {s: s.read_text(encoding="utf-8") for s in scripts}
    scenes = {s: parse_scene(s) for s in sorted(project.glob("scenes/**/*.tscn"))}

    # 腳本 -> 掛著它的 (場景, 節點路徑)
    attached = {}
    for scene_path, nodes in scenes.items():
        for node_path, info in nodes.items():
            if info["script"]:
                target = project / info["script"].removeprefix("res://")
                attached.setdefault(target, []).append((scene_path, node_path))

    # --- 1. $NodePath ---
    checked_paths = 0
    for script, text in script_text.items():
        literals = set(re.findall(r"\$([A-Za-z_][\w/]*)", text))
        # 只認自己身上的 get_node()。x.get_node_or_null(...) 是問別的節點，
        # 那個節點是誰要執行期才知道，靜態驗不了。
        literals |= set(re.findall(r'(?<![.\w])get_node(?:_or_null)?\("([^"/][^"]*)"\)', text))
        if not literals:
            continue
        hosts = attached.get(script, [])
        if not hosts:
            problems.append(
                f"{script.relative_to(root)}: 用了 {sorted(literals)} 但沒有任何場景掛著這個腳本，無法驗證"
            )
            continue
        for scene_path, node_path in hosts:
            nodes = scenes[scene_path]
            for literal in sorted(literals):
                full = literal if node_path == "." else f"{node_path}/{literal}"
                checked_paths += 1
                if full not in nodes:
                    problems.append(
                        f"{script.relative_to(root)}: $"
                        f"{literal} 在 {scene_path.name} 的 {node_path} 底下不存在"
                    )
    notes.append(f"節點路徑：檢查了 {checked_paths} 條")

    # --- 2. autoload 名稱與成員 ---
    unknown_members = 0
    for script, text in script_text.items():
        body = re.sub(r"^\s*#.*$", "", text, flags=re.M)
        for name, member in re.findall(r"\b([A-Z]\w+)\.(\w+)", body):
            if name not in autoload_text:
                continue
            if member in NODE_BUILTINS or member in script_members(autoload_text[name]):
                continue
            unknown_members += 1
            problems.append(f"{script.relative_to(root)}: {name}.{member} 在 {name} 裡找不到定義")
    notes.append(f"autoload：{len(autoloads)} 項，成員參照 {unknown_members} 處對不上")

    # --- 3. RPC ---
    rpc_calls = 0
    for script, text in script_text.items():
        for obj, method in re.findall(r"(?:\b(\w+)\.)?(\w+)\.rpc(?:_id)?\(", text):
            rpc_calls += 1
            if obj in autoload_text:
                target_text, where = autoload_text[obj], obj
            elif obj in ("", "self", None):
                target_text, where = text, script.name
            else:
                continue  # 透過區域變數呼叫，靜態看不出來
            if method not in rpc_methods(target_text):
                problems.append(
                    f"{script.relative_to(root)}: 對 {where}.{method} 呼叫 .rpc()，"
                    f"但該函式沒有 @rpc 標註"
                )
    notes.append(f"RPC：檢查了 {rpc_calls} 處呼叫")

    # --- 4. connect ---
    connects = 0
    for script, text in script_text.items():
        for obj, signal_name, callback in re.findall(r"\b(\w+)\.(\w+)\.connect\((\w+)\)", text):
            connects += 1
            if obj in autoload_text and signal_name not in signals(autoload_text[obj]):
                problems.append(f"{script.relative_to(root)}: {obj} 沒有訊號 {signal_name}")
            if callback not in script_members(text):
                problems.append(f"{script.relative_to(root)}: connect 到不存在的 {callback}()")
        for signal_name, callback in re.findall(r"^\s*(\w+)\.connect\((\w+)\)", text, re.M):
            connects += 1
            if signal_name not in signals(text) and callback not in script_members(text):
                problems.append(f"{script.relative_to(root)}: connect 到不存在的 {callback}()")
    notes.append(f"訊號連接：檢查了 {connects} 處")

    # --- 4b. 用到但沒宣告的常數 ---
    #
    # gdparse 只驗語法，抓不到「常數改名後有一處沒跟著改」——那在編輯器裡
    # 要等執行到那一行才會報 Identifier not declared。實際踩過一次。
    undeclared = 0
    for script, text in script_text.items():
        body = re.sub(r"#.*$", "", text, flags=re.M)
        body = re.sub(r'"[^"]*"', '""', body)
        declared = set(re.findall(r"^const\s+([A-Z][A-Z0-9_]*)", text, re.M))
        for block in re.findall(r"^enum\s+\w*\s*\{([^}]*)\}", text, re.M | re.S):
            declared |= set(re.findall(r"([A-Z][A-Z0-9_]*)", block))
        for name in sorted(set(re.findall(r"(?<![.\w$])([A-Z][A-Z0-9_]{2,})\b", body))):
            if name in declared or name in GODOT_GLOBALS:
                continue
            if any(name.startswith(prefix) for prefix in GODOT_PREFIXES):
                continue
            undeclared += 1
            problems.append(f"{script.relative_to(root)}: 用到未宣告的常數 {name}")
    notes.append(f"常數：{undeclared} 個用到但沒宣告")

    # --- 5. 角色身高：管線設定檔與遊戲名冊必須一致 ---
    heights_file = root / "assets" / "source" / "characters.json"
    roster_file = project / "scripts" / "core" / "character_roster.gd"
    if heights_file.exists() and roster_file.exists():
        import json

        config = {
            k: float(v)
            for k, v in json.loads(heights_file.read_text(encoding="utf-8")).items()
            if not k.startswith("_")
        }
        roster = {
            m[0]: float(m[1])
            for m in re.findall(
                r'&"(\w+)":\s*\{[^}]*?"height":\s*([\d.]+)',
                roster_file.read_text(encoding="utf-8"),
                re.S,
            )
        }
        for name in sorted(set(config) | set(roster)):
            if config.get(name) != roster.get(name):
                problems.append(
                    f"角色 {name} 的身高不一致："
                    f"characters.json {config.get(name)} vs character_roster.gd {roster.get(name)}"
                    "（碰撞體會對不上模型）"
                )
        notes.append(f"角色身高：比對 {len(set(config) | set(roster))} 隻")

    # --- 5. 群組 ---
    added, used = set(), set()
    for text in script_text.values():
        added |= set(re.findall(r'add_to_group\("([^"]+)"\)', text))
        used |= set(re.findall(r'get_nodes_in_group\("([^"]+)"\)', text))
        used |= set(re.findall(r'is_in_group\("([^"]+)"\)', text))
    for scene_text in (p.read_text(encoding="utf-8") for p in scenes):
        added |= set(re.findall(r'groups = \[([^\]]*)\]', scene_text))
    for group in sorted(used - added):
        problems.append(f'沒有任何地方 add_to_group("{group}")，但有人在讀這個群組')
    notes.append(f"群組：{len(added)} 個加入、{len(used)} 個讀取")

    return problems, notes


def main():
    root = Path(__file__).resolve().parent.parent
    problems, notes = run(root)
    for note in notes:
        print(f"  {note}")
    if problems:
        print(f"\n發現 {len(problems)} 個問題：")
        for index, problem in enumerate(problems, 1):
            print(f"{index}. {problem}")
        return 1
    print("\n接線檢查：沒有發現問題。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
