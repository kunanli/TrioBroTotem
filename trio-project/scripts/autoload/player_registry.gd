extends Node

## 隊伍名冊：誰佔了哪個 slot。host 權威，客戶端只讀（TD-02）。
##
## 這是 autoload，所以在每台機器上的節點路徑都是 /root/PlayerRegistry，
## RPC 不需要任何額外的路徑同步就能對上——名冊這種全域小狀態放在
## autoload 比放在關卡裡簡單得多。
##
## 見 docs/13-tech-decisions.md TD-02、TD-04。

signal slots_changed()

var slots: Array[PlayerSlot] = []

## 本機要用的顯示名稱與輸入裝置，連線時送給 host。
var local_display_name: String = ""
var local_device_id: int = -1


func _ready() -> void:
	if local_display_name.is_empty():
		local_display_name = "Player-%d" % (randi() % 900 + 100)
	NetworkService.hosted.connect(_on_hosted)
	NetworkService.joined.connect(_on_joined)
	NetworkService.peer_left.connect(_on_peer_left)
	NetworkService.disconnected.connect(_on_disconnected)


# --- 查詢 -------------------------------------------------------------------

func get_slot(slot_id: int) -> PlayerSlot:
	for slot in slots:
		if slot.slot_id == slot_id:
			return slot
	return null


func slots_for_peer(peer_id: int) -> Array[PlayerSlot]:
	var found: Array[PlayerSlot] = []
	for slot in slots:
		if slot.peer_id == peer_id:
			found.append(slot)
	return found


func free_slot_id() -> int:
	for candidate in PlayerSlot.MAX_SLOTS:
		if get_slot(candidate) == null:
			return candidate
	return -1


# --- host 端的名冊異動 -------------------------------------------------------

func _on_hosted() -> void:
	slots.clear()
	_host_claim_slot(NetworkService.local_peer_id(), local_display_name, local_device_id)
	_fill_with_ai()


## 空位一律由 AI 補上（docs/11 Must：沒有它，湊不到三人的玩家無法遊玩）。
## 隊伍永遠是三個人，真人加入時是「接手」某個 AI，不是新增一個位置。
func _fill_with_ai() -> void:
	var host := NetworkService.local_peer_id()
	var added := false
	for candidate in PlayerSlot.MAX_SLOTS:
		if get_slot(candidate) != null:
			continue
		var slot := PlayerSlot.new(candidate, host, -1)
		slot.is_ai = true
		slot.display_name = "AI-%d" % candidate
		slots.append(slot)
		added = true
	if added:
		slots.sort_custom(_by_slot_id)
		_broadcast()


func _on_joined() -> void:
	# 客戶端連上後主動報到。host 不會自作主張替它取名或指定裝置。
	# 這條路徑之後會被抓取請求沿用（TD-02：抓取是 request → host 驗證 → 廣播）。
	_request_register.rpc_id(1, local_display_name, local_device_id)


## 有人離線時把位置交還給 AI，而不是把角色收掉。
## 隊伍維持三個人，剩下的玩家不會突然少一個隊友（docs/11 AI 補位）。
func _on_peer_left(peer_id: int) -> void:
	if not NetworkService.is_host():
		return
	var changed := false
	for slot in slots:
		if slot.peer_id != peer_id:
			continue
		slot.peer_id = NetworkService.local_peer_id()
		slot.device_id = -1
		slot.is_ai = true
		slot.display_name = "AI-%d" % slot.slot_id
		changed = true
	if changed:
		_broadcast()


func _on_disconnected() -> void:
	slots.clear()
	slots_changed.emit()


## 真人加入時優先接手 AI 的位置——只換 peer_id 與 is_ai 兩個欄位，
## 角色的位置、血量、手上拿的東西全部原封不動（TD-04）。
func _first_ai_slot() -> PlayerSlot:
	for slot in slots:
		if slot.is_ai:
			return slot
	return null


func _host_claim_slot(peer_id: int, display_name: String, device_id: int) -> bool:
	var taken := _first_ai_slot()
	if taken != null:
		taken.peer_id = peer_id
		taken.device_id = device_id
		taken.is_ai = false
		taken.display_name = display_name
		_broadcast()
		return true

	var slot_id := free_slot_id()
	if slot_id < 0:
		push_warning("[Registry] 隊伍已滿，拒絕 peer %d" % peer_id)
		return false
	var slot := PlayerSlot.new(slot_id, peer_id, device_id)
	slot.display_name = display_name
	slots.append(slot)
	slots.sort_custom(_by_slot_id)
	_broadcast()
	return true


func _by_slot_id(a: PlayerSlot, b: PlayerSlot) -> bool:
	return a.slot_id < b.slot_id


func _broadcast() -> void:
	var payload: Array = []
	for slot in slots:
		payload.append(slot.to_dict())
	_receive_slots.rpc(payload)


# --- RPC --------------------------------------------------------------------

## 客戶端 → host。host 是唯一能決定 slot 歸屬的人。
@rpc("any_peer", "reliable")
func _request_register(display_name: String, device_id: int) -> void:
	if not NetworkService.is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not slots_for_peer(sender).is_empty():
		return  # 重複報到，忽略
	if not _host_claim_slot(sender, display_name, device_id):
		_reject.rpc_id(sender, "隊伍已滿（上限 %d 人）" % PlayerSlot.MAX_SLOTS)


## host → 全體。call_local 讓 host 自己也走同一條路徑，避免兩套邏輯。
@rpc("authority", "call_local", "reliable")
func _receive_slots(payload: Array) -> void:
	var rebuilt: Array[PlayerSlot] = []
	for entry in payload:
		rebuilt.append(PlayerSlot.from_dict(entry))
	slots = rebuilt
	slots_changed.emit()


@rpc("authority", "reliable")
func _reject(reason: String) -> void:
	push_warning("[Registry] 被 host 拒絕：%s" % reason)
	NetworkService.last_error = reason
	NetworkService.call_deferred("leave")
