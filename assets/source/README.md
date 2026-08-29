# 原始模型放這裡

Meshy 匯出的檔案（`.glb` / `.fbx`）放進這個資料夾，然後跑：

```bash
python3 tools/inspect_model.py assets/source/pig.glb --map assets/source/pig_bone_map.json
```

工具會列出骨架階層、面數、動畫清單，並比對〈[美術管線](../../docs/12-art-pipeline.md)〉的資產規格
與 TD-07 的骨骼命名規範。exit code 非 0 表示有擋住管線的問題。

正規化過的資產不放這裡，放進 `trio-project/` 底下由 Godot 匯入。

> **授權提醒**：Meshy 免費方案輸出為 CC BY 4.0 且模型公開，與商業上市不相容。
> 在把任何正式資產放進來之前先確認方案。
