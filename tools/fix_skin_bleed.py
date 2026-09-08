#!/usr/bin/env python3
"""把自動蒙皮漏進頭裡的手臂權重收回來——連續地收，不撕裂。

    python3 tools/fix_skin_bleed.py            # 只量：三隻各漏了多少（不改檔）
    python3 tools/fix_skin_bleed.py --apply    # 改 trio-project/assets/characters/*.glb
    python3 tools/fix_skin_bleed.py x.glb      # 指定檔案（可多個）

只用標準函式庫，跟 inspect_model.py 一樣不需要 Blender、Godot 或 pip。

## 這是在修什麼

Meshy 自動蒙皮是照「離哪根骨頭近」在體積裡擴散的，而這三隻是大頭身：頭直接壓在
肩膀上，肩與上臂的影響就這樣滲進了整顆頭，連頭頂（y 1.4 公尺）都有。量出來
（不帶參數就是只量）：

    青蛙  10,726 個頂點裡 2,294 個「頭為主、卻帶著外來骨權重」，平均 0.24、最高 0.68
    豬    2,505 個，平均 0.16　　貓  4,128 個，平均 0.08

結果就是**手一擺、臉就歪**：待機時手臂不動看不出來，跑步的手臂擺幅放大 0.85×1.45
之後，青蛙的臉整個剪切掉（使用者：「青蛙的臉過度扭曲」）。它跟頭骨怎麼轉沒關係——
把頭穩定層整個關掉（`GaitBob.HEAD_STEADY` 0）畫面一模一樣，就是這樣抓到的。

反方向也漏：青蛙後腦與兩側各有一片「上臂 0.5／頭 0.5」的頂點跟「頭 0.5／上臂 0.5」
的頂點交錯散佈。

## 第一版的硬規則為什麼不行

「主骨兩步外的骨骼權重一律搬走」——那片交錯區域裡相鄰的兩個頂點，一個變成 100% 跟頭、
一個變成 100% 跟手臂，後腦勺整片黑色撕裂。這種事要量：**相鄰頂點權重向量的 L1 差**，
99 百分位原檔是 1.13，硬規則 2.00（626 條邊整個翻掉）。所以任何逐頂點的硬分類
都不行，修法必須是**連續的**。

## 規則：頭殼場

1. 合法骨 = 與 Head 在骨架樹上兩步內（Neck、UpperChest）；其餘是外來骨。
2. 錨點只看兩件重跑不會變的事：**完全沒有頭權重**的頂點不是頭（−1）；帶頭權重、
   又離所有外來骨的骨段超過 `FAR`（身高的 0.17）的頂點是頭（+1）。後者是給大頭身的：
   青蛙兩側整片「頭 0.5／上臂 0.5」離肩膀很遠，用權重猜不出來，用距離一看就是頭
   （只靠平滑仍留 489–740 個頭高度的頂點沒收乾淨；加了之後是 0）。
3. 其餘（帶頭權重、又靠近手臂的那一圈）沿網格鄰接做諧和插值（反覆取鄰居平均），
   再抹幾輪，得到一個平滑的頭殼場 f∈[0,1]。
4. **上限**而不是搬比例：外來權重總和 ≤ 1−f，超過的等比削掉、搬到 Head；外來骨為主
   的頂點頭權重 ≤ f，超過的搬到主骨兩步內離頂點最近的骨。頭殼上（f=1）外來權重
   歸零，肩膀（f=0）不動，脖子根漸變。

**重跑不再變**是設計出來的：錨點只依賴「有沒有頭權重」與幾何，上限規則不會把頭權重
加到原本沒有的頂點上、也不會把它削到零，所以第二次跑算出來的場一模一樣、每個頂點
都已經在上限內。第一版用權重大小當錨，修完權重變了、場跟著長，第二次跑又搬一次，
一路搬到撕裂為止。

只修「頭 ↔ 外來骨」這一組。其他漏（左右小腿互滲、大腿帶胸）報表列出來但不動：
沒有症狀，硬分會撕。

## 之後

改完要讓 Godot 重新匯入（`godot --headless --import`）。`tools/check_project.py`
會再量一次，頭殼上還有外來權重就擋——新的 Meshy 匯出檔進來時一定會中。
"""

