extends Node

## 疊高的權威判定。全案風險最高的一項（docs/10 高風險項目）。
##
## 做法是**邏輯附掛**，不是網路化的剛體堆疊（TD-05）：上層角色的位置由
## 「下層的頭頂錨點 + 自己的半身高」推導出來，整柱只有底座在做物理。
## 這把「剛體堆疊同步」這個幾乎做不好的問題，降級成「狀態機 + 座標推導」。
##
## 判定流程與抓取相同（TD-02）：客戶端只送出「我好像可以疊上去」的請求，
## 目標查詢與重量驗證都在 host 重跑一次。客戶端說了不算。

## 潰散時往外彈開的速度。要夠明顯讓玩家知道柱子倒了（事故就是內容，docs/01）。
const COLLAPSE_IMPULSE := 4.5
const COLLAPSE_LIFT := 3.0

## 剛脫離的人多久內不能再疊回去，避免跳下來又立刻黏上。
const RESTACK_COOLDOWN := 0.5

## 水平對齊與高度差的容許範圍（相對於底座身高）。
const ALIGN_RADIUS_RATIO := 0.45
const HEIGHT_TOLERANCE := 0.6

## 誰疊在誰上面。key 是上層的 slot_id，value 是它踩著的 slot_id。
## 用「向下指」而不是「每層一個清單」，是因為每個角色最多只踩一個人，
## 這樣新增／移除都不必維護陣列順序。
var _below: Dictionary = {}
var _cooldowns: Dictionary = {}


func below_of(slot_id: int) -> int:
	return _below.get(slot_id, -1)


func is_stacked(slot_id: int) -> bool:
	return _below.has(slot_id)


## 誰踩在這個人頭上，沒有回傳 -1。
func rider_of(slot_id: int) -> int:
	for rider in _below:
		if _below[rider] == slot_id:
			return rider
	return -1


## 從這個人往上的整串（不含自己），由下往上。
func riders_above(slot_id: int) -> Array[int]:
	var chain: Array[int] = []
	var cursor := rider_of(slot_id)
	while cursor >= 0:
		chain.append(cursor)
		cursor = rider_of(cursor)
	return chain


func _physics_process(_delta: float) -> void:
	if NetworkService.is_host():
		_reclaim_orphans()


## 有人中途離線時，踩在他身上的角色會卡在半空。host 每幀掃一次。
func _reclaim_orphans() -> void:
	for rider in _below.keys():
		if CarrySystem.find_player(rider) == null or CarrySystem.find_player(_below[rider]) == null:
			_apply_unstack.rpc(rider, Vector3.ZERO)


# --- 客戶端送出的請求 -------------------------------------------------------

## 疊高不佔按鍵（docs/06）：走到隊友頭上就自動吸附。
## 客戶端偵測到腳下踩著人時送這個請求，host 再驗一次。
@rpc("any_peer", "call_local", "reliable")
func request_stack(slot_id: int, target_slot: int) -> void:
	if not _authorised(slot_id):
		return
	if _cooldowns.get(slot_id, 0.0) > Time.get_ticks_msec() / 1000.0:
		return
	if not _can_stack(slot_id, target_slot):
		return
	_apply_stack.rpc(slot_id, target_slot)


## 上層按跳鍵自己下來（docs/06：按跳鍵下來）。
@rpc("any_peer", "call_local", "reliable")
func request_dismount(slot_id: int) -> void:
	if not _authorised(slot_id):
		return
	if not is_stacked(slot_id):
		return
	_apply_unstack.rpc(slot_id, Vector3.UP * COLLAPSE_LIFT)


## 底層跳躍或受擊 → 整柱潰散（docs/04）。
@rpc("any_peer", "call_local", "reliable")
func request_collapse(slot_id: int) -> void:
	if not _authorised(slot_id):
		return
	collapse_above(slot_id)


## 純 host 端的脫離。不要直接呼叫 request_dismount——那是 @rpc 方法，
## 直接呼叫時 get_remote_sender_id() 拿到的是上一次 RPC 的殘留值。
func detach(slot_id: int) -> void:
	if not NetworkService.is_host() or not is_stacked(slot_id):
		return
	_apply_unstack.rpc(slot_id, Vector3.UP * COLLAPSE_LIFT)


## host 端也會直接呼叫（例如之後的受擊、ragdoll）。
func collapse_above(slot_id: int) -> void:
	if not NetworkService.is_host():
		return
	var chain := riders_above(slot_id)
	if chain.is_empty():
		return
	# 由上往下拆，免得拆到一半下面的人已經不在鏈上。
	chain.reverse()
	for index in chain.size():
		var rider: int = chain[index]
		var angle := TAU * float(index) / maxf(chain.size(), 1.0)
		var push := Vector3(cos(angle), 0.0, sin(angle)) * COLLAPSE_IMPULSE
		_apply_unstack.rpc(rider, push + Vector3.UP * COLLAPSE_LIFT)


# --- host 端的判定 -----------------------------------------------------------

func _authorised(slot_id: int) -> bool:
	if not NetworkService.is_host():
		return false
	var sender := multiplayer.get_remote_sender_id()
	var claimed := sender if sender != 0 else 1
	var slot := PlayerRegistry.get_slot(slot_id)
	return slot != null and slot.peer_id == claimed


func _creates_loop(slot_id: int, target_slot: int) -> bool:
	var cursor := below_of(target_slot)
	while cursor >= 0:
		if cursor == slot_id:
			return true
		cursor = below_of(cursor)
	return false


func _stack_allowed(rider: Node3D, base: Node3D, slot_id: int, target_slot: int) -> bool:
	# 重量即規則：輕的才能站到重的上面（docs/04 順序必然由重量決定）。
	var lighter: bool = rider.weight < base.weight
	# 一個人頭上只能站一個；手上有事的人不該還能當梯子。
	var free: bool = (
		rider_of(target_slot) < 0
		and rider.carried_by_slot < 0
		and base.carried_by_slot < 0
		and CarrySystem.held_carryable(target_slot) == null
	)
	return lighter and free and not _creates_loop(slot_id, target_slot)


## host 自己重新確認幾何關係，不採信客戶端說的位置。
func _stack_aligned(rider: Node3D, base: Node3D) -> bool:
	var offset: Vector3 = rider.global_position - base.global_position
	var horizontal := Vector2(offset.x, offset.z).length()
	var expected: float = (base.character_height + rider.character_height) * 0.5
	return (
		horizontal < base.character_height * ALIGN_RADIUS_RATIO
		and absf(offset.y - expected) < HEIGHT_TOLERANCE
	)


func _can_stack(slot_id: int, target_slot: int) -> bool:
	if slot_id == target_slot or is_stacked(slot_id):
		return false
	var rider := CarrySystem.find_player(slot_id)
	var base := CarrySystem.find_player(target_slot)
	if rider == null or base == null:
		return false
	return _stack_allowed(rider, base, slot_id, target_slot) and _stack_aligned(rider, base)


# --- 廣播 -------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _apply_stack(slot_id: int, target_slot: int) -> void:
	_below[slot_id] = target_slot
	var rider := CarrySystem.find_player(slot_id)
	if rider != null:
		rider.on_stacked(target_slot)


@rpc("authority", "call_local", "reliable")
func _apply_unstack(slot_id: int, push: Vector3) -> void:
	if not _below.erase(slot_id):
		return
	_cooldowns[slot_id] = Time.get_ticks_msec() / 1000.0 + RESTACK_COOLDOWN
	var rider := CarrySystem.find_player(slot_id)
	if rider != null:
		rider.on_unstacked(push)
