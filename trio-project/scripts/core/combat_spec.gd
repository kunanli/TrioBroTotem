class_name CombatSpec
extends RefCounted

## 打擊感規格，直接對應 docs/05-combat.md 與 docs/06-controls-ui.md 的表格。
##
## 全部寫成資料而不是散在程式碼裡，是因為這些數字**一定會反覆調**——
## M1 的驗收標準是「找三個朋友玩 20 分鐘，他們自己笑出來」，
## 那個標準只能靠改數字逼近，改的人必須一眼看到全部。
##
## 基準是 Overcooked：**回饋速度優先，不是重量感**（docs/05）。
## 這與 Gang Beasts 的方向相反——不要長頓幀、慢動作、低頻鏡頭搖晃。

## 文件用「幀」描述頓幀，以 60 fps 為基準換算成秒。
const FRAME := 1.0 / 60.0

## 三段連擊（docs/06）。單一攻擊鍵，不設輕重擊分鍵。
##
## windup 出手前搖、active 判定窗口、recovery 後搖，單位秒。
## combo_window 是後搖開始後多久內按下一段還能接上——太短會覺得斷，
## 太長會變成隨便亂按都能連。
const COMBO: Array[Dictionary] = [
	{
		"name": "light_1",
		"windup": 0.08, "active": 0.08, "recovery": 0.16, "combo_window": 0.34,
		"damage": 12.0, "knockback": 4.0, "hitstop": 3.0 * FRAME, "shake": 0.12,
	},
	{
		"name": "light_2",
		"windup": 0.07, "active": 0.08, "recovery": 0.18, "combo_window": 0.34,
		"damage": 12.0, "knockback": 4.5, "hitstop": 3.0 * FRAME, "shake": 0.12,
	},
	{
		# 第三下把人打飛出去——這正好餵養本作的物理喜劇（docs/06）。
		"name": "heavy_3",
		"windup": 0.13, "active": 0.10, "recovery": 0.32, "combo_window": 0.0,
		"damage": 20.0, "knockback": 11.0, "hitstop": 7.0 * FRAME, "shake": 0.30,
	},
]

## 情境攻擊（docs/06）：不佔按鍵，變化來自「你正在做什麼」。
const DASH_ATTACK := {
	"name": "dash",
	"windup": 0.06, "active": 0.14, "recovery": 0.26, "combo_window": 0.0,
	"damage": 16.0, "knockback": 8.0, "hitstop": 6.0 * FRAME, "shake": 0.22,
}
const AIR_ATTACK := {
	"name": "air",
	"windup": 0.10, "active": 0.16, "recovery": 0.24, "combo_window": 0.0,
	"damage": 18.0, "knockback": 9.0, "hitstop": 6.0 * FRAME, "shake": 0.24,
}

## 跑動中攻擊的速度門檻（超過就變成衝刺撞擊）。
const DASH_SPEED_THRESHOLD := 3.5

## 擊退倍率依目標種類（docs/05）。擊退距離直接反映敵人強度，
## 玩家不用看血條就能讀出威脅等級。
const KNOCKBACK_BY_KIND := {
	&"mud_puppet": 2.0,
	&"bound_animal": 1.2,
	&"enemy_soldier": 0.6,
	&"boss": 0.0,
	&"boss_broken": 0.8,
}

## 打到隊友時的擊退倍率。誤傷的擊退**永不可關**（docs/04），
## 因為法師的水球永遠要能把隊友推上高台，否則關掉開關就會卡關。
const FRIENDLY_KNOCKBACK := 1.0

## 命中白閃的持續時間（docs/05：0.05s）。
const FLASH_TIME := 0.05

