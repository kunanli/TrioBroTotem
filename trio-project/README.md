# trio-project（Godot 專案）

M0 技術驗證原型。角色是 Meshy 生成的模型；關卡的幾何全部是 Godot 的原始形狀組出來的（沒有任何場景模型檔），但**視覺層次做過了**：配色、燈光、路、谷壁、營地。
動畫**由程式生成**（TD-12，`motion_forge.gd`），shader 只有一支：角色描邊（TD-09 的 inverted hull）。
**畫面上的字全部是英文**，除錯訊息維持中文。

設計文件在 [`../docs/`](../docs/)，技術決定在 [`../docs/13-tech-decisions.md`](../docs/13-tech-decisions.md)。

## 目前進度

| M0 步驟 | 狀態 |
|---|---|
| 0. `NetworkService` + `PlayerSlot` + 三人連線基本移動 | ✅ 已寫，未在引擎驗證 |
| 1. 抓取與投擲同步 | ✅ 已寫，未在引擎驗證 |
| 2. **疊高同步**（最高風險） | ✅ 已寫，未在引擎驗證 |
| 3. 倒地與救援 | ✅ 已寫，未在引擎驗證 |
| 3b. PhysicalBone3D ragdoll | ⬜ 下一步 |
| 4. 在 80–150 ms 延遲下重跑驗收（TD-10） | ⬜ |

## 目錄

```
scenes/
  main.tscn              進入點：World（換場時換的就是這一層）+ Players
                         + PlayerSpawner + TitleUI + LobbyUI
  player/player.tscn     膠囊角色（含跟隨鏡頭、抓取偵測、攜帶錨點）
  world/camp.tscn        營地：出生點、練習道具、營火、任務看板
  world/test_arena.tscn  第一章「藤蔓谷地」灰盒
  world/crate.tscn       可搬物件
  world/default_env.tres 共用的 Environment（AA／glow／SSAO／霧全在這一份）
  world/materials/*.tres  共用材質，由 tools/sync_materials.py 從 palette.gd 產生
  world/rock.tscn        可扛的石頭（以前是一個放大的木箱）
  world/tent.tscn        帳篷（**有碰撞**，以前那兩個是穿得過去的方塊）
  world/totem.tscn       圖騰：三隻不同族疊在一起（docs/02 的核心意象）
  tools/level_probe.tscn 截圖探針，不進 exe（export_presets 的 exclude_filter）
scripts/
  autoload/
    network_service.gd   TD-03：唯一碰 MultiplayerPeer 的地方
    player_registry.gd   TD-02/04：隊伍名冊，host 權威
    game_input.gd        TD-04：輸入以 device_id 分流
    carry_system.gd      TD-02：抓取、投擲、掙扎的權威判定
  core/
    outline.gd           TD-09：描邊材質的唯一來源（角色與敵人共用同一份）
    palette.gd           全遊戲配色的唯一來源（封閉在 25 色）
    player_slot.gd       TD-04：玩家身分（一個 peer 可以有多個）
    weight_ladder.gd     重量階梯，全遊戲唯一一張表
    carryable.gd         可被抓起的元件（玩家與場景物件共用）
  player/player_character.gd  TD-02：自己的角色自己算，其他人插值
  world/prop.gd          host 權威的場景物理物件
    game_flow.gd         開始畫面 → 營地 → 任務關卡，host 權威
  world/mission_board.gd 走過去按互動就出發
  main.gd                名冊 → 場上角色；換場時抽換 World 子樹
  ui/title_ui.gd         開始畫面（連線控制全在這裡）
  ui/lobby_ui.gd         遊戲中的面板（不是 HUD）
  world/scenery_plan.gd  關卡裝飾的資料表（路徑折線、谷壁參數、營地擺設）
  world/scenery.gd       依上表把裝飾長出來（路、邊石、谷壁、柵欄、火塘、雜物）
  world/campfire.gd      營火的閃爍與火焰／煙
  shaders/outline.gdshader  全專案唯一一支 shader
```

## 怎麼跑

**編輯器內多開**（最方便）：`Debug` → `Customize Run Instances...` →
勾選 `Enable Multiple Instances` → 數量設 2 或 3 → 關掉對話框 → 按 ▶。

會跳出對應數量的遊戲視窗。**第一個按「開房」，其餘按「加入」**
（位址欄預設就是 `127.0.0.1`）。

想省掉點按鈕，同一個對話框裡每個實例可以設 `Launch Arguments`：
第一個填 `--host`，其餘填 `--join=127.0.0.1`。

