extends Node

## 抓取、投擲、掙扎的權威判定。全部由 host 決定（TD-02）。
##
## 客戶端只能說「我想抓」，不能說「我要抓那一個」——目標查詢在 host 端做。
## 這條 request → host 驗證 → 廣播 的路徑與 PlayerRegistry 的報到同一套，
## 之後的疊高（TD-05）也會沿用。
##
## 重量規則（docs/04）：只能抓起比自己輕的目標。這是 host 唯一要驗的東西，
## 也是整個系統唯一不能讓客戶端說了算的地方。

## 投擲初速的基準值。實際速度還會乘上蓄力與重量比。
const THROW_BASE_SPEED := 9.0

## 投擲的重量修正上下限。太重丟不遠，太輕也不該變成狙擊槍。
const THROW_WEIGHT_SCALE := Vector2(0.4, 2.0)

## 向上的投擲分量，讓拋物線好看一點。
const THROW_LIFT := 0.35

## 放開後多久才能再抓，避免一放開就被同一個人抓回去。
const REGRAB_COOLDOWN := 0.4

var _cooldowns: Dictionary = {}


func _physics_process(_delta: float) -> void:
	if NetworkService.is_host():
		_reclaim_orphans()


## 持有者中途離線時，被他抓著的東西會永遠停在半空中而且沒人能再抓。
## host 每幀掃一次，把沒有持有者的東西放掉。
func _reclaim_orphans() -> void:
	for node in get_tree().get_nodes_in_group("carryables"):
		if node.held_by >= 0 and find_player(node.held_by) == null:
			_apply_release.rpc(node.held_by, str(node.get_path()), Vector3.ZERO)


func find_player(slot_id: int) -> Node3D:
	for node in get_tree().get_nodes_in_group("player_characters"):
		if node.slot_id == slot_id:
			return node
	return null


## 刻意不檢查持有者是否還在場上——持有者中途離線時，
## 這個函式仍要找得到那個被卡住的物件，才有辦法把它放掉（見 _reclaim_orphans）。
func held_carryable(slot_id: int) -> Carryable:
	for node in get_tree().get_nodes_in_group("carryables"):
		if node.held_by == slot_id:
			return node
	return null


# --- 客戶端送出的請求（host 才會處理）--------------------------------------

@rpc("any_peer", "call_local", "reliable")
func request_grab(slot_id: int) -> void:
	if not _is_authorised(slot_id):
		return
	if held_carryable(slot_id) != null:
		return
	if _cooldowns.get(slot_id, 0.0) > Time.get_ticks_msec() / 1000.0:
		return
	var grabber := find_player(slot_id)
	if grabber == null:
		return
	var target := _best_target(grabber)
	if target == null:
		return
	_apply_grab.rpc(slot_id, str(target.get_path()))


@rpc("any_peer", "call_local", "reliable")
func request_drop(slot_id: int) -> void:
	if not _is_authorised(slot_id):
		return
	_release(slot_id, Vector3.ZERO)


@rpc("any_peer", "call_local", "reliable")
func request_throw(slot_id: int, charge: float) -> void:
	if not _is_authorised(slot_id):
		return
	var carryable := held_carryable(slot_id)
	var grabber := find_player(slot_id)
	if carryable == null or grabber == null:
		return
	_release(slot_id, _throw_velocity(grabber, carryable, charge))


## 被抓的人掙脫。掙扎的累積在被抓者自己那端算，這裡只確認他真的正被這個人抓著。
@rpc("any_peer", "call_local", "reliable")
func request_struggle_break(holder_slot: int) -> void:
	if not NetworkService.is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	var carryable := held_carryable(holder_slot)
	if carryable == null:
		return
	var victim := carryable.body()
	if not victim.has_method("set_carried_by"):
		return
	if sender != 1 and victim.owner_peer_id != sender:
		return
	_release(holder_slot, Vector3.UP * 2.0)


# --- host 端的判定 -----------------------------------------------------------

func _is_authorised(slot_id: int) -> bool:
	if not NetworkService.is_host():
		return false
	# rpc_id(1) 由 host 自己呼叫時是本地呼叫，sender 為 0。
	var sender := multiplayer.get_remote_sender_id()
	var claimed_peer := sender if sender != 0 else 1
	var slot := PlayerRegistry.get_slot(slot_id)
	return slot != null and slot.peer_id == claimed_peer


func _best_target(grabber: Node3D) -> Carryable:
	var best: Carryable = null
	var best_distance := INF
	for overlap in grabber.grab_probe.get_overlapping_bodies():
		if overlap == grabber:
			continue
		var carryable := overlap.get_node_or_null("Carryable") as Carryable
		if carryable == null or carryable.is_held():
			continue
		# 重量規則：只能抓起比自己輕的（docs/04）。相同重量抓不動，這是刻意的。
		if carryable.weight >= grabber.weight:
			continue
		var distance := grabber.global_position.distance_to(overlap.global_position)
		if distance < best_distance:
			best_distance = distance
			best = carryable
	return best


func _throw_velocity(grabber: Node3D, carryable: Carryable, charge: float) -> Vector3:
	# 蓄力由客戶端計時，所以一定要夾住。合作 PvE 不需要防作弊，
	# 但要防的是掉封包造成的離譜數值。
	var clamped := clampf(charge, 0.0, 1.0)
	var ratio := clampf(
		grabber.weight / maxf(carryable.weight, 1.0),
		THROW_WEIGHT_SCALE.x,
		THROW_WEIGHT_SCALE.y
	)
	# 明確標型別：grabber 宣告成 Node3D，facing_basis() 不是它的成員，
	# 回傳型別未知，:= 推不出來。
	var forward: Vector3 = -grabber.facing_basis().z
	var speed := THROW_BASE_SPEED * (0.35 + 0.65 * clamped) * ratio
	return (forward + Vector3.UP * THROW_LIFT).normalized() * speed


func _release(slot_id: int, release_velocity: Vector3) -> void:
	var carryable := held_carryable(slot_id)
	if carryable == null:
		return
	_apply_release.rpc(slot_id, str(carryable.get_path()), release_velocity)


# --- 廣播（call_local 讓 host 走同一條路徑）----------------------------------

@rpc("authority", "call_local", "reliable")
func _apply_grab(slot_id: int, path: String) -> void:
	var carryable := get_node_or_null(NodePath(path)) as Carryable
	if carryable == null:
		push_warning("[Carry] 找不到 %s，抓取略過" % path)
		return
	carryable.begin_carry(slot_id)


@rpc("authority", "call_local", "reliable")
func _apply_release(slot_id: int, path: String, release_velocity: Vector3) -> void:
	var carryable := get_node_or_null(NodePath(path)) as Carryable
	if carryable == null:
		return
	carryable.end_carry(release_velocity)
	_cooldowns[slot_id] = Time.get_ticks_msec() / 1000.0 + REGRAB_COOLDOWN
