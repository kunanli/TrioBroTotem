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

## 手離東西多遠會脫手。
##
## 不做繩索物理（那是 M2 的事），現在只要「走太開會掉」這個規則清楚就夠了。
##
## 這個值管的是**人**離得多遠，不是東西有多長：共扛時原木掛在兩人錨點的中點，
## 所以九公尺長的原木由兩個相隔四公尺的人抬著完全合理。
## （這裡原本的註解寫著「要大於原木長度」，那是錯的，而且一直沒事——
## 因為共扛從來沒有真的發生過。）
const SHARED_MAX_DISTANCE := 4.5

var _cooldowns: Dictionary = {}


func _physics_process(_delta: float) -> void:
	if not NetworkService.is_host():
		return
	_reclaim_orphans()
	_break_stretched()


## 持有者中途離線時，被他抓著的東西會永遠停在半空中而且沒人能再抓。
## host 每幀掃一次，把失去持有者的東西放掉。
func _reclaim_orphans() -> void:
	for node in get_tree().get_nodes_in_group("carryables"):
		var carryable: Carryable = node
		for slot in carryable.holders.duplicate():
			if find_player(slot) == null:
				_apply_leave.rpc(slot, str(carryable.get_path()))


## 共扛的兩人走太開就脫手。
##
## 不擋住他們走開——那會變成兩個人被綁在一起互相拉扯，比掉下來更難受。
## 掉下來至少規則清楚：離太遠就扛不動了。
func _break_stretched() -> void:
	for node in get_tree().get_nodes_in_group("carryables"):
		var carryable: Carryable = node
		# 架住的東西不會跟著人走，所以人一走開就永遠拉成一條線——而且沒有
		# 任何東西會解除它，那個人就一路被拖慢下去。走遠了就當作放手。
		if carryable.is_held() and not carryable.is_lifted():
			var holder := find_player(carryable.primary_holder())
			if holder != null:
				var reach := holder.global_position.distance_to(carryable.global_position)
				if reach > SHARED_MAX_DISTANCE:
					_apply_release.rpc(carryable.primary_holder(), str(carryable.get_path()), Vector3.ZERO)
			continue
		if not carryable.is_shared():
			continue
		var a := find_player(carryable.holders[0])
		var b := find_player(carryable.holders[1])
		if a == null or b == null:
			continue
		if a.global_position.distance_to(b.global_position) > SHARED_MAX_DISTANCE:
			_apply_release.rpc(carryable.primary_holder(), str(carryable.get_path()), Vector3.ZERO)


func find_player(slot_id: int) -> Node3D:
	for node in get_tree().get_nodes_in_group("player_characters"):
		if node.slot_id == slot_id:
			return node
	return null


## 刻意不檢查持有者是否還在場上——持有者中途離線時，
## 這個函式仍要找得到那個被卡住的物件，才有辦法把它放掉（見 _reclaim_orphans）。
func held_carryable(slot_id: int) -> Carryable:
	for node in get_tree().get_nodes_in_group("carryables"):
		var carryable: Carryable = node
		if carryable.held_by(slot_id):
			return carryable
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
		# 抓不到不一定是「附近沒東西」，也可能是「太重了」。靜默失敗會讓玩家
		# 以為按鍵壞了——第一章要教的正是重量規則，所以這裡一定要出聲。
		var heavy := _nearest_too_heavy(grabber)
		if heavy != null:
			_apply_strain.rpc(str(heavy.get_path()))
		return
	# 架得住但抬不起來也要出聲，而且**那才是要教的那一刻**：「我抓到了，
	# 但它不動——需要有人來幫。」抓不動的那一聲以前是給「按了沒反應」用的，
	# 有了架住之後幾乎沒有東西是抓不動的，這一聲的意義就搬到這裡。
	if not target.can_join(grabber.weight):
		_apply_strain.rpc(str(target.get_path()))
	_apply_grab.rpc(slot_id, str(target.get_path()))


@rpc("any_peer", "call_local", "reliable")
func request_drop(slot_id: int) -> void:
	if not _is_authorised(slot_id):
		return
	var carryable := held_carryable(slot_id)
	if carryable == null:
		return
	# 共扛時放手只有自己脫離，東西不落地——另一個人還扛著。
	# 直接整個放掉的話，兩人合作搬東西會變成「誰先放手誰就毀掉進度」。
	if carryable.is_shared():
		_apply_leave.rpc(slot_id, str(carryable.get_path()))
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
	# 兩個人扛著的東西不能被其中一個丟出去——那在物理上與畫面上都說不通。
	# 想丟就先讓對方放手。
	if carryable.is_shared():
		_apply_leave.rpc(slot_id, str(carryable.get_path()))
		return
	# 抬都抬不起來的東西當然丟不出去。出一聲，不要靜默地把它放掉——
	# 玩家會以為自己丟了、然後發現東西還在腳邊。
	if not carryable.is_lifted():
		_apply_strain.rpc(str(carryable.get_path()))
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


