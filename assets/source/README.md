# 原始模型（Meshy 匯出）

**這個資料夾在 Godot 專案外面，是刻意的。** Godot 會匯入專案資料夾底下的每一個
模型檔並產生 `.import`，如果把兩、三萬面的原始匯出檔放進去，等於讓引擎替
永遠不會用到的資產建索引。原始檔留在這裡，只有正規化過的才進 `trio-project/`。

## 放法

```
assets/source/
  archer/
    archer.glb          ← Meshy 匯出的原始檔（要 GLB，不要只有 FBX）
    archer.fbx          ← 有就一起放，但工具讀的是 GLB
    textures/           ← 貼圖若是分開的檔案
  knight/
  monster/
```

## 兩步驟

```
python tools/inspect_model.py assets/source/knight/knight.glb

blender --background --python tools/blender_normalize.py -- ^
    --input assets/source/knight/knight.glb ^
    --output trio-project/assets/characters/knight.glb

python tools/inspect_model.py trio-project/assets/characters/knight.glb
```

（上面是 Windows CMD 的換行符 `^`；PowerShell 用 `` ` ``，Linux/macOS 用 `\`。
不想換行就全部寫成一行。）

第 1 步若出現「不在 profile 內」的骨骼而它其實應該對到標準骨架，
先用 `--map knight_bone_map.json` 產出對照表、手動補完，再用 `--map` 餵給第 2 步。

## 為什麼要 GLB

`.glb` 是 JSON + 二進位，工具（與 Claude）可以直接讀出骨架階層與骨骼名。
`.fbx` 是二進位私有格式，讀不了。Meshy 兩種都能匯出，先給 GLB。

## 授權

本專案採用 Meshy 付費方案（完整商用權、私有資產）。
免費方案的輸出為 CC BY 4.0 且模型公開，不得放進這裡。

## 檔案大小

模型檔直接進 git 就好。等到累積超過 1 GB 再考慮 Git LFS——
現階段 LFS 的麻煩大於好處。

詳見〈[美術管線](../../docs/12-art-pipeline.md)〉。