import argparse
import json
import math
import struct
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHARACTERS = ROOT / "trio-project" / "assets" / "characters"

## 與 Head 相隔幾步以內算合法。頭跟脖子 1 步、頭跟上胸 2 步都合理，
## 頭跟肩 3 步、頭跟上臂 4 步不可能是真的。
MAX_HOPS = 2

## 每個頂點最多幾根骨骼（glTF 的 JOINTS_0 / WEIGHTS_0 是 VEC4）。
INFLUENCES = 4

## 小於這個的權重視為零。
EPSILON = 1e-3

## 頭的骨骼（Meshy 的 FBX 會多兩根葉端骨）。
HEAD_BONES = {"Head", "head_end", "headfront"}

## 幾何錨：離所有外來骨的骨段超過身高的這個比例、又帶頭權重，就一定是頭。
## 量過：青蛙的頭錨頂點離外來骨段最近 0.19 公尺、純手臂頂點最遠 0.36，
## 身高 1.47 × 0.17 ≈ 0.25 在中間。
FAR_FRACTION = 0.17

## 諧和插值最多跑幾輪、變化小於多少就停。錨點密（沒頭權重的與離手臂遠的
## 都錨住），沒錨的只有頭靠近肩膀的那一圈，幾十輪就收斂。
MAX_SWEEPS = 300
SWEEP_TOLERANCE = 1e-4

## 平滑證據 → 頭殼程度 f 的映射範圍。範圍越寬，脖子根的過渡越軟。
FIELD_LOW = -0.8
FIELD_HIGH = 0.8

## 頭殼場算完再沿網格抹幾輪（見 head_field）。用撕裂量尺定的：不抹的話青蛙的
## p99 從 1.13 升到 1.31（脖子根一條摺痕），抹 3 輪回到 1.13，6 輪豬也回到 0.66。
FIELD_SMOOTH = 6

## 症狀：頭殼上（f 超過 SHELL）還帶著超過 LEAK 的外來權重。修完必須是 0。
SHELL = 0.99
LEAK = 0.01

## 合併重複頂點（UV 接縫）時位置四捨五入到幾位。
MERGE_DIGITS = 5

GLB_MAGIC = 0x46546C67
CHUNK_JSON = 0x4E4F534A
CHUNK_BIN = 0x004E4942

COMPONENTS = {
    5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4),
}
COUNTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


# --- GLB 讀寫 ---------------------------------------------------------------


def load_glb(path):
    """回傳 (json, bytearray(bin), bin 在檔案裡的位移, 整個檔)。"""
    data = bytearray(Path(path).read_bytes())
    magic, _version, length = struct.unpack_from("<III", data, 0)
    if magic != GLB_MAGIC:
        raise ValueError("不是 GLB：%s" % path)
    offset = 12
    doc = None
    blob = None
    blob_at = 0
    while offset < length:
        size, kind = struct.unpack_from("<II", data, offset)
        offset += 8
        if kind == CHUNK_JSON:
            doc = json.loads(bytes(data[offset:offset + size]))
        elif kind == CHUNK_BIN:
            blob = data[offset:offset + size]
            blob_at = offset
        offset += size
    if doc is None or blob is None:
        raise ValueError("GLB 缺 JSON 或 BIN 區塊：%s" % path)
    return doc, blob, blob_at, data


def accessor_layout(doc, index):
    accessor = doc["accessors"][index]
    view = doc["bufferViews"][accessor["bufferView"]]
    fmt, size = COMPONENTS[accessor["componentType"]]
    count = COUNTS[accessor["type"]]
    stride = view.get("byteStride", size * count)
    base = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    return fmt, count, stride, base, accessor["count"], accessor.get("normalized", False)


