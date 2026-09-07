class_name CharacterRoster
extends RefCounted

## 角色名冊：每隻的模型、重量、身高、朝向修正、程序化姿態。
##
## 重量沿用 WeightLadder，不在這裡另立一份——重量即規則（docs/01），
## 全遊戲只能有一張表。身高與 assets/source/characters.json 對齊，
## 那是美術管線正規化時實際套用的數字。
##
## yaw_offset 是模型朝向的修正角度。Meshy 出來的角色面向 +Z，而 Godot 的
## 前方是 −Z，所以要轉 180 度，否則角色會倒著走。逐隻設定是因為換了
## 生成工具或手動改過的模型可能不一樣。
##
## idle_hold 是「沒有 idle 動畫時，走路動畫要停在哪一幀」（0 到 1 的比例）。
## 0.55 是實測掃過整個循環挑出來的：三隻在這一幀雙腳最靠攏（前後距離 0.00–0.02
## 個身高，對比第 0 幀的 0.04–0.06、跨步中的 0.31）。
##
## **現在已經有 idle 了**（MotionForge 生成，見 motion_clips.gd 的 IDLE），
## 所以這個欄位平常用不到——它是備援：生成失敗時 `_stand()` 還是有東西可以擺，
## 不會退回雙手平舉的 T 字站在那裡。留著的成本是一行，拿掉的代價是
## 「生成一壞掉，畫面上就是三尊 T 字雕像」。
##
## walk_speed 是**量出來的**：這支走路片段原本對應多快的移動速度（公尺／秒）。
##
## 量法與重新量的方式：
##
##     godot --headless --path trio-project res://scenes/tools/gait_probe.tscn
##
## 站立期的腳不該滑，所以「腳相對身體往後退多快」就等於「身體該以多快前進」。
## 探針逐格取兩隻腳之中往後退得最快的那一個，再取整個循環的中位數——
## 那個分佈是一段很乾淨的平台（p25 0.81、p50 0.87、p75 0.92），不是雜訊。
##
## **這一欄取代了三個各自為政的猜測**：`CharacterVisual` 的 1.6、
## `PlayerCharacter` 用身高 × 0.62 反推的步幅、以及播放倍率的上限。
## 舊的 1.6 幾乎是實際值的兩倍，所以動畫一直播得太慢，腳一直在滑。
## 三隻差不多是應該的——同一份來源動畫重定向到三副骨架，差的只有比例。
##
## weapons 是這隻手上拿的東西（scripts/player/weapon_rack.gd）。
##   kind  劍／弓／法杖，零件表寫在 WeaponRack
##   bone  掛在哪根手骨
##   at    在**手骨的局部座標**下的偏移，單位是「1.6 公尺角色的公尺數」，
##         掛的時候會乘上這隻的骨架高度比例。+Y 是往身體外側（也就是
##         從手腕往拳頭的方向），所以 0.06 大約就是「握在拳心」。
##   spin  疊在 WeaponRack.GRIP_SPIN 上的微調角度（度）。
## 手骨的三軸方向見 weapon_rack.gd 的檔頭——調這幾個數字前先看那裡。
##
## pose 是程序化姿態層的參數（scripts/player/procedural_pose.gd）。
##
## breath_amplitude 是**放大過的**。原本 0.6–1.4 度，在遊戲鏡頭下頭與肩完全看不出
## 在動（`gait_probe` 待機那段量到頭位移不到半公分）——三尊雕像。放大到 2–3.6 度
## 之後頭肩動 1.5 公分以上，才看得見有人在呼吸。三隻的比例（戰士深慢、法師淺、
## 弓手淺快）維持不變。
## 角度單位是度，Vector3(X, Y, Z) 在「角色空間」下解讀：
##   X 正 = 抬頭／後仰    Y 正 = 向左轉    Z 正 = 向角色的右手邊倒
## 所以手臂往外張是左臂 Z 負、右臂 Z 正。這些是給人調的數字，不是規則——
## 覺得戰士太駝背就把 Spine 的 X 往正的調，不必動程式。

