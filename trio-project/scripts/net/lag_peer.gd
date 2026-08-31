class_name LagPeer
extends MultiplayerPeerExtension

## 在真的 peer 外面包一層，注入延遲與丟包（TD-10）。
##
## 為什麼要自己寫：TD-10 規定 M0 的驗收必須在 80–150 ms 延遲加 1% 丟包下重跑，
## 而 Godot 4.7 沒有內建的網路模擬（ProjectSettings 與 ENetConnection 都查過）。
## TD-10 提到的 clumsy／tc netem 要每台測試機各自安裝設定——朋友幫你測的時候
## 不會想弄那個，結果就是永遠只有區網成績。
##
## 「區網測試幾乎一定會過，然後上市炸掉」是 TD-10 的原話。這一層就是為了
## 讓那句話不要成真。
##
## 做法：收進來的封包不直接交出去，壓上「可以放行的時間」丟進佇列，
## _poll() 時才把到期的搬進待領區。送出去的不延遲——單邊延遲兩次就是來回延遲，
## 收端做一次就夠，兩邊都做會變成設定值的兩倍。

## 只丟不可靠的封包。
##
## reliable 的封包 ENet 自己會重送，我們在這裡丟掉它，測到的是「重送機制有沒有
## 壞掉」，不是「遊戲在丟包下好不好玩」——那會得到假的結論。真實網路丟包時，
## reliable 的資料最後還是會到，只是晚一點。
const DROPPABLE := [
	MultiplayerPeer.TRANSFER_MODE_UNRELIABLE,
	MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED,
]

var base: MultiplayerPeer = null

## 單邊延遲（毫秒）。來回大約是這個值的兩倍。
var latency_ms: float = 0.0

## 抖動（毫秒）。固定延遲比真實網路好對付太多——沒有抖動的話，
## 客戶端的預測會學會一個穩定的偏移量，測不出真實的難度。
var jitter_ms: float = 0.0

## 丟包率 0.0–1.0。
var loss: float = 0.0

## 每條通道最後一次放行的時間，用來保住先進先出。
var _last_due: Dictionary = {}

var _queued: Array[Dictionary] = []
var _ready_packets: Array[Dictionary] = []
var _current: Dictionary = {}


func configure(peer: MultiplayerPeer, latency: float, packet_loss: float) -> void:
	base = peer
	latency_ms = latency
	jitter_ms = latency * 0.25
	loss = packet_loss
	# peer_connected / peer_disconnected 是 peer **自己**發的訊號，不是靠封包傳的。
	# MultiplayerAPI 監聽的是被指派給它的那個 peer——也就是這一層。底層的訊號
	# 不轉出來的話，上層永遠不知道有人連進來，症狀是
	# 「Attempt to call RPC with unknown peer ID: 1」。踩過，而且很難從封包那邊看出來。
	base.peer_connected.connect(func(id: int): peer_connected.emit(id))
	base.peer_disconnected.connect(func(id: int): peer_disconnected.emit(id))


# --- 收：延遲與丟包都發生在這一側 -------------------------------------------