def read_accessor(doc, blob, index):
    fmt, count, stride, base, total, normalized = accessor_layout(doc, index)
    scale = {"B": 255.0, "H": 65535.0}.get(fmt) if normalized else None
    out = []
    for item in range(total):
        values = struct.unpack_from("<" + fmt * count, blob, base + item * stride)
        if scale:
            values = tuple(value / scale for value in values)
        out.append(values)
    return out


def write_accessor(doc, blob, index, rows):
    fmt, count, stride, base, total, normalized = accessor_layout(doc, index)
    assert len(rows) == total
    scale = {"B": 255.0, "H": 65535.0}.get(fmt) if normalized else None
    for item, values in enumerate(rows):
        if scale:
            values = tuple(int(round(value * scale)) for value in values)
        struct.pack_into("<" + fmt * count, blob, base + item * stride, *values)


# --- 骨架 -------------------------------------------------------------------


def invert_matrix(m):
    """4x4 反矩陣（glTF 是 column-major 的 16 個數）。高斯消去，不用 numpy。"""
    a = [
        [m[col * 4 + row] for col in range(4)] + [1.0 if row == k else 0.0 for k in range(4)]
        for row in range(4)
    ]
    for col in range(4):
        pivot = max(range(col, 4), key=lambda row: abs(a[row][col]))
        a[col], a[pivot] = a[pivot], a[col]
        factor = a[col][col]
        a[col] = [value / factor for value in a[col]]
        for row in range(4):
            if row != col and a[row][col]:
                ratio = a[row][col]
                a[row] = [x - ratio * y for x, y in zip(a[row], a[col])]
    return [[a[row][4 + col] for col in range(4)] for row in range(4)]


def segment_distance(point, start, end):
    """點到線段的距離。"""
    axis = [end[k] - start[k] for k in range(3)]
    offset = [point[k] - start[k] for k in range(3)]
    length = sum(x * x for x in axis)
    t = 0.0
    if length > 1e-12:
        t = max(0.0, min(1.0, sum(x * y for x, y in zip(offset, axis)) / length))
    return math.dist(point, [start[k] + t * axis[k] for k in range(3)])


class Rig:
    """一個 skin：骨骼名、父子關係、每根骨在網格空間的原點與骨段。"""

    def __init__(self, doc, blob, skin):
        nodes = doc["nodes"]
        self.joints = skin["joints"]
        self.names = [nodes[node].get("name", "?") for node in self.joints]
        parent = {}
        for index, node in enumerate(nodes):
            for child in node.get("children", []):
                parent[child] = index
        self.parent = parent
        # 反綁定矩陣把網格空間換到骨骼空間，反過來的平移就是骨骼在網格空間的原點。
        self.origins = []
        for matrix in read_accessor(doc, blob, skin["inverseBindMatrices"]):
            inverse = invert_matrix(matrix)
            self.origins.append((inverse[0][3], inverse[1][3], inverse[2][3]))
        self.children = defaultdict(list)
        for index, node in enumerate(self.joints):
            up = parent.get(node)
            if up in self.joints:
                self.children[self.joints.index(up)].append(index)
        self._hops = {}

    def hops(self, a, b):
        """兩根骨（skin 內的索引）在樹上隔幾步。"""
        key = (a, b) if a <= b else (b, a)
        if key not in self._hops:
            chain_a = self._chain(self.joints[a])
            chain_b = self._chain(self.joints[b])
            for up_a, node in enumerate(chain_a):
                if node in chain_b:
                    self._hops[key] = up_a + chain_b.index(node)
                    break
            else:
                self._hops[key] = 99
        return self._hops[key]

    def _chain(self, node):
        out = []
        while node is not None:
            out.append(node)
            node = self.parent.get(node)
        return out

    def segments(self, bones):
        """這些骨的骨段（原點→每個子骨原點；沒子骨的就是一個點）。"""
        out = []
        for bone in bones:
            kids = self.children.get(bone, [])
            for kid in kids:
                out.append((self.origins[bone], self.origins[kid]))
            if not kids:
                out.append((self.origins[bone], self.origins[bone]))
        return out

    def nearest_within(self, anchor, point, limit):
        """離 point 最近、且與 anchor 在 limit 步內的骨骼。"""
        best = anchor
        best_distance = None
        for joint in range(len(self.joints)):
            if self.hops(anchor, joint) > limit:
                continue
            origin = self.origins[joint]
            distance = sum((origin[axis] - point[axis]) ** 2 for axis in range(3))
            if best_distance is None or distance < best_distance:
                best, best_distance = joint, distance
        return best


