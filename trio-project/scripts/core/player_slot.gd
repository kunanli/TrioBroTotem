class_name PlayerSlot
extends RefCounted

## TD-04：玩家身分不等於連線 peer。
##
## 一個 peer 可以擁有多個 slot（本地分屏），一個 slot 也可以沒有真人（AI 接管）。
## 這一層是本地分屏、AI 補位、營地換角三項功能的共同前提，
## 事後補裝會動到連線核心，所以在 M0 第一行連線程式碼之前就要就位。
##
## 見 docs/13-tech-decisions.md TD-04。

const MAX_SLOTS := 3

## 0..2，隊伍中的位置。角色的 multiplayer 節點名由此決定，全機一致。
var slot_id: int = -1

## 哪台機器負責這個 slot。AI 接管時為 host 的 peer_id。
var peer_id: int = 1

## 該機器上的哪個輸入裝置。-1 = 鍵鼠，>= 0 = 手把 device index。
## 本地分屏時同一個 peer_id 會有兩個 slot，靠這個欄位分開。
var device_id: int = -1

## 是否由 AI 接管。真人中途加入時只是改這個欄位 + peer_id，角色狀態不斷。
var is_ai: bool = false

## 目前 possess 哪隻角色（豬 / 蛙 / 貓 ...）。M0 尚未使用。
var character_id: StringName = &""

var display_name: String = ""


func _init(p_slot_id: int = -1, p_peer_id: int = 1, p_device_id: int = -1) -> void:
	slot_id = p_slot_id
	peer_id = p_peer_id
	device_id = p_device_id


## 這個 slot 是不是由「本機」負責。注意這不等於 is_multiplayer_authority()——
## 本地分屏時本機會負責兩個 slot。
func is_local(local_peer_id: int) -> bool:
	return peer_id == local_peer_id


func to_dict() -> Dictionary:
	return {
		"slot_id": slot_id,
		"peer_id": peer_id,
		"device_id": device_id,
		"is_ai": is_ai,
		"character_id": String(character_id),
		"display_name": display_name,
	}


static func from_dict(data: Dictionary) -> PlayerSlot:
	var slot := PlayerSlot.new()
	slot.slot_id = int(data.get("slot_id", -1))
	slot.peer_id = int(data.get("peer_id", 1))
	slot.device_id = int(data.get("device_id", -1))
	slot.is_ai = bool(data.get("is_ai", false))
	slot.character_id = StringName(data.get("character_id", ""))
	slot.display_name = String(data.get("display_name", ""))
	return slot
