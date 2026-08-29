# 技術決策紀錄

這份文件只記錄**已經拍板、且事後改動成本很高**的技術決定。每項包含決定、理由、以及「什麼情況下該重新檢討」。

設計問題請看〈[待決事項](OPEN-QUESTIONS.md)〉，工時與範圍請看〈[開發里程碑](11-roadmap.md)〉。

---

## TD-01・渲染器：Forward+

| | |
|---|---|
| 決定 | `renderer/rendering_method = forward_plus` |
| 狀態 | 已套用至 `trio-project/project.godot` |

**理由**：目標平台是 PC / Steam，美術方向是低多邊形卡通風與少量光源，離 GPU 瓶頸很遠。Compatibility 渲染器在後處理、compute 與部分螢幕空間效果上有明確限制，而**為某一渲染器寫的 shader 無法無痛搬到另一個**——水面、腐化溶解、命中閃白、描邊全部綁在這個選擇上。用 Compatibility 換到的效能，換不回損失的表現力。

**同時移除**：`rendering_device/driver.windows = "d3d12"`。該設定在 Compatibility 下無效，在 Forward+ 下會強制走 D3D12 後端；預設的 Vulkan 更穩，需要時再開。

**重新檢討的觸發條件**：M2 實測分屏雙渲染在目標最低規格上掉到 60 FPS 以下。屆時的選項是降 Mobile 渲染器，而不是回 Compatibility。

---

## TD-02・網路權威模型：自己的角色 client 權威，其餘 host 權威

| 項目 | 權威方 |
|---|---|
| 自己角色的移動與跳躍 | **該玩家的 client** |
| 抓取判定（重量規則）、投擲結果 | host |
| 傷害、血量、倒地狀態 | host |
| 敵人 AI 與位置 | host |
| 場景物理物件（原木、石頭、礦車） | host |
| 疊高狀態機（成立、順序、潰散） | host |
| 章節進度、控制點、寶箱 | host |

**理由**：三人合作 PvE，作弊沒有意義。完整 server authority + 預測回滾能換到的只有抗延遲，代價是 100 小時以上的額外工程，對本作是過度工程。反之純 server authority 無預測會產生輸入延遲，與〈[戰鬥與敵人](05-combat.md)〉的 Overcooked 回饋速度基準直接衝突。

**實作硬規則**：

- 抓取是 **request → host 驗證重量階梯 → 廣播結果**，客戶端絕不自行決定抓取成立
- 客戶端上的場景物理物件關閉物理運算，只做插值跟隨 host 的 transform
- 客戶端可以樂觀播放攻擊動畫與命中特效，但**扣血一律等 host**

**重新檢討的觸發條件**：M0 的延遲測試（見 TD-10）顯示 client 權威移動導致隊友位置飄移到影響抓取與疊高。

---

## TD-03・傳輸層：開發用 ENet，上市用 Steam relay

**決定**：M0–M3 使用內建 `ENetMultiplayerPeer`；上市前換成 Steam 的 P2P / relay（`SteamMultiplayerPeer`）。

**理由**：〈[開發里程碑](11-roadmap.md)〉M4 已指出「兩個朋友連不上線」會直接變成退款。裸 ENet 在真實家用網路（雙層 NAT、CGNAT）下的連線失敗率不可接受，這個問題的解法是 Steam 的 NAT 打洞與中繼伺服器，不是自己寫連線碼。

**現在就要做的事**：把 peer 的建立與銷毀**全部收在單一 autoload**（`NetworkService`）裡，遊戲其他部分只呼叫 `host_game()` / `join_game()`，不直接碰 `MultiplayerPeer`。這樣未來換傳輸層是改一個檔案，而不是全專案搜尋。

---

## TD-04・玩家身分抽象：一個 peer ≠ 一個玩家

**決定**：從 M0 第一行程式開始，玩家身分即為獨立資料結構，不得用 `peer_id` 當作玩家識別。

```
PlayerSlot {
    slot_id            # 0..2，隊伍中的位置
    peer_id            # 哪台機器（本地 AI 為 host 的 peer_id）
    input_device       # 哪個輸入裝置（同一 peer 可有多個）
    is_ai              # 是否由 AI 接管
    possessed_character # 目前操控哪隻角色
}
```