# --- 網格 -------------------------------------------------------------------


class Mesh:
    """頂點鄰接。UV 接縫會把同一個位置拆成好幾個頂點，這裡依位置合併回去。"""

    def __init__(self, positions, indices):
        self.positions = positions
        lookup = {}
        self.canon = []
        for index, point in enumerate(positions):
            key = tuple(round(value, MERGE_DIGITS) for value in point)
            self.canon.append(lookup.setdefault(key, index))
        self.neighbours = defaultdict(set)
        for tri in range(0, len(indices), 3):
            a, b, c = (self.canon[indices[tri + k]] for k in range(3))
            self.neighbours[a].update((b, c))
            self.neighbours[b].update((a, c))
            self.neighbours[c].update((a, b))
        self.groups = defaultdict(list)
        for index, root in enumerate(self.canon):
            self.groups[root].append(index)
        ys = [point[1] for point in positions]
        self.height = max(ys) - min(ys)

    def edges(self):
        for a, neighbours in self.neighbours.items():
            for b in neighbours:
                if a < b:
                    yield a, b


def smoothstep(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3.0 - 2.0 * x)


def head_field(rig, mesh, joints_rows, weight_rows, head_set, legit):
    """每個頂點的頭殼程度 f∈[0,1]。見檔頭的規則 2–3。"""
    far = mesh.height * FAR_FRACTION
    foreign_segments = rig.segments([b for b in range(len(rig.joints)) if b not in legit])
    head_weight = [
        sum(w for j, w in zip(joints, weights) if w > EPSILON and j in head_set)
        for joints, weights in zip(joints_rows, weight_rows)
    ]
    anchor = {}
    value = {}
    for root, members in mesh.groups.items():
        if all(head_weight[i] <= EPSILON for i in members):
            anchor[root] = -1.0
        elif all(
            segment_distance(mesh.positions[root], a, b) > far for a, b in foreign_segments
        ):
            anchor[root] = 1.0
        else:
            anchor[root] = None
        value[root] = anchor[root] if anchor[root] is not None else 0.0
    free = [root for root, fixed in anchor.items() if fixed is None and mesh.neighbours[root]]
    for _sweep in range(MAX_SWEEPS):
        worst = 0.0
        for root in free:
            neighbours = mesh.neighbours[root]
            mean = sum(value[n] for n in neighbours) / len(neighbours)
            worst = max(worst, abs(mean - value[root]))
            value[root] = mean
        if worst < SWEEP_TOLERANCE:
            break
    field = {
        root: smoothstep((v - FIELD_LOW) / (FIELD_HIGH - FIELD_LOW)) for root, v in value.items()
    }
    # 再把 f 本身沿網格抹幾輪：錨點密的地方過渡只有一兩圈頂點，脖子根會出現一條
    # 看得到的摺痕。抹過之後頭殼深處還是 1、肩膀還是 0，只有過渡帶變寬。
    for _sweep in range(FIELD_SMOOTH):
        blurred = {}
        for root, current in field.items():
            neighbours = mesh.neighbours[root]
            if not neighbours:
                blurred[root] = current
                continue
            mean = sum(field[n] for n in neighbours) / len(neighbours)
            blurred[root] = 0.5 * current + 0.5 * mean
        field = blurred
    return [field[mesh.canon[i]] for i in range(len(joints_rows))]