> 多視窗測試時，點進畫面會鎖住滑鼠（為了轉鏡頭）。**按 `Esc` 放開**
> 才能點到另一個視窗。

**命令列多開**（三個終端機）：

```bash
godot --path . -- --host
godot --path . -- --join=127.0.0.1
godot --path . -- --join=127.0.0.1
```

沒帶參數就用畫面左上角的面板手動開房／加入。

**即使一個人測也要先按「開房」**——抓取判定走 host RPC，沒有連線時沒有 host，
也不會生成任何角色。

**一個人也能測三人玩法**：開房之後空位會自動補上 AI 夥伴，隊伍永遠是三個人。
疊高、抓取、扶起這些需要隊友的機制，一個人開一個視窗就驗得動。
第二個人加入時是**接手**某個 AI（只換 peer 與 is_ai 兩個欄位，角色的位置、
血量、手上拿的東西全部不變），不是新增位置；有人離線則交還給 AI。

### 操作

| 鍵鼠 | 手把 | 動作 |
|---|---|---|
| WASD | 左搖桿 | 移動（相對鏡頭）；被抓時變成掙扎 |
| 滑鼠（點畫面鎖定，`Esc` 放開）或按住右鍵拖曳 | 右搖桿 | 轉鏡頭（可上下） |
| 滑鼠左鍵 或 J（手上沒東西時） | X | 攻擊——連按接三段連擊 |
| E（按住 2.5 秒） | LT | 扶起倒地的隊友 |
| K | — | 測試用：把自己打倒 |
| 空白鍵 | A | 跳 |
| F | B | 抓取／放下 |
| 滑鼠左鍵 或 J（按住蓄力，放開擲出） | RT | 投擲 |

手把的投擲是 RT 而鍵鼠是攻擊鍵，這個不對稱來自 docs/06——手把按鍵已經排滿，
鍵鼠還有餘裕。鍵盤保留 J 是因為 M0 要在同一台機器上開三個視窗，用滑鼠會一直搶焦點。

膠囊前面那塊小方塊是朝向指示。

### 遊戲流程

開始畫面 → 營地 → 任務關卡（docs/08 的流程圖）。

1. **開始畫面**：填名字，一個人按「開一個房間」，其他人填他的位址按「加入」。
   網路模擬的檔位也在這裡選——連上線之後才改是不會生效的。
2. **營地**：連上就會一起出現在這裡。可以自由練抓、丟、疊、推，
   場地上有箱子、石頭與一根原木。
3. **出任務**：走到北邊的任務看板前面，按 E（手把 LT）出發。任何人都可以按。
4. **回營地**：通關之後幾秒自動回營地，可以再出發一次。

換場只換 `World` 底下的子樹，不是 `change_scene_to_file`——整個場景換掉會連
`Players` 與 `MultiplayerSpawner` 一起銷毀，而戰鬥系統傳的是節點路徑字串。

中途加入的人會被拉到當下的階段（host 在對方連上時補送一次），
所以任務打到一半有人連進來，他會直接出現在關卡裡而不是卡在營地。

### 手感參數在哪

全部在 `player_character.gd` 最上面，改完不用重開，Godot 會熱載入。

**移動**：刻意用「時間」而不是「加速度」表示——`ACCEL_TIME = 0.10`（到全速）、
`STOP_TIME = 0.07`（到停止）、`TURN_TIME = 0.07`（轉向）。數字越小越接近「按下就走」。
基準是 Overcooked：回饋速度優先，不要重量感（docs/05）。覺得飄就調小，太滑溜就調大。

**跳躍**：`JUMP_VELOCITY = 5.4`、`FALL_MULTIPLIER = 1.7`（下墜比上升快，跳起來才不飄）、
`AIR_CONTROL = 0.25`。另外兩個是「按不準也跳得起來」的容錯：
`COYOTE_TIME = 0.12`（走出平台之後還有多久可以跳）、`JUMP_BUFFER = 0.12`（落地前提早
按會被記住多久）。物理跑 120 Hz，沒有這兩個的話早按或晚按**一格（8 毫秒）**就整個丟掉。

**腳步與傾斜**：`STRIDE_RATIO = 0.62`（步幅＝身高的幾成，所以矮的角色步伐比較密）、
`STEP_VOLUME_DB = -15`、`LEAN_MAX = 0.16`（加速與轉彎時身體傾多少）。

