# trio-project（Godot 專案）

M0 技術驗證原型。全程膠囊體：**零美術、零動畫、零 shader**（TD-09）。

設計文件在 [`../docs/`](../docs/)，技術決定在 [`../docs/13-tech-decisions.md`](../docs/13-tech-decisions.md)。

## 目前進度

| M0 步驟 | 狀態 |
|---|---|
| 0. `NetworkService` + `PlayerSlot` + 三人連線基本移動 | ✅ 已寫，未在引擎驗證 |
| 1. 抓取與投擲同步 | ✅ 已寫，未在引擎驗證 |
| 2. **疊高同步**（最高風險） | ⬜ |
| 3. Ragdoll 與倒地救援 | ⬜ |
| 4. 在 80–150 ms 延遲下重跑驗收（TD-10） | ⬜ |

## 目錄

```
scenes/
  main.tscn              進入點：World + Players + PlayerSpawner + LobbyUI
  player/player.tscn     膠囊角色（含跟隨鏡頭、抓取偵測、攜帶錨點）
  world/test_arena.tscn  測試場地（含三個箱子與一顆石頭）
  world/crate.tscn       可搬物件
scripts/
  autoload/
    network_service.gd   TD-03：唯一碰 MultiplayerPeer 的地方
    player_registry.gd   TD-02/04：隊伍名冊，host 權威
    game_input.gd        TD-04：輸入以 device_id 分流
    carry_system.gd      TD-02：抓取、投擲、掙扎的權威判定
  core/
    player_slot.gd       TD-04：玩家身分（一個 peer 可以有多個）
    weight_ladder.gd     重量階梯，全遊戲唯一一張表
    carryable.gd         可被抓起的元件（玩家與場景物件共用）
  player/player_character.gd  TD-02：自己的角色自己算，其他人插值
  world/prop.gd          host 權威的場景物理物件
  main.gd                名冊 → 場上角色
  ui/lobby_ui.gd         開發用連線面板（不是 HUD）
```

## 怎麼跑

**編輯器內多開**：`Debug → Customize Run Instances`，設 3 個實例。

**命令列多開**（三個終端機）：

```bash
godot --path . -- --host
godot --path . -- --join=127.0.0.1
godot --path . -- --join=127.0.0.1
```

沒帶參數就用畫面左上角的面板手動開房／加入。

**即使一個人測也要先按「開房」**——抓取判定走 host RPC，沒有連線時沒有 host，
也不會生成任何角色。

### 操作

| 鍵鼠 | 手把 | 動作 |
|---|---|---|
| WASD | 左搖桿 | 移動（相對鏡頭）；被抓時變成掙扎 |
| 按住滑鼠右鍵拖曳 | 右搖桿 | 轉鏡頭 |
| 空白鍵 | A | 跳 |
| F | B | 抓取／放下 |
| 滑鼠左鍵 或 J（按住蓄力，放開擲出） | RT | 投擲 |

手把的投擲是 RT 而鍵鼠是攻擊鍵，這個不對稱來自 docs/06——手把按鍵已經排滿，
鍵鼠還有餘裕。鍵盤保留 J 是因為 M0 要在同一台機器上開三個視窗，用滑鼠會一直搶焦點。

膠囊前面那塊小方塊是朝向指示。

### 手感參數在哪

`player_character.gd` 最上面。刻意用「時間」而不是「加速度」表示——
`ACCEL_TIME = 0.10`（到全速）、`STOP_TIME = 0.07`（到停止）、`TURN_TIME = 0.07`（轉向）。
數字越小越接近「按下就走」。基準是 Overcooked：回饋速度優先，不要重量感（docs/05）。

覺得飄就調小，覺得太滑溜就調大。改完不用重開，Godot 會熱載入。

### 步驟 1 要驗的四件事

1. **重量規則**：豬（slot 0）抓得動蛙與貓，貓抓不動豬也抓不動石頭。同重量抓不動是刻意的
2. **被抓的人**：位置跟著抓的人走，狂推搖桿約兩秒可以掙脫
3. **投擲**：蓄力越久飛越遠；目標越重飛越近
4. **三台一致**：三邊看到的「誰拿著什麼」必須完全一致，不能有人手上是空的