## 抓取判定（docs/04 的重量規則 + docs/07 第一章的兩人合扛）：
##   1. 已經有人拿、兩人重量和超得過 → 加入
##   2. 沒人拿、自己扛得動           → 單人扛
##   3. 沒人拿、扛不動、而且是「東西」→ **架住**（抓著但不離地，等人來幫）
##   4. 其餘（扛不動的人）           → 抓不到
##
## 第 3 段是這個機制的入口，而它以前不存在。原木 45、蛙 30、貓 20，
## **兩個人誰都開不了頭**，所以第 1 段那條路永遠到不了——共扛唯一的入口是
## 「豬先扛起來，別人再加入」，而豬自己就扛得動。於是「蛙加貓一起扛原木」
## 這句話寫在遊戲內的目標列上、寫在這裡、寫在 carryable.gd、寫在 docs/04，
## **四個地方全部是假的**。
func _best_target(grabber: Node3D) -> Carryable:
	var best: Carryable = null
	var best_distance := INF
	for overlap in grabber.grab_probe.get_overlapping_bodies():
		if overlap == grabber:
			continue
		var carryable := overlap.get_node_or_null("Carryable") as Carryable
		if carryable == null or carryable.held_by(grabber.slot_id):
			continue
		if not _can_lift(carryable, grabber):
			continue
		var distance := grabber.global_position.distance_to(overlap.global_position)
		if distance < best_distance:
			best_distance = distance
			best = carryable
	return best


func _can_lift(carryable: Carryable, grabber: Node3D) -> bool:
	if carryable.locked:
		return false
	if carryable.is_held():
		return carryable.can_join(grabber.weight)
	# 相同重量抬不動，這是刻意的（docs/04）。
	if carryable.weight < grabber.weight:
		return true
	# 架住：抬不動也抓得住。
	#
	# **只對東西，不對人。** 被架住的隊友照樣走得動，那個狀態沒有意義，
	# 而且他一走開，架住的人就會被拖慢半天卻抓著空氣。扛人是另一個動詞
	# （救援與喜劇），它的門檻維持嚴格單人判定。
	return not carryable.body().has_method("set_carried_by")


## 附近最近的「抓不動」目標，用來給玩家回饋。
func _nearest_too_heavy(grabber: Node3D) -> Carryable:
	var best: Carryable = null
	var best_distance := INF
	for overlap in grabber.grab_probe.get_overlapping_bodies():
		var carryable := overlap.get_node_or_null("Carryable") as Carryable
		if carryable == null or carryable.held_by(grabber.slot_id):
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
	if carryable.is_shared():
		Sfx.play(&"stack", carryable.global_position, 1.15)


## 一個人脫手，但東西還被別人扛著。
@rpc("authority", "call_local", "reliable")
func _apply_leave(slot_id: int, path: String) -> void:
	var carryable := get_node_or_null(NodePath(path)) as Carryable
	if carryable == null:
		return
	carryable.drop_holder(slot_id)
	_cooldowns[slot_id] = Time.get_ticks_msec() / 1000.0 + REGRAB_COOLDOWN
	if not carryable.is_held():
		carryable.end_carry(Vector3.ZERO)


## 抓不動的回饋。只出聲不做別的——這是教學，不是懲罰。
@rpc("authority", "call_local", "reliable")
func _apply_strain(path: String) -> void:
	var carryable := get_node_or_null(NodePath(path)) as Carryable
	if carryable != null:
		Sfx.play(&"strain", carryable.global_position)


## slot_id 保留在簽章裡是為了訊息本身的可讀性（誰觸發的放手），
## 但冷卻要套在**所有**持有者身上——共扛時只有觸發者被冷卻的話，
## 另一個人可以立刻抓回去，東西就永遠落不了地。
@rpc("authority", "call_local", "reliable")
func _apply_release(_slot_id: int, path: String, release_velocity: Vector3) -> void:
	var carryable := get_node_or_null(NodePath(path)) as Carryable
	if carryable != null and release_velocity.length() > 0.5:
		Sfx.play(&"throw", carryable.global_position)
	if carryable == null:
		return
	for slot in carryable.holders:
		_cooldowns[slot] = Time.get_ticks_msec() / 1000.0 + REGRAB_COOLDOWN
	carryable.end_carry(release_velocity)