**鏡頭**：搬到 `scripts/player/player_camera.gd` 了。`DISTANCE_RATIO = 3.1`
（距離＝身高的幾倍）、`FIELD_OF_VIEW = 62`、`FOLLOW_TIME = 0.09`（水平追隨）、
`VERTICAL_TIME = 0.28`（垂直追隨）、`MOUSE_SENSITIVITY`、`STICK_LOOK_SPEED`。

> 搖桿死區改成會重新歸一化了（原本推過 0.2 就直接輸出 0.2，等於沒有慢速），
> 所以**右搖桿在中間附近會比以前慢**——那是刻意的（微調瞄準用），
> 但如果整體覺得太鈍，調大 `STICK_LOOK_SPEED`。

**打擊回饋**：在 `scripts/core/combat_spec.gd`，不在這個檔案——那些數字直接對應
`docs/05-combat.md` 的規格表，放在一起才一眼看得到全部。

覺得打起來沒感覺，**先只動 `SHAKE_ANGLE` 一個旋鈕**（每一段攻擊的 `shake` 值
換算成幾弧度的鏡頭偏轉，預設 0.10）。其餘：`SHAKE_TIME` 是震動長度、
`SHAKE_FREQUENCY` 是震幾下（**不要調超過 15**，60 fps 的畫面每秒只畫 60 次，
再高就會混疊成雜訊而且每台機器不一樣）、`PUNCH_ATTACK` / `PUNCH_VICTIM` 是
命中縮放、`RUMBLE` 是手把震動的強度與時長。

**角色看起來太小**有兩個調法，效果不同：把 `DISTANCE_RATIO` 調小是拉近鏡頭，
會犧牲看到隊友與環境的範圍；把 `FIELD_OF_VIEW` 調小是縮視角，角色變大但廣度損失較少。
兩者都不想動的話，就改 `assets/source/characters.json` 的身高讓角色相對場景真的變大——
那需要重跑 `normalize-all`。

垂直刻意比水平慢三倍——兩者相同的話，跳躍與走斜坡時鏡頭會跟著上下彈，
那是第三人稱最明顯的暈眩來源。覺得跳躍時鏡頭反應太慢就把
`VERTICAL_TIME` 調小，覺得晃就調大。

物理跑 **120 Hz**（`project.godot`）。角色的移動是在物理幀更新的，
60 Hz 在高刷新率螢幕上看得出一格一格跳——鏡頭做了平滑之後反而更明顯。

### 我看得到畫面了：tools/shoot_level.py

```bash
GODOT=/path/to/godot python3 tools/shoot_level.py          # 兩關都拍
GODOT=/path/to/godot python3 tools/shoot_level.py camp     # 只拍營地
```

這台開發機沒有顯示卡，但 **Xvfb ＋ Mesa 的 lavapipe（軟體 Vulkan）讓 Godot 的
Forward+ 跑得起來**，跟遊戲實際用的渲染器一模一樣，連 SSAO 都畫得出來。
Linux 上要 `apt install xvfb mesa-vulkan-drivers`。

鏡頭用的是**玩家真正的參數**（從 `player_camera.gd` 推出來：距離 3.1 倍身高、
俯角 0.42、FOV 62），不是隨便挑一個好看的角度——宣傳照會騙人。出生點會放三根
人形膠囊當比例尺：**畫面裡沒有人的尺度，就沒辦法判斷一顆石頭是大是小**，
然後每樣東西都會被做得太大。

> **踩過的坑**：一開始走的是 Compatibility（OpenGL）渲染器，那條路**平行光完全
> 不會亮**——整個世界只剩環境光與霧，而且沒有任何警告。差點照著那個畫面把太陽
> 調成另一個角度，實際上根本沒有太陽。畫面整個變平、方塊沒有亮暗面，
> 那是渲染器的問題，不是你的燈。

### 配色在哪調

`scripts/core/palette.gd`，25 色封閉表，**要加一個就要刪一個**。兩條規則寫在
檔案開頭，改顏色之前先讀那兩段。

`.tscn` 沒辦法呼叫程式，所以場景裡指的是 `scenes/world/materials/*.tres`——
那些是 `tools/sync_materials.py` 從配色表**產生**的，不要手改。改完配色跑一次：

```bash
python3 tools/sync_materials.py     # 重新產生
python3 tools/check_project.py      # 會比對兩邊，不一致就失敗
```

