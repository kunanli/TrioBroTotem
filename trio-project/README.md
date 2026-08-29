# trio-project（Godot 專案）

M0 技術驗證原型。全程膠囊體：**零美術、零動畫、零 shader**（TD-09）。

設計文件在 [`../docs/`](../docs/)，技術決定在 [`../docs/13-tech-decisions.md`](../docs/13-tech-decisions.md)。

## 目前進度

| M0 步驟 | 狀態 |
|---|---|
| 0. `NetworkService` + `PlayerSlot` + 三人連線基本移動 | ✅ 骨架完成 |
| 1. 抓取與投擲同步 | ⬜ |
| 2. **疊高同步**（最高風險） | ⬜ |
| 3. Ragdoll 與倒地救援 | ⬜ |
| 4. 在 80–150 ms 延遲下重跑驗收（TD-10） | ⬜ |

## 目錄

```
scenes/
  main.tscn              進入點：World + Players + PlayerSpawner + LobbyUI
  player/player.tscn     膠囊角色（含跟隨鏡頭）
  world/test_arena.tscn  測試場地
scripts/
  autoload/
    network_service.gd   TD-03：唯一碰 MultiplayerPeer 的地方
    player_registry.gd   TD-02/04：隊伍名冊，host 權威
    game_input.gd        TD-04：輸入以 device_id 分流
  core/player_slot.gd    TD-04：玩家身分（一個 peer 可以有多個）
  player/player_character.gd  TD-02：自己的角色自己算，其他人插值
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

操作：`WASD` 移動、`空白鍵` 跳。膠囊前面那塊小方塊是朝向指示。

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

純 Python 就能跑：檢查 autoload 與 main_scene 的路徑、`.tscn` 的資源參照與 parent 路徑、
腳本縮排。裝了 `gdtoolkit` 與 `godot-parser` 之後還會做 GDScript 語法、風格與場景結構檢查：

```bash
pip install "gdtoolkit==4.*" godot-parser
```

目前狀態：**GDScript 7/7 語法通過、gdlint 無問題、3 個場景全部解析成功。**

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

- **鏡頭方向固定，沒有滑鼠視角。** 鏡頭規則尚未定案（見〈連線、營地與分屏〉鏡頭規則），
  定案前不做鏡頭相對移動，免得改兩次。
- **一個 peer 只分配一個 slot。** `PlayerSlot` 已經支援多個，但本地分屏是上市後的事。
- **沒有 AI 夥伴。** `PlayerSlot.is_ai` 欄位已就位，行為要等 M2。
- **連線面板不是 HUD。** 正式 HUD 見〈操作與 UI〉，M1 才做。
