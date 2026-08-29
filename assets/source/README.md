# 原始模型放這裡

Meshy 匯出的檔案（`.glb` / `.fbx`）放進這個資料夾，然後跑兩步：

```bash
# 1. 驗貨——看骨架對不對得上、面數超不超標
python3 tools/inspect_model.py assets/source/pig.glb

# 2. 正規化——改名、套用 transform、必要時 decimate、輸出乾淨 GLB
blender --background --python tools/blender_normalize.py -- \
    --input assets/source/pig.glb --output assets/source/pig_normalised.glb

# 3. 再驗一次，確認 17/17 且沒有警告
python3 tools/inspect_model.py assets/source/pig_normalised.glb
```

第 1 步若出現「猜不出來」的骨骼而它其實應該對到 profile，先用
`--map pig_bone_map.json` 產出對照表、手動補完，再用 `--map` 餵給第 2 步。

詳見〈[美術管線](../../docs/12-art-pipeline.md)〉。`_normalised.glb` 之後會搬進
`trio-project/` 由 Godot 匯入。

> **授權**：本專案採用 Meshy 付費方案（完整商用權、私有資產）。
> 免費方案的輸出為 CC BY 4.0 且模型公開，不得放進這裡。