const CHARACTERS := {
	# 豬戰士：體格撐開、微前傾、呼吸幅度大而慢。站在那裡就該像一堵牆。
	&"pig_warrior": {
		"model": "res://assets/characters/pig_warrior.glb",
		"walk_speed": 0.873,
		"weight": WeightLadder.PIG,
		"height": 1.6,
		"yaw_offset": 180.0,
		"idle_hold": 0.55,
		"weapons": [
			{
				"kind": &"sword", "bone": &"RightHand",
				"at": Vector3(0.0, 0.06, 0.0), "spin": Vector3(94.0, 0.0, 50.0),
			},
		],
		"pose": {
			"breath_amplitude": 3.6,
			"breath_period": 4.0,
			"sway_amplitude": 2.0,
			"sway_period": 6.3,
			"look_speed": 0.8,
			"bones": {
				&"Spine": Vector3(-3.0, 0.0, 0.0),
				&"Chest": Vector3(1.5, 0.0, 0.0),
				&"Head": Vector3(2.5, 0.0, 0.0),
				&"LeftUpperArm": Vector3(0.0, 0.0, -14.0),
				&"RightUpperArm": Vector3(0.0, 0.0, 14.0),
				&"LeftLowerArm": Vector3(-6.0, 0.0, 0.0),
				&"RightLowerArm": Vector3(-6.0, 0.0, 0.0),
			},
		},
	},
	# 蛙法師：挺胸、兩手收在身前、幾乎不擺動。安靜是他的辨識度。
	&"frog_mage": {
		"model": "res://assets/characters/frog_mage.glb",
		"walk_speed": 0.752,
		"weight": WeightLadder.FROG,
		"height": 1.4,
		"yaw_offset": 180.0,
		"idle_hold": 0.55,
		"weapons": [
			{
				"kind": &"staff", "bone": &"RightHand",
				"at": Vector3(0.0, 0.06, 0.0), "spin": Vector3(-34.0, 0.0, 31.0),
			},
		],
		"pose": {
			"breath_amplitude": 2.0,
			"breath_period": 4.6,
			"sway_amplitude": 0.4,
			"sway_period": 7.9,
			"look_speed": 1.0,
			"bones": {
				&"Spine": Vector3(2.0, 0.0, 0.0),
				&"Chest": Vector3(2.5, 0.0, 0.0),
				&"Head": Vector3(-4.0, 0.0, 0.0),
				# 這隻的骨架本身手就張得很開：實測手離身體中線 0.66 個身高，
				# 豬與貓只有 0.38–0.42，而且整個走路循環都一樣，不是挑幀能解決的。
				# 所以這裡是往內收（左臂 Z 正、右臂 Z 負），跟另外兩隻方向相反。
				# 52 度是掃出來的：26 → 0.575、40 → 0.498、52 → 0.423，
				# 落在貓 0.407 與豬 0.477 之間，法師本來就該比戰士收斂。
				&"LeftUpperArm": Vector3(0.0, 0.0, 52.0),
				&"RightUpperArm": Vector3(0.0, 0.0, -52.0),
				&"LeftLowerArm": Vector3(-34.0, 0.0, 0.0),
				&"RightLowerArm": Vector3(-34.0, 0.0, 0.0),
			},
		},
	},
	# 貓弓手：側身站、一手抬到腰前像搭著箭、呼吸淺而快、轉頭最快。
	&"cat_archer": {
		"model": "res://assets/characters/cat_archer.glb",
		"walk_speed": 0.915,
		"weight": WeightLadder.CAT,
		"height": 1.7,
		"yaw_offset": 180.0,
		"idle_hold": 0.55,
		"weapons": [
			{
				"kind": &"bow", "bone": &"LeftHand",
				"at": Vector3(0.0, 0.06, 0.0), "spin": Vector3(108.0, 0.0, -21.0),
			},
		],
		"pose": {
			"breath_amplitude": 2.4,
			"breath_period": 2.6,
			"sway_amplitude": 1.0,
			"sway_period": 4.1,
			"look_speed": 1.6,
			"bones": {
				&"Spine": Vector3(0.0, 8.0, 0.0),
				&"Chest": Vector3(-1.5, -4.0, 0.0),
				&"Head": Vector3(0.0, -5.0, 0.0),
				&"LeftUpperArm": Vector3(0.0, 0.0, -5.0),
				&"RightUpperArm": Vector3(0.0, 0.0, 5.0),
				&"LeftLowerArm": Vector3(-28.0, 0.0, 0.0),
				&"RightLowerArm": Vector3(-10.0, 0.0, 0.0),
			},
		},
	},
}

## M0 的 slot 對應。之後由玩家在營地選角（docs/08 換角色）。
const SLOT_ORDER: Array[StringName] = [&"pig_warrior", &"frog_mage", &"cat_archer"]


static func id_for_slot(slot_id: int) -> StringName:
	if slot_id < 0:
		return SLOT_ORDER[0]
	return SLOT_ORDER[slot_id % SLOT_ORDER.size()]


static func entry(character_id: StringName) -> Dictionary:
	return CHARACTERS.get(character_id, {})