def cap_vertex(rig, joints, weights, point, f, head, head_set, legit):
    """規則 4：外來權重 ≤ 1−f、外來為主時頭權重 ≤ f。回傳 (joints, weights, 搬走的量, 搬到誰)。"""
    table = defaultdict(float)
    for j, w in zip(joints, weights):
        if w > EPSILON:
            table[j] += w
    if not table:
        return list(joints), list(weights), 0.0, None
    dominant = max(table, key=table.get)
    moved = 0.0
    target = None
    foreign = sum(w for j, w in table.items() if j not in legit)
    head_total = sum(w for j, w in table.items() if j in head_set)
    cap = 1.0 - f
    # 沒有頭權重的頂點不動：它是場的 −1 錨，加了頭權重下次的場就不一樣了。
    if head_total > EPSILON and foreign > cap + 1e-6:
        keep = cap / foreign
        for j in list(table):
            if j not in legit:
                moved += table[j] * (1.0 - keep)
                table[j] *= keep
        table[head] += moved
        target = head
    elif dominant not in legit:
        # 同理，頭權重削到剩一點點就好，不削到零。
        floor = max(f, 2.0 * EPSILON)
        if head_total > floor + 1e-6:
            keep = floor / head_total
            for j in list(table):
                if j in head_set:
                    moved += table[j] * (1.0 - keep)
                    table[j] *= keep
            target = rig.nearest_within(dominant, point, MAX_HOPS)
            table[target] += moved
    pairs = sorted(((j, w) for j, w in table.items() if w > EPSILON), key=lambda p: -p[1])
    pairs = pairs[:INFLUENCES]
    total = sum(w for _j, w in pairs) or 1.0
    new_joints = [j for j, _w in pairs] + [0] * (INFLUENCES - len(pairs))
    new_weights = [w / total for _j, w in pairs] + [0.0] * (INFLUENCES - len(pairs))
    return new_joints, new_weights, moved, target


def tear(mesh, joints_rows, weight_rows):
    """撕裂量尺：相鄰頂點權重向量的 L1 差，回傳 (最大, p99, 平均)。"""
    vectors = [
        {j: w for j, w in zip(joints, weights) if w > 1e-6}
        for joints, weights in zip(joints_rows, weight_rows)
    ]
    jumps = []
    for a, b in mesh.edges():
        va, vb = vectors[a], vectors[b]
        jumps.append(sum(abs(va.get(k, 0.0) - vb.get(k, 0.0)) for k in set(va) | set(vb)))
    if not jumps:
        return 0.0, 0.0, 0.0
    jumps.sort()
    return jumps[-1], jumps[int(len(jumps) * 0.99)], sum(jumps) / len(jumps)


# --- 主流程 -----------------------------------------------------------------


