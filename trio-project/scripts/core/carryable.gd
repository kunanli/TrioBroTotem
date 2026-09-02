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
##
## 持有者是**清單**而不是單一個 slot，因為第一章要教「兩人合扛原木」
## （docs/07）。重量表（WeightLadder）的數字本來就支援這件事：
## 原木 45，豬 50 一個人扛得動，蛙 30 加貓 20 剛好也是 50——
## 「強的一個人扛，或弱的兩個人一起扛」。
##
## 而這件事一直到「架住」（`is_lifted`）做出來才**第一次真的成立**。

## 最多幾個人一起扛。三個人扛一根原木在畫面上讀不出來，也沒有設計上的理由。
const MAX_HOLDERS := 2

@export var weight: float = WeightLadder.CRATE

## 持有者的 slot_id 清單，空的表示沒人拿。這個清單由 host 決定（TD-02），
## 透過 CarrySystem 的 RPC 廣播，任何一端都不得自行寫入。
var holders: Array[int] = []

## 被場景結構鎖住，誰都抓不動（例如已經架成橋的原木）。
var locked: bool = false


func _ready() -> void:
	add_to_group("carryables")


func body() -> Node3D:
	return get_parent() as Node3D


func is_held() -> bool:
	return not holders.is_empty()


func is_shared() -> bool:
	return holders.size() > 1


## 抬得起來嗎——持有者的體重加起來要**超過**它。
##
## 這跟 can_join 是同一個不等式，只是換個問法：抓得住不等於抬得起來。
##
## **架住＝抓著但沒抬起來。** 物件留在原地、持有者被拖慢，等第二個人來。
## 沒有這個狀態的話，第一章那句「蛙 30 加貓 20 一起扛原木 45」是假的——
## 兩個人誰都開不了頭，`can_join` 那條路永遠到不了（見 carry_system 的
## `_can_lift`）。共扛唯一的入口本來是「豬先扛起來，別人再加入」，
## 而豬自己就扛得動，所以共扛從來沒有必要、也從來沒有發生過。
func is_lifted() -> bool:
	return not holders.is_empty() and holders_weight() > weight


## 第一個抓住的人。被扛的玩家只認得單一個持有者（set_carried_by 的介面），
## 共扛時由這個人代表。
func primary_holder() -> int:
	return holders[0] if not holders.is_empty() else -1


func held_by(slot_id: int) -> bool:
	return holders.has(slot_id)


func can_join(grabber_weight: float) -> bool:
	if holders.size() >= MAX_HOLDERS:
		return false
	return holders_weight() + grabber_weight > weight


func holders_weight() -> float:
	var total := 0.0
	for slot in holders:
		var holder := CarrySystem.find_player(slot)
		if holder != null:
			total += holder.weight
	return total


## 加入一個持有者。第一個人進來時才做「開始被扛」的狀態切換。
func begin_carry(holder_slot: int) -> void:
	if holders.has(holder_slot) or holders.size() >= MAX_HOLDERS:
		return
	var first := holders.is_empty()
	holders.append(holder_slot)
	if not first:
		return
	var target := body()
	if target is RigidBody3D:
		target.freeze = true
	elif target.has_method("set_carried_by"):
		target.set_carried_by(holder_slot)


## 一個人放手，但還有別人扛著。物件不落地，只是換成單人扛。
func drop_holder(holder_slot: int) -> void:
	holders.erase(holder_slot)


func end_carry(release_velocity: Vector3) -> void:
	var target := body()
	holders.clear()
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
	# **架住的東西不跟著錨點走。** 少了 is_lifted 這一半，一抓住就會瞬移到
	# 手上——那正好是「架住」要避免的事。
	if not is_lifted():
		return
	var target := body()
	var anchors := _anchors()
	if anchors.is_empty():
		return

	if anchors.size() == 1:
		target.global_position = anchors[0].global_position
		if not target.has_method("set_carried_by"):
			target.global_rotation = anchors[0].global_rotation
		return

	# 共扛：放在兩個錨點的中間，長軸沿著兩人的連線。
	# 原木因此是橫著被抬起來的——不必看 UI 就知道現在是兩個人在扛。
	var a := anchors[0].global_position
	var b := anchors[1].global_position
	target.global_position = (a + b) * 0.5
	if target.has_method("set_carried_by"):
		return
	var along := b - a
	if along.length_squared() < 0.0001:
		return
	target.global_transform = Transform3D(
		Basis.looking_at(along.normalized(), Vector3.UP), target.global_position
	)


func _anchors() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for slot in holders:
		var holder := CarrySystem.find_player(slot)
		if holder != null:
			out.append(holder.carry_anchor)
	return out