| 想改什麼 | 調哪個 |
|---|---|
| 路不夠明顯 | `path` 與 `turf` 的明度差（現在 0.156，規則是至少 0.15） |
| 敵人不夠顯眼 | `corrupt`（紫）與 `corrupt_glow`（常駐自發光） |
| 「這個爬得上去」看不出來 | `stone`——樹樁台、終點台、練習台階都用它 |
| 谷壁太暗／太亮 | `cliff_face`。**垂直面天生就比水平面暗**，所以這個數字看起來會高得不合理，那是對的（檔案裡有一整段在講） |

### 路與裝飾在哪調

資料在 `scripts/world/scenery_plan.gd`（**只有資料**），產生器在 `scenery.gd`。
改資料、跑 `shoot_level.py`、看結果——這是這一輪的迭代迴圈。

| 想改什麼 | 調哪個 |
|---|---|
| 路的走法、寬窄、岔路 | `PATHS`。每一段是 `{"p": 位置, "w": 半寬}`，中間會平滑成曲線 |
| 路邊的石頭 | `scenery.gd` 的 `KERB_*`。**真正讓人認出「路」的是兩排石頭**，不是那條變色的帶子 |
| 谷壁的高低、往內傾多少 | `CLIFFS` 的 `height` 與 `lean_deg`。**往內傾是「這是谷」最強的暗示**，垂直的牆讀作走廊 |
| 斷崖的深度與霧氣 | `RAVINE` |
| 營地的柵欄、大門、火塘、雜物 | `PALISADE` / `FIRE_RING` / `CLUTTER` |

**三條不能破的規則**（都寫成程式裡的檢查或註解了）：

1. **有碰撞、或有程式用名字／路徑／群組指到它 → 寫在 `.tscn`；其餘才用程式生。**
2. **走廊中央（|x| < 6）從 0.35 公尺到岩拱下緣之間不准有任何裝飾。** 裝飾沒有碰撞，
   玩家會直接穿過去。這一條是 `scenery.gd::_check_clearance()`，違規會累積在
   `clearance_violations` 裡。
3. **亂數一律用帶固定種子的 `RandomNumberGenerator` 實例，不准用全域 `randf()`。**
   全域那個用時間當種子，三台機器會長出三片不一樣的谷壁，而 docs/PLAYTEST.md
   明確要測試者互相看對方的螢幕。

**同一種東西超過 8 份就用 `MultiMeshInstance3D`**，而且**一定要明寫
`custom_aabb`**——實例散佈在 56 公尺、節點卻在原點，引擎算出來的邊界是錯的，
整片谷壁會隨著轉鏡頭忽隱忽現，看起來會像驅動程式的 bug。

> **寫測試的人注意**：Godot 4.7 的 `MultiMesh.get_instance_transform()`
> **讀回來一律是單位矩陣**（寫進去是對的、畫出來也是對的，只有讀回來不對）。
> 拿它驗位置會得到「每一批都違規」這種假警報。要驗就在資料還在手上的時候驗。

### 關卡機關在哪調

| 機關 | 腳本 | 旋鈕 |
|---|---|---|
| 重量壓力板 | `scripts/world/weight_plate.gd` | 場景檔上的 `needed_weight`（要多重才開）、`latch`（開了要不要關回去）、`gate_path`（連著哪一道門）、`objective`（目標列那一句）；腳本裡的 `GATE_DROP`／`GATE_SPEED`（門沉多深、多快）與 `GLOW_IDLE`／`GLOW_FULL`（板子的自發光範圍） |
| 門 | `scenes/world/gate.tscn`（**沒有腳本**，由板子推） | 高 8 公尺是尺寸表上的數字，不能自己改；板子五片是 `MeshInstance3D`，`cast_shadow = 0` |

**第一章的兩塊板子**：前廳中央的墊子上要 50（石頭 35 ＋ 木箱 25、或兩個木箱、
或豬自己站上去），遠岸 2.4 公尺台上的要 25（木箱一個，或蛙／豬自己站上去）。
**每一塊都刻意留了兩條以上互相獨立的解**——道具有可能掉進斷崖，而斷崖只救玩家
不救道具，所以任何謎題都不得依賴一個會永久遺失的道具。

`latch` 在第一章一定要是 `true`：不閂住的話，撐著門的人一倒地隊伍就被一道牆
分開，而這一章沒有檢查點。它存在是為了第二章的控制點以後可以用 `false`。

改完跑 `godot --headless --path trio-project res://scenes/tools/plate_probe.tscn`，
它會開一個 host、把真的木箱放上去、讓真的玩家站上去再倒地，驗五條規則。
`check_project.py` 每次都會跑它。

### 畫面與描邊在哪調

