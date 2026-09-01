extends Node

## 血量、倒地與救援的權威判定（docs/04 Ragdoll 與倒地救援）。
##
## 設計上這一套同時是治療系統：血量歸零不會死，只是倒地等人扶，
## 而扶起會帶回一小段血——「扶起即回血」是治療三層的第一層（docs/04）。
## 所以這裡沒有獨立的補師機制，也不該有。
##
## 網路模型（TD-06）：同步的是「倒地與否」與 host 權威的位置，不是每根骨頭。
## 骨骼讓各客戶端自己算——三台畫面上手腳擺的姿勢不一樣完全沒關係，
## 那反而符合「事故就是內容」。但「你倒在哪」必須是 host 說了算，
## 否則會出現「我明明站在他旁邊卻扶不到」這種最傷體驗的 bug。

const MAX_HEALTH := 100.0

## 扶起需要的時間，以及扶起後回多少血（docs/04 治療第一層）。
const REVIVE_TIME := 2.5
const REVIVE_HEAL := 35.0
const REVIVE_RANGE := 2.2

## 全隊倒地後多久重來。正式版是退回營地（docs/04），M0 先原地重生。
const WIPE_RESPAWN_DELAY := 3.0

var _health: Dictionary = {}
var _downed: Dictionary = {}
var _wipe_timer: float = -1.0


func health_of(slot_id: int) -> float:
	return _health.get(slot_id, MAX_HEALTH)


func is_downed(slot_id: int) -> bool:
	return _downed.get(slot_id, false)


func any_alive() -> bool:
	for slot in PlayerRegistry.slots:
		if not is_downed(slot.slot_id):
			return true
	return false


func _physics_process(delta: float) -> void:
	if not NetworkService.is_host():
		return
	_tick_wipe(delta)


## 全隊倒地 = 本章失敗（docs/04）。章節內因此不需要檢查點系統。
func _tick_wipe(delta: float) -> void:
	if PlayerRegistry.slots.is_empty():
		return
	if any_alive():
		_wipe_timer = -1.0
		return
	if _wipe_timer < 0.0:
		_wipe_timer = WIPE_RESPAWN_DELAY
		print("[Down] 全隊倒地，%.0f 秒後重來" % WIPE_RESPAWN_DELAY)
		return
	_wipe_timer -= delta
	if _wipe_timer <= 0.0:
		_wipe_timer = -1.0
		for slot in PlayerRegistry.slots:
			_apply_revive.rpc(slot.slot_id, MAX_HEALTH)


# --- 客戶端送出的請求 -------------------------------------------------------

## 落地傷害。速度由自己這端量，host 夾住範圍——蓄力投擲也是同一個處理方式。
@rpc("any_peer", "call_local", "reliable")
func request_fall_damage(slot_id: int, impact_speed: float) -> void:
	if not _authorised(slot_id) or is_downed(slot_id):
		return
	var over := clampf(impact_speed, 0.0, 60.0) - PlayerCharacter.SAFE_FALL_SPEED
	if over <= 0.0:
		return
	apply_damage(slot_id, over * PlayerCharacter.FALL_DAMAGE_PER_SPEED, Vector3.ZERO)


## 扶起。累積在扶的人那端算，滿了才送一次請求——每幀送會是 120 packets/s。
@rpc("any_peer", "call_local", "reliable")
func request_revive(slot_id: int, target_slot: int) -> void:
	if not _authorised(slot_id) or is_downed(slot_id):
		return
	if not is_downed(target_slot):
		return
	var reviver := CarrySystem.find_player(slot_id)
	var target := CarrySystem.find_player(target_slot)
	if reviver == null or target == null:
		return
	if reviver.global_position.distance_to(target.global_position) > REVIVE_RANGE:
		return
	_apply_revive.rpc(target_slot, REVIVE_HEAL)


## 測試用：把自己打倒。M0 還沒有敵人，沒有這個就驗不了倒地與救援。
## 卡住時把自己送回出生點。
##
## 測試場一定會有人卡進地形、掉進縫裡、或被丟到回不來的地方。沒有這個鍵，
## 唯一的解法是重開遊戲，那等於測試中斷。順便把血補滿並解除倒地——
## 目的是「讓人繼續玩」，不是懲罰。
@rpc("any_peer", "call_local", "reliable")
func request_respawn(slot_id: int) -> void:
	if not _authorised(slot_id):
		return
	_apply_respawn.rpc(slot_id)


@rpc("authority", "call_local", "reliable")
func _apply_respawn(slot_id: int) -> void:
	_downed[slot_id] = false
	_health[slot_id] = MAX_HEALTH
	var player := CarrySystem.find_player(slot_id)
	if player != null and player.has_method("respawn"):
		player.respawn()


@rpc("any_peer", "call_local", "reliable")
func request_debug_knockdown(slot_id: int) -> void:
	if not _authorised(slot_id):
		return
	apply_damage(slot_id, MAX_HEALTH, Vector3.UP * 3.0)


# --- host 端 ---------------------------------------------------------------

func _authorised(slot_id: int) -> bool:
	if not NetworkService.is_host():
		return false
	var sender := multiplayer.get_remote_sender_id()
	var claimed := sender if sender != 0 else 1
	var slot := PlayerRegistry.get_slot(slot_id)
	return slot != null and slot.peer_id == claimed


## 之後的攻擊、誤傷、場景傷害都走這裡。傷害一律 host 決定（TD-02）。
func apply_damage(slot_id: int, amount: float, impulse: Vector3) -> void:
	if not NetworkService.is_host() or is_downed(slot_id):
		return
	var remaining := maxf(health_of(slot_id) - amount, 0.0)
	_apply_health.rpc(slot_id, remaining)
	if remaining <= 0.0:
		_apply_down.rpc(slot_id, impulse)


## 場景補給的回血（docs/04 治療系統的第二層）。蘋果、圖騰站、掉落都走這裡。
##
## **不要用 apply_damage(slot, -amount) 代替。** 那條路只有下限 maxf(…, 0.0)
## 沒有上限，蘋果會把人補到 100 以上——而 100 是全遊戲唯一的血量上限，
## 破了它之後「還剩幾成血」這件事就再也讀不出來了。
##
## 倒地的人補不了：血量歸零不能自行復活，扶起是隊友的工作（docs/04）。
## 那條路是 _apply_revive，不是這裡。
func apply_heal(slot_id: int, amount: float) -> void:
	if not NetworkService.is_host() or is_downed(slot_id):
		return
	_apply_health.rpc(slot_id, minf(health_of(slot_id) + amount, MAX_HEALTH))


# --- 廣播 -------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _apply_health(slot_id: int, value: float) -> void:
	_health[slot_id] = value


@rpc("authority", "call_local", "reliable")
func _apply_down(slot_id: int, impulse: Vector3) -> void:
	_downed[slot_id] = true
	var player := CarrySystem.find_player(slot_id)
	if player != null:
		player.on_downed(impulse)
	# 倒下的人不能繼續當梯子或當乘客（docs/04 底層倒下整柱潰散）。
	# 這兩個函式自己會擋非 host，不必在這裡再判一次。
	StackSystem.collapse_above(slot_id)
	StackSystem.detach(slot_id)


@rpc("authority", "call_local", "reliable")
func _apply_revive(slot_id: int, health: float) -> void:
	_downed[slot_id] = false
	_health[slot_id] = maxf(health, 1.0)
	var player := CarrySystem.find_player(slot_id)
	if player != null:
		player.on_revived()