func _poll() -> void:
	if base == null:
		return
	base.poll()

	while base.get_available_packet_count() > 0:
		# 順序要命：get_packet() 會把封包從佇列彈出去，之後再問 peer / channel
		# 就是在空佇列上讀，拿到的是垃圾。症狀是 host 端一直噴
		# 「!connected_peers.has(sender)」，封包全部路由到不存在的 peer。
		# 所以中繼資料一律先讀完，最後才取資料。
		var mode := base.get_packet_mode()
		var from := base.get_packet_peer()
		var channel := base.get_packet_channel()
		var entry := {
			"data": base.get_packet(),
			"peer": from,
			"channel": channel,
			"mode": mode,
		}
		if loss > 0.0 and DROPPABLE.has(mode) and randf() < loss:
			continue
		# 抖動會讓後送的封包比先送的早到期——也就是亂序。ENet 的 reliable 通道
		# 保證順序，破壞它測到的是假問題：實測未加這道保護時，客戶端在 80 ms
		# 之下會噴「ID 1 not found in cache of peer 1」，因為同步封包跑到了
		# 生成封包前面。那是模擬器的錯，不是遊戲的錯。
		#
		# 所以每條通道的放行時間單調不遞減：抖動照加，但不准插隊。
		# 代價是不模擬「純 unreliable 的亂序」——那是比較少見的真實狀況，
		# 而且會製造大量假警報。
		var key := "%d:%d" % [from, channel]
		var due := _now() + maxf(latency_ms + randf_range(-jitter_ms, jitter_ms), 0.0)
		due = maxf(due, float(_last_due.get(key, 0.0)))
		_last_due[key] = due
		entry["due"] = due
		_queued.append(entry)

	var now := _now()
	var still_waiting: Array[Dictionary] = []
	for item in _queued:
		if float(item["due"]) <= now:
			_ready_packets.append(item)
		else:
			still_waiting.append(item)
	_queued = still_waiting


func _get_available_packet_count() -> int:
	return _ready_packets.size()


## get_packet_peer / channel / mode 的合約是**下一個要讀的封包**，不是剛讀完的。
## 引擎會先問 peer 再呼叫 get_packet，順序反了就會路由錯，症狀是
## 「Attempt to call RPC with unknown peer ID: 1」，連線建不起來。踩過。
func _peek() -> Dictionary:
	return _ready_packets[0] if not _ready_packets.is_empty() else _current


func _get_packet_script() -> PackedByteArray:
	if _ready_packets.is_empty():
		return PackedByteArray()
	_current = _ready_packets.pop_front()
	return _current["data"]


func _get_packet_peer() -> int:
	return int(_peek().get("peer", 0))


func _get_packet_channel() -> int:
	return int(_peek().get("channel", 0))


func _get_packet_mode() -> int:
	return int(_peek().get("mode", MultiplayerPeer.TRANSFER_MODE_RELIABLE))


func _get_max_packet_size() -> int:
	return base.get_max_packet_size() if base != null else 0


# --- 送：原樣轉出去，延遲只在收端做一次 --------------------------------------


func _put_packet_script(buffer: PackedByteArray) -> Error:
	if base == null:
		return ERR_UNCONFIGURED
	return base.put_packet(buffer)


func _set_target_peer(peer: int) -> void:
	if base != null:
		base.set_target_peer(peer)


func _set_transfer_channel(channel: int) -> void:
	if base != null:
		base.set_transfer_channel(channel)


func _get_transfer_channel() -> int:
	return base.get_transfer_channel() if base != null else 0


func _set_transfer_mode(mode: int) -> void:
	if base != null:
		base.set_transfer_mode(mode)


func _get_transfer_mode() -> int:
	return base.get_transfer_mode() if base != null else 0


# --- 其餘一律轉給被包住的 peer ------------------------------------------------


func _get_unique_id() -> int:
	return base.get_unique_id() if base != null else 0


func _is_server() -> bool:
	return base.is_server() if base != null else false


func _is_server_relay_supported() -> bool:
	return base.is_server_relay_supported() if base != null else false


func _get_connection_status() -> int:
	if base == null:
		return MultiplayerPeer.CONNECTION_DISCONNECTED
	return base.get_connection_status()


func _disconnect_peer(peer: int, force: bool) -> void:
	if base != null:
		base.disconnect_peer(peer, force)


func _set_refuse_new_connections(enable: bool) -> void:
	if base != null:
		base.refuse_new_connections = enable


func _is_refusing_new_connections() -> bool:
	return base.refuse_new_connections if base != null else false


func _close() -> void:
	_last_due.clear()
	_queued.clear()
	_ready_packets.clear()
	if base != null:
		base.close()


func _now() -> float:
	return Time.get_ticks_msec()
