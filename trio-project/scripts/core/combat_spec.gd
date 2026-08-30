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

## 鏡頭震的衰減時間。要快——慢衰減會拖節奏，與 Overcooked 基準打架。
const SHAKE_DECAY := 0.18


static func step(index: int) -> Dictionary:
	return COMBO[clampi(index, 0, COMBO.size() - 1)]


static func knockback_multiplier(kind: StringName) -> float:
	return KNOCKBACK_BY_KIND.get(kind, FRIENDLY_KNOCKBACK)