# --- 鏡頭震 -----------------------------------------------------------------
#
# 上面每一段攻擊的 shake 是**強度**，下面這幾個是所有攻擊共用的**形狀**。
#
# 舊版有三個獨立的毛病疊在一起，任何一個沒解掉都還是看不見：
#   1. 用 move_toward(shake, 0, delta / SHAKE_DECAY) 衰減——那是「每秒減 5.56」的
#      速率，不是「0.18 秒衰減完」的時長。輕擊的 0.12 只震 21 毫秒（1.3 幀）。
#   2. 震動加在鏡頭「位置」上，下一行 look_at 又把鏡頭轉回去對準沒被震的錨點，
#      角色因此永遠釘在畫面正中央不動——衝擊感要的正是整張畫面一起跳。
#   3. jitter 是世界座標的 (x, y, 0)，鏡頭轉到看向 ±X 時，x 分量變成推拉鏡頭，
#      對畫面完全沒貢獻。同一下攻擊，鏡頭朝不同方向震動強度不一樣。

## 震動時長。與強度**解耦**——強弱只差在幅度，不差在長度。
const SHAKE_TIME := 0.18

## 震動頻率（Hz）。0.18 秒內震盪約 2.5 次。
##
## 上限被 60 fps 綁死：**畫面每秒只畫 60 次，震動超過 15 Hz 就會混疊**——
## 一開始設 26 Hz，實測 60 fps 取樣到的幅度只有 144 fps 的 64%，
## 而且兩者的軌跡完全不同。那不是「震動」，那是雜訊，而且每台機器不一樣。
## 14 Hz 在 60 fps 下一個週期有 4.3 個取樣點，畫得出形狀。
##
## 下限則是 docs/05 明文禁止的「低頻鏡頭搖晃」（那是 3–6 Hz 的沉重晃動）。
## 14 Hz 加上 0.18 秒的包絡，快且乾脆，兩邊都不違反。
const SHAKE_FREQUENCY := 14.0

## 每一段攻擊的 shake 值換算成幾弧度的鏡頭偏轉。這是**調震動大小唯一要動的旋鈕**。
## 0.10 時重擊（0.30）峰值 1.72°、輕擊（0.12）0.69°。
const SHAKE_ANGLE := 0.10

## 側傾（roll）佔水平擺動的比例。少量就好，太多會暈。
const SHAKE_ROLL := 0.35

## 沿命中方向的一次性偏轉，讓震動有方向而不只是亂抖。
const KICK_TIME := 0.10
const KICK_ANGLE := 0.16

## 被打中時自己的鏡頭震強度。
const HURT_SHAKE := 0.26

## 落地的最大鏡頭震（依落下速度內插到這個值）。
const LAND_SHAKE_MAX := 0.16

# --- 命中縮放（docs/05 的「輕微縮放」）----------------------------------------

const PUNCH_TIME := 0.14

## 正數＝拉長，負數＝壓扁。打中人時攻擊者前頂，被打的一方壓扁。
const PUNCH_ATTACK := 0.09
const PUNCH_VICTIM := -0.14
const PUNCH_LAND_MIN := -0.06
const PUNCH_LAND_MAX := -0.20

# --- 手把震動（docs/05 的表）-------------------------------------------------

const RUMBLE := {
	&"hit": {"weak": 0.35, "strong": 0.12, "seconds": 0.08},
	&"hurt": {"weak": 0.50, "strong": 0.45, "seconds": 0.18},
	&"ragdoll": {"weak": 0.0, "strong": 0.22, "seconds": 0.30},
	&"land": {"weak": 0.25, "strong": 0.20, "seconds": 0.10},
}


static func step(index: int) -> Dictionary:
	return COMBO[clampi(index, 0, COMBO.size() - 1)]


static func knockback_multiplier(kind: StringName) -> float:
	return KNOCKBACK_BY_KIND.get(kind, FRIENDLY_KNOCKBACK)


## 震動包絡，回傳 0..1。
##
## 寫成 static 的理由是驗證：headless 探針不必建場景、不必開連線就能逐點取樣，
## 直接比對「0.17 秒還有值、0.19 秒歸零」。壞掉的舊版沒有這種可驗的形狀。
static func shake_envelope(elapsed: float) -> float:
	if elapsed >= SHAKE_TIME or elapsed < 0.0:
		return 0.0
	return 1.0 - elapsed / SHAKE_TIME
