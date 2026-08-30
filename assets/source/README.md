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

### 一個角色可以有多個檔案

`normalize-all` 取資料夾裡的**第一個檔案當底模**，其餘只取動作併進來
（共用同一套 rig 才行——骨骼名稱要一致）：

```
assets/source/pig_warrior/
  pig_warrior.glb        ← 底模
  Walking.fbx            ← 以下只取動作
  Running.fbx
  Standing Idle.fbx
```

檔名決定動作名稱（`Walking` → `walk`、`Standing Idle` → `idle`）。
Mixamo 下載時**務必勾 In Place**，否則位移會寫進 Hips 曲線，角色會自己往前飄。
詳細設定見 [`docs/12-art-pipeline.md`](../../docs/12-art-pipeline.md)。

攻擊、受擊、死亡不用下載——那幾支由程式生成，時間軸直接對齊 `CombatSpec`
的判定窗口（TD-12）。

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

## 這些檔案不進版控

`.gitignore` 已經擋掉這個資料夾底下的 `.fbx` / `.glb` / `.png` 等二進位。
README 與資料夾結構仍然追蹤。

**理由**：Meshy 的原始匯出隨時能重新下載，而且每次重生成都是新的一份。
它們又大（單一角色連貼圖 80 MB）又不是最終資產。版控只放正規化後、
真正進遊戲的檔案——那些每隻只有幾 MB，放在 `trio-project/assets/characters/`。

### 一次性清理（已經進過版控的話）

git 的歷史是永久的，所以光是刪檔案不會讓 repo 變小。目前歷史裡累積了
兩批模型（第一批 archer/knight/monster，第二批 Cat_Archer/Frog_Mage/Pig_Warrior），
**repo 已經 395 MB**，要改寫才拿得掉。

**在本機跑，不要在別的地方跑。** 跑完之後你的模型檔會留在硬碟上——
它們變成「未追蹤且被忽略」的檔案，不會被刪。

```
cd TrioBroTotem
git pull
pip install git-filter-repo

python tools/purge_history.py --dry-run
python tools/purge_history.py --backup-to ../TrioBroTotem_assets_backup --yes
git push --force origin main
```

腳本會先擋掉不安全的情況（working tree 不乾淨、還有沒推上去的 commit），
列出會清掉哪些檔案，備份到 repo 外面，改寫歷史，重新加回 remote，
然後印出驗證數字。**最後的強制推送刻意留給你手動執行**，確認數字都對再按。

`--backup-to` 很重要：`filter-repo` 結束時會做 `reset --hard`，
所以 working tree 裡的模型檔會一起被刪掉。要留著就先備份到 repo 外面。

> `--path-glob "assets/*.png"` 的 `*` 會跨越 `/`，所以兩批模型不管放在
> `assets/source/` 還是 `assets/<角色>/` 都會被清掉。`assets/reference/`
> 目前只有 `.jpg` 與 `.drawio`，不受影響——但之後若在那裡放 PNG，
> 記得把它從清理範圍排除。
GitHub 那邊要等它自己 gc，但新的 clone 會馬上變小。

**如果你有第二份 clone 或任何 CI，它們會壞掉**，要重新 clone。
現在只有你一個人在用，是做這件事成本最低的時機。

詳見〈[美術管線](../../docs/12-art-pipeline.md)〉。
