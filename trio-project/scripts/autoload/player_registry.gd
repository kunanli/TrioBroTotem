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


func _on_joined() -> void:
	# 客戶端連上後主動報到。host 不會自作主張替它取名或指定裝置。
	# 這條路徑之後會被抓取請求沿用（TD-02：抓取是 request → host 驗證 → 廣播）。
	_request_register.rpc_id(1, local_display_name, local_device_id)


func _on_peer_left(peer_id: int) -> void:
	if not NetworkService.is_host():
		return
	var kept: Array[PlayerSlot] = []
	for slot in slots:
		if slot.peer_id != peer_id:
			kept.append(slot)
	if kept.size() == slots.size():
		return
	slots = kept
	_broadcast()


func _on_disconnected() -> void:
	slots.clear()
	slots_changed.emit()


func _host_claim_slot(peer_id: int, display_name: String, device_id: int) -> bool:
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
