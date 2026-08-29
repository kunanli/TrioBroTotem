class_name Carryable
extends Node3D

## 掛在任何可以被抓起來的東西底下的元件。
##
## 「扛昏迷隊友、兩人合扛原木、搬石頭共用同一套抓取與負重系統」——
## docs/04-systems.md 的這句話就是這個元件存在的理由：玩家與場景物件
## 走同一條路徑，之後多一種可搬物件只要掛一個 Carryable。
##
## 被抓時**不做 reparent**，改成每幀跟隨持有者的錨點。
## 理由與 TD-05 的疊高附掛相同：reparent 會動到 MultiplayerSpawner
## 追蹤的節點結構，而純粹的 transform 跟隨不會。

@export var weight: float = WeightLadder.CRATE

## 持有者的 slot_id，-1 表示沒人拿。這個值由 host 決定（TD-02），
## 透過 CarrySystem 的 RPC 廣播，任何一端都不得自行寫入。
var held_by: int = -1


func _ready() -> void:
	add_to_group("carryables")


func body() -> Node3D:
	return get_parent() as Node3D


func is_held() -> bool:
	return held_by >= 0


func begin_carry(holder_slot: int) -> void:
	held_by = holder_slot
	var target := body()
	if target is RigidBody3D:
		target.freeze = true
	elif target.has_method("set_carried_by"):
		target.set_carried_by(holder_slot)


func end_carry(release_velocity: Vector3) -> void:
	var target := body()
	held_by = -1
	if target is RigidBody3D:
		# 只有 host 模擬場景物件（TD-02），客戶端維持凍結等同步。
		if NetworkService.simulates_world():
			target.freeze = false
			target.linear_velocity = release_velocity
	elif target.has_method("set_carried_by"):
		target.set_carried_by(-1)
		if target.has_method("apply_throw"):
			target.apply_throw(release_velocity)


func _physics_process(_delta: float) -> void:
	if held_by < 0:
		return
	var holder := CarrySystem.find_player(held_by)
	if holder == null:
		return
	var target := body()
	target.global_position = holder.carry_anchor.global_position
	if not target.has_method("set_carried_by"):
		target.global_rotation = holder.carry_anchor.global_rotation