## 延遲測試（TD-10，M0 驗收的必要條件）

區網測試一定會過，然後上市炸掉。驗收必須在延遲下重跑一次。

```bash
# Linux，注入到 loopback（雙向各 75ms → RTT 約 150ms）
sudo tc qdisc add dev lo root netem delay 75ms 15ms loss 1%
sudo tc qdisc del dev lo root      # 測完移除
```

Windows 用 [clumsy](https://jagt.github.io/clumsy/)，filter 設
`udp and (udp.DstPort == 27015 or udp.SrcPort == 27015)`，Lag 75ms、Drop 1%。

要調的三個數字都在 `player_character.gd` 最上面：`SYNC_HZ`、`REMOTE_LERP`、`TELEPORT_DISTANCE`。

## 檢查

```bash
python3 tools/check_project.py
```

純 Python 就能跑：

- `project.godot` 的 autoload 與 main_scene 路徑存在
- `.tscn` 的資源參照與 parent 路徑
- 腳本縮排
- **接線**：腳本裡的 `$NodePath` 在掛著它的場景中存在、autoload 成員存在、
  呼叫 `.rpc()` 的方法有 `@rpc` 標註、`.connect()` 的訊號與回呼存在、群組名有人加入

裝了下面兩個之後還會做 GDScript 語法、風格與場景結構檢查：

```bash
pip install "gdtoolkit==4.*" godot-parser
```

**最重要的一項是引擎編譯檢查**。設定 `GODOT` 環境變數指到執行檔就會自動啟用：

```
set GODOT=C:\path\to\Godot_v4.7.2-stable_win64.exe
python tools/check_project.py
```

gdparse 只驗語法，抓不到 `Color.WEBGRAY`（常數不存在）或
`var x := obj.unknown_method()`（型別推不出來）這一類——只有引擎抓得到。
這兩個錯誤在第一次開專案時真的出現過。

`$Visaul/CarryAnchor` 這種打錯的路徑在編輯器裡要執行到那一行才炸，
而且訊息是「null instance」，離真正的原因很遠——接線檢查就是為了這一類問題。

## 但這份骨架仍未在引擎裡跑過

撰寫環境無法取得 Godot 執行檔。上面的檢查能抓語法與路徑錯誤，抓不到執行期行為。
**第一次開專案時請照這個順序確認**：

1. 開啟專案，看輸出面板有沒有 script parse error
2. `專案設定 → Autoload` 應有 NetworkService / PlayerRegistry / GameInput 三項
3. 執行 `main.tscn`，膠囊應出現在測試場地上，左上有連線面板
4. 多開兩個實例加入，左上面板應顯示 3 個 slot，且三隻膠囊互相看得到彼此移動

第 4 步失敗最可能的原因是 `player_character.gd` 的 `_setup_synchronizer()`——
複製設定是用程式碼建的（見該函式的註解說明為什麼），Godot 版本若改過
`SceneReplicationConfig` 的 API，這裡會是第一個壞掉的地方。

## 已知的簡化

這些是刻意的，不是遺漏：

- **鏡頭是最簡單的環繞跟隨，沒有 SpringArm、沒有俯仰、不會避開障礙物。**
  `SpringArm3D` 的價值（避免鏡頭穿牆）在開闊測試場地用不到，卻引進投射方向的
  正負號慣例——第一次跑就因此把鏡頭放到角色前面。改成自己算位置。
  轉向用「按住右鍵拖曳」而不是鎖定滑鼠，因為 M0 要在同一台機器上開三個視窗。
  〈連線、營地與分屏〉列的那些鏡頭規則（疊高時誰優先、合體時共用還是各自）
  仍然未定案，那些要等有實際玩法才談得下去。
- **一個 peer 只分配一個 slot。** `PlayerSlot` 已經支援多個，但本地分屏是上市後的事。
- **沒有 AI 夥伴。** `PlayerSlot.is_ai` 欄位已就位，行為要等 M2。
- **連線面板不是 HUD。** 正式 HUD 見〈操作與 UI〉，M1 才做。