這一區的東西**在這台機器上看不到**（headless 的 llvmpipe 不畫蒙皮網格），
所以下面每一個數字都只驗過「有生效」，沒有驗過「好不好看」。覺得不對就直接調。

**整體畫面**：`scenes/world/default_env.tres` 一份共用的 Environment，
`camp.tscn` 與 `test_arena.tscn` 都指過去，各自只覆蓋要不一樣的
（營地暖色黃昏、第一章冷色谷地）。**要調畫面就調這一份**，不要在場景裡各改各的——
分成兩份的下場是調一個數字要改兩個地方，然後忘記其中一個。

| 想改什麼 | 調哪個 |
|---|---|
| 營火與終點標記不夠亮／太亮 | `glow_intensity`（0.55）、`glow_hdr_threshold`（1.1，越低越多東西發光） |
| 方塊跟地面糊在一起／接縫太髒 | `ssao_intensity`（2.4）、`ssao_radius`（1.4） |
| 遠處太清楚／太糊 | `fog_depth_begin`（18 公尺）、`fog_depth_end`（90） |
| 鋸齒 | `project.godot` 的 `msaa_3d`（2 ＝ 4×；0 是關掉、3 是 8×） |
| 天空有色帶 | `use_debanding`（已開） |

**描邊**：`scripts/core/outline.gd`，三個常數，**平常只要動 `WIDTH`**（0.006）。
外推量會乘上到鏡頭的距離，所以描邊在畫面上遠近一樣粗，半畫面分屏時也還在。
`MIN_WIDTH`（0.012）是給耳朵、手指那種薄的部位墊底，破洞才調它；
`COLOR` 不是純黑（純黑在暗處會跟陰影糊掉）。

轉角破洞是 inverted hull 的已知代價（硬邊的法線不連續，外推會裂開）。
真的很明顯的話，正解是在美術管線那邊把法線平滑掉，不是把 `WIDTH` 一直加大。

**誰有描邊**：會動的東西（角色、敵人）。場景方塊沒有——全部都描會變成線稿，
而 `docs/09` 要的是「色塊乾淨」。

### 生成的動畫在哪調

跳躍、落地、受擊、倒下這四支**沒有美術資產**，是程式用骨骼旋轉建出來的（TD-12）。

- **姿勢**：`scripts/player/motion_clips.gd`。`JUMP` / `LAND` / `HURT` / `DEATH`
  是關鍵影格陣列，每一格寫「在哪個相位（`phase`）的幾成（`at`）、哪根骨頭轉幾度」。
  角度是**角色空間的尤拉角**，不是骨骼的區域座標——三隻角色的骨架朝向不一樣，
  寫區域座標的話同一份資料在不同角色身上會歪掉。
- **長度**：`scripts/player/motion_forge.gd` 的 `NON_COMBAT`，每一支自己寫
  `windup` / `active` / `recovery`。跳躍的 `windup` 只有 0.05 秒——調長會覺得
  「按下去沒反應」。
- **扛東西與滯空**是**疊加姿勢**不是片段（`CARRY_POSE` / `AIRBORNE_POSE`，
  由 `procedural_pose.gd` 的第五、六層加上去），因為它們必須跟走路共存：
  上半身抱著、腿照常走。做成片段的話扛著東西就不能走路了。

**骨頭名字打錯是靜默失敗**——那條軌道不會建出來，也不會有任何錯誤訊息，
只是那根骨頭不動。`tools/check_project.py` 抓不到這個，改完姿勢資料請在遊戲裡看一眼。

### 角色模型與動畫

slot 0/1/2 分別是豬戰士、青蛙法師、貓咪弓箭手，模型從
`trio-project/assets/characters/<角色>.glb` 載入。碰撞體高度、鏡頭注視高度、
攜帶錨點都依 `character_roster.gd` 的身高換算——三隻差 1.4 到 1.7 公尺，
用固定值會有人被埋進地裡。

動畫用 `AnimationPlayer` 直接切換加交叉淡入，不是 `AnimationTree`。
現階段的需求（待機／移動／單次動作）用這樣就夠，而且看得懂改得動；
要 BlendSpace 混合方向與速度時再升級。

動畫名稱由美術管線正規化成 `idle` / `walk` / `run` / `attack` / `death` 等
（見 `tools/blender_normalize.py` 的 `ANIMATION_NAMES`），所以遊戲端可以直接
用名稱找。**Meshy 一個匯出檔只帶一支動畫**，多支就放同一個角色資料夾，
`normalize-all` 會把第一個當底模、其餘只取動作併進來。

