# 美術管線（Meshy → Godot）

### 授權（已解決）

**採用 Meshy 付費方案**，取得完整商用權與私有資產。免費方案輸出為 CC BY 4.0 且模型公開，與商業上市不相容，因此不得用於任何會進入上市版的資產。

> 用免費方案產出的暫時素材若曾進過 repo，上市前要確認已全部替換掉。

### 共用骨架原則

所有角色使用**同一套骨骼命名與階層**，否則動畫無法共用。

- 六隻動物 × 20 個動畫 = 120 個動畫 → 不可行
- 共用骨架後 = 20 個動畫 + 少量角色專屬動作 → 可行

**因此：所有角色一律做成擬人兩足，包含長頸鹿。**四足需要另一套骨架與另一條動畫產線，且 Meshy 的四足動畫選項較少。長頸鹿的脖子作為額外骨鏈附加在標準骨架上。

**命名規範已定案**：採用 Godot 的 `SkeletonProfileHumanoid`，不自創。好處是免費打開現成人形動畫庫可供 retarget。完整說明見〈[技術決策](13-tech-decisions.md)〉TD-07。

### 工具

每隻動物都要重跑一次的雜事已經腳本化，不要用手點。

| 指令 | 做什麼 |
|---|---|
| `python3 tools/inspect_model.py <模型.glb>` | 驗貨。列出骨架階層、面數、動畫清單，比對本文規格與 TD-07 命名。只需要 Python |
| `python3 tools/inspect_model.py <模型.glb> --map m.json` | 同上，並輸出骨骼改名對照表 |
| `python3 tools/run_blender.py inspect <資料夾>` | 同上，但讀 FBX。需要 Blender |
| `python3 tools/run_blender.py normalize --input a.fbx --output b.glb` | 正規化單一模型。改名骨骼（連帶頂點群組與動畫曲線）、套用 scale/rotation、超標時 decimate、匯出乾淨 GLB |
| `python3 tools/run_blender.py normalize-all` | 把 `assets/source/<角色>/` 每一隻都正規化到 `trio-project/assets/characters/<角色>.glb`。每隻跑一次獨立的 Blender，不共用場景 |

`run_blender.py` 會自己找 Blender（`BLENDER` 環境變數 → PATH → 各平台常見安裝位置，
多版本取最新），不必每次手打一長串路徑。找不到時會列出所有找過的地方。
它等同於手打 `blender --background --python tools/<腳本> -- <參數>`。

`inspect_model.py` 在有擋住管線的問題時 exit code 非 0，可以掛進 CI。

`blender_normalize.py` 在 Blender 5.0 實測跑通；匯出參數會依版本過濾，動作曲線同時支援
4.4 前後兩種擺法，所以 4.x 也能跑。

### 角色身高由設定檔決定，不交給 Meshy

`assets/source/characters.json` 指定每隻正規化後的身高，`normalize-all` 會逐隻套用。

**為什麼要訂**：Meshy 每次生成的尺度不固定。實測三隻是 1.75 / 1.57 / **3.19** 公尺——
豬變成最高的，與本文件〈美術與音效方向〉的「豬矮寬、貓細長」完全相反。而三隻的
相對比例直接決定疊高高度、抓取距離、鏡頭距離，不能放著讓生成工具決定。

命令列的 `--target-height` 優先於設定檔，方便臨時試。

### Meshy 的匯出設定（實測後補上）

前兩批匯出全部沒過，問題都出在 Meshy 端的設定，不是模型本身：

| 問題 | 怎麼改 |
|---|---|
| 沒有骨架 | Meshy 的 **Rigging** 是獨立步驟，要另外跑。沒跑就只是靜態模型 |
| 面數大幅超標（曾出現 22 倍） | 生成時就要壓。**大幅超標時不要靠事後 decimate**——減面會優先吃掉關節處的 edge loop，正好是變形最需要它的地方 |
| 貼圖 4K（單張 25 MB） | 本作是低多邊形卡通風、色塊乾淨（docs/09），512–1024 就夠。而且分屏要渲染兩次 |

**第三批（rig 後）通過了**：三隻都是 24 根骨骼、必要骨骼 17/17、`headfront` 為共同的角色專屬骨鏈。
骨架結構三隻一致——這正是共用動畫的前提（見上方共用骨架原則）。

面數 19,508 / 10,325 / 19,473，其中兩隻約 1.3 倍超標。這個幅度靠 decimate
（比例 0.77）處理是可以接受的，跟 22 倍那種要重生成的情況不同。
若減面後關節處明顯壓扁，就改用 `--tri-max 20000` 放寬，不要硬壓。

匯出格式選 **GLB**。FBX 是二進位私有格式，`inspect_model.py` 讀不了，
要驗貨得動用 Blender（`inspect_fbx.py`），慢得多。

**四個實測踩到、值得記住的坑**：

0. **脊椎不能靠名稱判斷。** Meshy 的 `Spine` / `Spine01` / `Spine02` 會有兩個以上
   對到同一個標準名，改名時後者被跳過，留下半改名的骨架——`Chest` 跑到 `Spine`
   下面，順序整個顛倒，而且沒有任何錯誤訊息。改用階層位置：Hips 之上第一節是
   `Spine`、第二節 `Chest`、第三節 `UpperChest`。改名一律分兩階段（先改成暫時名稱），
   否則目標名稱被佔用時會靜默失敗。

0b. **根節點的 `scale 0.01` 是 Blender glTF 匯出器的正常慣例，不是問題。**
   它把骨骼寫成公分等級的位移，再用根 scale 換算回公尺。只看 scale 會誤報；
   要驗的是骨骼位移乘上根 scale 之後的**實際尺寸**。

1. **匯入檔常夾帶不屬於角色的物件。** 測試檔裡就混進一個 80 面的孤立網格。一起算面數會誤判、
   一起匯出會進遊戲。腳本因此只認「parent 是骨架，或有指向該骨架的 Armature 修改器」的網格，
   其餘一律移除並回報。
2. **骨骼改名要連動三個地方**：骨骼本身、網格的頂點群組、動作的曲線路徑。漏掉第三個時，
   骨架看起來完全正確，動畫卻整個不動，而且**不會有任何錯誤訊息**——這是最難查的一種壞法。

### 資產規格

| 項目 | 規格 |
|---|---|
| 生成 pose | T-pose（需寫進 Meshy prompt） |
| 拓撲 | 每個角色跑一次 Remesh，關節處需有 edge loop |
| 面數 | 5,000–15,000 三角面（低於 Meshy 建議上限，因未來需支援分屏雙渲染） |
| 匯出格式 | FBX（引擎管線）／GLB（Blender 與檢查用） |
| 骨骼命名 | `SkeletonProfileHumanoid`（TD-07） |

### Ragdoll 需自行建置

Meshy 提供的是動畫用 rig。Godot 的 ragdoll 需要 PhysicalBone3D、各骨骼碰撞體、關節角度限制——這些必須在 Godot 端建立。「Create Physical Skeleton」可一鍵生成骨架，但碰撞形狀與 joint 限制全部需手調，否則會抽搐或炸開。

**Ragdoll 是核心賣點，需單獨排工時（估 40–60 小時）。**這 40–60 小時大半花在手調碰撞形狀與關節限制，不是寫程式。網路同步策略與「離開 ragdoll 時的姿勢混合」見〈[技術決策](13-tech-decisions.md)〉TD-06。



---

[← 回到文件索引](../README.md)
