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
## Meshy 目前只給了走路，站著不動時得從走路循環裡挑一個看起來像站姿的位置。
## 之後真的有 idle 了，CharacterVisual 會自動改用它，這個欄位就沒作用了。
##
## pose 是程序化姿態層的參數（scripts/player/procedural_pose.gd）。
## 角度單位是度，Vector3(X, Y, Z) 在「角色空間」下解讀：
##   X 正 = 抬頭／後仰    Y 正 = 向左轉    Z 正 = 向角色的右手邊倒
## 所以手臂往外張是左臂 Z 負、右臂 Z 正。這些是給人調的數字，不是規則——
## 覺得戰士太駝背就把 Spine 的 X 往正的調，不必動程式。

const CHARACTERS := {
	# 豬戰士：體格撐開、微前傾、呼吸幅度大而慢。站在那裡就該像一堵牆。
	&"pig_warrior": {
		"model": "res://assets/characters/pig_warrior.glb",
		"weight": WeightLadder.PIG,
		"height": 1.6,
		"yaw_offset": 180.0,
		"idle_hold": 0.0,
		"pose": {
			"breath_amplitude": 1.4,
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
		"weight": WeightLadder.FROG,
		"height": 1.4,
		"yaw_offset": 180.0,
		"idle_hold": 0.0,
		"pose": {
			"breath_amplitude": 0.6,
			"breath_period": 4.6,
			"sway_amplitude": 0.4,
			"sway_period": 7.9,
			"look_speed": 1.0,
			"bones": {
				&"Spine": Vector3(2.0, 0.0, 0.0),
				&"Chest": Vector3(2.5, 0.0, 0.0),
				&"Head": Vector3(-4.0, 0.0, 0.0),
				&"LeftUpperArm": Vector3(0.0, 0.0, -8.0),
				&"RightUpperArm": Vector3(0.0, 0.0, 8.0),
				&"LeftLowerArm": Vector3(-34.0, 0.0, 0.0),
				&"RightLowerArm": Vector3(-34.0, 0.0, 0.0),
			},
		},
	},
	# 貓弓手：側身站、一手抬到腰前像搭著箭、呼吸淺而快、轉頭最快。
	&"cat_archer": {
		"model": "res://assets/characters/cat_archer.glb",
		"weight": WeightLadder.CAT,
		"height": 1.7,
		"yaw_offset": 180.0,
		"idle_hold": 0.0,
		"pose": {
			"breath_amplitude": 0.8,
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