def process(path, apply):
    """量一個 GLB；apply 為真時順手改掉並寫回。回傳統計。"""
    doc, blob, blob_at, data = load_glb(path)
    if not doc.get("skins"):
        return {"path": path, "skinned": False}
    stats = {
        "path": path, "skinned": True, "vertices": 0, "leaky": 0, "leak_mean": 0.0,
        "leak_max": 0.0, "shell": 0, "symptom": 0, "moved": 0.0, "targets": Counter(),
        "tear_before": (0.0, 0.0, 0.0), "tear_after": (0.0, 0.0, 0.0),
    }
    leak_total = 0.0
    dirty = False
    for mesh_index, mesh_doc in enumerate(doc["meshes"]):
        skin_index = 0
        for node in doc["nodes"]:
            if node.get("mesh") == mesh_index and "skin" in node:
                skin_index = node["skin"]
        rig = Rig(doc, blob, doc["skins"][skin_index])
        head = rig.names.index("Head") if "Head" in rig.names else -1
        if head < 0:
            continue
        head_set = {i for i, name in enumerate(rig.names) if name in HEAD_BONES}
        legit = {i for i in range(len(rig.joints)) if rig.hops(head, i) <= MAX_HOPS}
        for primitive in mesh_doc["primitives"]:
            attributes = primitive["attributes"]
            if "JOINTS_0" not in attributes or "indices" not in primitive:
                continue
            joints_rows = read_accessor(doc, blob, attributes["JOINTS_0"])
            weight_rows = read_accessor(doc, blob, attributes["WEIGHTS_0"])
            positions = read_accessor(doc, blob, attributes["POSITION"])
            indices = [row[0] for row in read_accessor(doc, blob, primitive["indices"])]
            mesh = Mesh(positions, indices)
            field = head_field(rig, mesh, joints_rows, weight_rows, head_set, legit)
            new_joints = []
            new_weights = []
            for i, (joints, weights, point) in enumerate(zip(joints_rows, weight_rows, positions)):
                stats["vertices"] += 1
                table = {j: w for j, w in zip(joints, weights) if w > EPSILON}
                dominant = max(table, key=table.get) if table else None
                foreign = sum(w for j, w in table.items() if j not in legit)
                if dominant in head_set and foreign > EPSILON:
                    stats["leaky"] += 1
                    leak_total += foreign
                    stats["leak_max"] = max(stats["leak_max"], foreign)
                if field[i] >= SHELL:
                    stats["shell"] += 1
                    if foreign > LEAK:
                        stats["symptom"] += 1
                fixed_joints, fixed_weights, moved, target = cap_vertex(
                    rig, joints, weights, point, field[i], head, head_set, legit
                )
                if moved > 0.0:
                    stats["moved"] += moved
                    stats["targets"][rig.names[target]] += 1
                new_joints.append(tuple(fixed_joints))
                new_weights.append(tuple(fixed_weights))
            stats["tear_before"] = tear(mesh, joints_rows, weight_rows)
            stats["tear_after"] = tear(mesh, new_joints, new_weights)
            if apply and stats["moved"] > 0.0:
                write_accessor(doc, blob, attributes["JOINTS_0"], new_joints)
                write_accessor(doc, blob, attributes["WEIGHTS_0"], new_weights)
                dirty = True
    if stats["leaky"]:
        stats["leak_mean"] = leak_total / stats["leaky"]
    if dirty:
        # JSON 沒動、BIN 大小沒變，直接把 BIN 那一段蓋回原檔。
        data[blob_at:blob_at + len(blob)] = blob
        Path(path).write_bytes(bytes(data))
    return stats


def audit(path):
    """給 check_project.py 用：回傳 (頭殼上還帶外來權重的頂點數, 撕裂 p99)。"""
    stats = process(path, apply=False)
    if not stats["skinned"]:
        return 0, 0.0
    return stats["symptom"], stats["tear_before"][1]


def report(stats):
    name = Path(stats["path"]).name
    if not stats["skinned"]:
        print("%s：沒有蒙皮，跳過" % name)
        return
    print(
        "%s：%d 個頂點；頭為主卻帶外來權重的 %d 個（平均 %.2f、最高 %.2f）；"
        "頭殼 %d 個頂點，其中還帶外來權重的 %d 個"
        % (
            name, stats["vertices"], stats["leaky"], stats["leak_mean"], stats["leak_max"],
            stats["shell"], stats["symptom"],
        )
    )
    print(
        "    撕裂（相鄰權重差 最大/p99/平均）原本 %.2f/%.2f/%.3f → 修後 %.2f/%.2f/%.3f；"
        "會搬 %.1f 的權重：%s"
        % (
            *stats["tear_before"], *stats["tear_after"], stats["moved"],
            "、".join("%s %d" % item for item in stats["targets"].most_common(4)) or "無",
        )
    )


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("paths", nargs="*", help="GLB 檔；不給就是 assets/characters 全部")
    parser.add_argument("--apply", action="store_true", help="真的改檔（預設只量）")
    args = parser.parse_args()
    paths = [Path(p) for p in args.paths] or sorted(CHARACTERS.glob("*.glb"))
    if not paths:
        sys.exit("找不到任何 GLB。")
    for path in paths:
        before = process(path, apply=args.apply)
        report(before)
        if args.apply and before.get("moved"):
            after = process(path, apply=False)
            print(
                "    改完再量：頭殼上還帶外來權重的 %d 個、撕裂 p99 %.2f、再跑會搬 %.2f"
                % (after["symptom"], after["tear_before"][1], after["moved"])
            )
    if not args.apply:
        print("（只量不改；要改加 --apply，改完跑 godot --headless --import）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