**理由**：這一層同時撐起三件**已經寫進設計文件**的功能——

| 功能 | 出處 | 沒有這層會怎樣 |
|---|---|---|
| 2 人本地分屏 + 1 人線上 | 〈[連線、營地與分屏](08-multiplayer-camp.md)〉 | 同一 peer 兩個玩家無法表達 |
| AI 夥伴補位、玩家中途接手 | 〈[開發里程碑](11-roadmap.md)〉Must | 接手＝換 peer，狀態全斷 |
| 營地換角色（possess 交換） | 〈[連線、營地與分屏](08-multiplayer-camp.md)〉 | 身分與角色綁死，無法交換 |

**這是唯一一件「功能延到上市後、但位子現在就得留」的事。** 現在寫死只省數小時，兩年後拆是數十小時，且會動到連線核心。

**注意**：本項不代表要在 M0 實作分屏。M0 只需要讓 `PlayerSlot` 存在且正確，分屏仍照〈開發里程碑〉延到上市後更新。

---

## TD-05・疊高同步：邏輯附掛，不做網路化剛體堆疊

**決定**：疊高成立時，上層角色改為**邏輯附掛**於下層——其 transform 由「底座 transform + 本地 offset」推導，整柱以單一實體同步。上層的移動輸入轉為鏡頭與掙扎輸入。潰散＝解除附掛 + 施加分離衝量 + 全員 ragdoll。

**理由**：網路化的剛體堆疊在任何引擎上都極難做穩，Jolt 也只是讓單機堆疊更穩，不解決同步問題。改成附掛後，全案最高風險項從「物理同步問題」降級成「狀態機 + 父子關係問題」，後者是可以做對的。

**這與設計文件一致**：〈[核心系統](04-systems.md)〉本來就寫「底層移動時上層跟隨」「順序由重量決定」——上層是乘客，不是共同施力者。附掛模型正好是這句話的直接實作。

**Jolt 的職責**：只負責潰散那一瞬間之後的表現，以及非疊高狀態下的一般物理。

**驗收**：見 TD-10。

---

## TD-06・Ragdoll 同步：狀態與根位置同步，骨骼各機自算

**決定**：

| 同步 | 不同步 |
|---|---|
| 進入／離開 ragdoll 的狀態切換 | 每根 `PhysicalBone3D` 的 transform |
| 觸發當下的衝量（方向與大小） | 骨骼的模擬過程 |
| host 權威的**根位置** | — |

**理由**：逐骨同步的頻寬與抖動都不可接受。三台機器上手腳擺的姿勢略有差異完全無妨——那反而符合〈[核心定位](01-overview.md)〉的「事故就是內容」。

**但根位置必須是 host 權威**：「你倒在哪」決定隊友能不能扶到你（〈[核心系統](04-systems.md)〉倒地救援）。若各機自算根位置，會出現「我明明站在他旁邊卻扶不到」這種最傷體驗的 bug。

**已知難點**（列入〈[美術管線](12-art-pipeline.md)〉的 40–60 小時內）：離開 ragdoll 時要擷取當下姿勢，在 0.2–0.3 秒內混合到起身動畫首幀。直接切回站姿會「啪」地彈回去，是最破壞喜劇感的畫面。另外 Godot 的 Create Physical Skeleton 一鍵產物必定抽搐，碰撞形狀與關節角度限制全部要手調——這 40–60 小時大半花在手調，不是寫程式。

---

## TD-07・骨骼命名：採用 Godot 的 SkeletonProfileHumanoid

**決定**：不自創命名規範。所有角色一律使用 Godot `SkeletonProfileHumanoid` 的骨骼命名與階層，import 時以 `BoneMap` 重定向。

**理由**：〈[美術管線](12-art-pipeline.md)〉已決定全角色擬人兩足。既然如此，採用標準人形骨架等於免費打開整個現成人形動畫庫（Mixamo 等）可供 retarget。單人開發者的 20 支共用動畫，能重定向現成的就不該自己做。

**主要骨骼**（完整清單以 Godot 的 profile 為準）：