模型載入失敗時會保留膠囊並在 Output 印警告，不會整個看不到東西。

### AI 夥伴

**成本原則：只做被動配合，不做主動解謎**（docs/08）。優先序由上而下：

1. 扶起倒地的隊友——全隊倒地就是本章失敗，這是最高優先
2. 打附近的敵人
3. 跟著最近的真人（帶遲滯，不會在跟隨距離上前後抖動）

刻意**沒有**的：主動判斷謎題、主動發起抓取、自己決定去哪個控制點、
自己決定何時疊高。這四項 docs/08 明列為「不需要會」，而且每一項都會
讓成本失控。AI 要能**被踩**（疊高時當底座），但不會自己跳到隊友頭上。

沒有尋路。撞到東西時靠跳躍脫困——這是「只做被動配合」的代價，
也是為什麼 docs/08 規定每個謎題都要標註「AI 是否需要主動執行」，
若是則該謎題必須改設計。

### 戰鬥（M1 的核心）

`docs/05` 的打擊感規格全部寫成資料，放在 `scripts/core/combat_spec.gd`——
那些數字**一定會反覆調**，而 M1 的驗收標準是「找三個朋友玩 20 分鐘，
他們自己笑出來」，只能靠改數字逼近，所以改的人必須一眼看到全部。

**三段連擊**（docs/06）：連按攻擊鍵接下去，第三下大擊退把敵人打飛。
**情境攻擊**：跑動中變衝刺撞擊、跳躍中變空中下劈，不佔按鍵。

測試場地放了四隻**泥偶**（docs/05 小怪三層的最底層）：一擊即散、
擊退倍率 ×2.0 是全遊戲最高——擊退距離直接反映敵人強度，
玩家不用看血條就能讀出威脅等級。

要驗的：

1. **連擊接得順**：三下打完的節奏，以及第三下明顯比前兩下重
2. **打飛**：泥偶被第三下打出去要飛得夠遠、夠好笑
3. **頓幀與鏡頭震**：命中當下有停頓感但不拖。覺得黏就把 `hitstop` 調小，
   覺得沒力就調大。基準是 Overcooked——**回饋速度優先，不是重量感**
4. **誤傷**：打隊友會把人推開但預設不扣血。擊退**永不可關**（docs/04），
   因為法師的水球永遠要能把隊友推上高台，否則關掉開關就會卡關

頓幀只停動畫，不動 `Engine.time_scale`——那會連物理與網路一起停掉，
三台機器立刻對不上。

### 步驟 3（倒地與救援）要驗的四件事

M0 還沒有敵人，所以傷害來源只有兩個：**從高處摔下來**，以及測試鍵 **K**。

1. **倒地**：按 K 或從高台摔下來，角色趴下、名牌顯示「倒地」、不能移動也不能自救
2. **扶起**：隊友走近按住 **E** 兩秒半，名牌會顯示進度百分比。
   起來後帶一小段血——「扶起即回血」是治療三層的第一層（docs/04），
   本作沒有專屬補師就是因為救援系統本身就是治療系統
3. **扛走**：倒地的人可以被抓起來扛走（重量規則照舊，貓扛不動豬）
4. **全隊倒地**：三個人都倒 → 三秒後全部重生。正式版是退回營地（docs/04），
   章節內因此完全不需要檢查點系統

倒地的人若正踩在別人頭上會自動脫離；當底座的人倒下則整柱潰散。

### 步驟 2（疊高）要驗的五件事

**疊高不佔按鍵**——跳到隊友頭上就會自動吸附（docs/06）。

1. **重量規則**：貓可以站上蛙或豬，蛙可以站上豬，**豬站不上任何人**。
   反過來試也要失敗——那是 host 權威的驗證在擋
2. **疊三層**：豬在底、蛙在中、貓在頂。底座走動時整柱跟著走，不散開
3. **上層按跳鍵**自己下來，只有他脫離，下面的柱子不受影響
4. **底座按跳鍵**整柱潰散，上面的人往外彈開（docs/04）
5. **關鍵**：三邊畫面看到的柱子必須完全一致。這是 M0 的最高風險項，
   `docs/10` 的驗收標準是「三台機器連線，疊成三層走動 30 秒不崩、不抖、不穿模」，
   而且要在 80–150 ms 延遲下重跑一次才算過（TD-10）

上層仍保有鏡頭自由，但移動輸入不推動角色——上層是乘客，不是共同施力者。

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
