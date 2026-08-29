class_name CharacterRoster
extends RefCounted

## 角色名冊：每隻的模型、重量、身高、朝向修正。
##
## 重量沿用 WeightLadder，不在這裡另立一份——重量即規則（docs/01），
## 全遊戲只能有一張表。身高與 assets/source/characters.json 對齊，
## 那是美術管線正規化時實際套用的數字。

const CHARACTERS := {
	&"pig_warrior": {
		"model": "res://assets/characters/pig_warrior.glb",
		"weight": WeightLadder.PIG,
		"height": 1.6,
		"yaw_offset": 0.0,
	},
	&"frog_mage": {
		"model": "res://assets/characters/frog_mage.glb",
		"weight": WeightLadder.FROG,
		"height": 1.4,
		"yaw_offset": 0.0,
	},
	&"cat_archer": {
		"model": "res://assets/characters/cat_archer.glb",
		"weight": WeightLadder.CAT,
		"height": 1.7,
		"yaw_offset": 0.0,
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