```
Root / Hips / Spine / Chest / UpperChest / Neck / Head
LeftShoulder  / LeftUpperArm  / LeftLowerArm  / LeftHand
RightShoulder / RightUpperArm / RightLowerArm / RightHand
LeftUpperLeg  / LeftLowerLeg  / LeftFoot  / LeftToes
RightUpperLeg / RightLowerLeg / RightFoot / RightToes
```

**角色專屬骨鏈**（長頸鹿的脖子、豬的耳朵、貓的尾巴等）掛在 profile 之外，不參與重定向，由角色專屬動畫或 secondary motion 驅動。

**Meshy prompt 需求**：T-pose、關節處有 edge loop、5,000–15,000 三角面（見〈美術管線〉資產規格）。

---

## TD-08・不使用 Root Motion

**決定**：角色位移完全由程式碼計算，動畫只負責視覺表現。

**理由**：Root motion 讓位移量來自動畫曲線，與網路預測、client 權威移動（TD-02）、以及疊高附掛（TD-05）全部衝突。動畫與移動速度的匹配用調整播放速率解決，不用 root motion。

**例外**：無位移需求的過場與情境動作（開寶箱、儀式）可使用，因為那些狀態下角色本來就不接受移動輸入。

---

## TD-09・Shader：排在 M1 之後，兩項做法先定

**決定**：M0 的 shader 工作量為零。M1 只做兩支：命中閃白、角色描邊。水面、腐化溶解、圖騰發光、合體特效全部排到 M2。

**理由**：shader 有即時的成就感，是單人開發最容易提前開工的項目，然後手感原型永遠沒開始。〈[開發里程碑](11-roadmap.md)〉M1 的驗收標準是「朋友有沒有笑」，那件事不需要任何 shader。

**兩項現在就定的做法**：

| 項目 | 做法 | 理由 |
|---|---|---|
| 角色描邊 | **Inverted hull**——第二個 material pass，`cull_front` + 沿法線外推 | 螢幕空間邊緣偵測在分屏雙視口下要跑兩次；inverted hull 是幾何的一部分，對分屏天然免費 |
| 命中閃白 | **`instance uniform`**，以 `GeometryInstance3D.set_instance_shader_parameter()` 驅動 | 〈[戰鬥與敵人](05-combat.md)〉要求閃白 0.05 秒且頻率極高，複製材質做切換會造成大量 material 切換 |

---

## TD-10・M0 驗收標準補上延遲測試

**原標準**（〈[開發里程碑](11-roadmap.md)〉）：三台機器連線，疊成三層走動 30 秒不崩、不抖、不穿模。

**補充**：上述測試必須在 **80–150 ms 延遲 + 1% 丟包**的條件下重跑一次才算通過。

**理由**：區網測試幾乎一定會過，然後上市炸掉。人工延遲用 `clumsy`（Windows）或 `tc netem`（Linux）注入。撐不住的話 M0 就是失敗——而那正是你花三個月要買到的答案。

---

## M0 工作切分

依風險由高到低排序，並把 ragdoll 往前挪（它與疊高潰散共用邏輯）。全程膠囊體，零美術、零動畫、零 shader。

| # | 項目 | 對應決策 | 產出 |
|---|---|---|---|
| 0 | `NetworkService` autoload + `PlayerSlot` 抽象 + 連線大廳 | TD-03, TD-04 | 三個膠囊在連線下能移動、跳 |
| 1 | 抓取與投擲同步 | TD-02 | 重量階梯判定由 host 執行 |
| 2 | **疊高同步**（最高風險） | TD-05 | 三層柱可移動 |
| 3 | Ragdoll 與倒地救援 | TD-06 | 潰散、扶起、扛走 |
| 4 | 延遲條件下重跑驗收 | TD-10 | M0 通過或失敗的判定 |

**延後至 M1 之後**：混合分屏、動態分屏合併、合體形態的三人共同輸入。TD-04 已為分屏留好位子，不需要在 M0 實作。

**進度與跑法**：見 [`trio-project/README.md`](../trio-project/README.md)。步驟 0 的骨架已建立。

---

[← 回到文件索引](../README.md)
