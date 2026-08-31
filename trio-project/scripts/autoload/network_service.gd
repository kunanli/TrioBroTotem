extends Node

## TD-03：所有 MultiplayerPeer 的建立與銷毀都收在這個檔案裡。
##
## 遊戲的其他部分只呼叫 host_game() / join_game() / leave()，
## 絕不直接碰 multiplayer.multiplayer_peer。
##
## 上市前要換成 Steam 的 P2P / relay（裸 ENet 在雙層 NAT、CGNAT 下
## 連線失敗率不可接受，那會直接變成退款）。屆時只需要改
## _create_server_peer() 與 _create_client_peer() 兩個函式。
##
## 見 docs/13-tech-decisions.md TD-03。

signal hosted()
signal joined()
signal join_failed(reason: String)
signal disconnected()
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)

enum Mode { OFFLINE, HOST, CLIENT }

const DEFAULT_PORT := 27015
const DEFAULT_ADDRESS := "127.0.0.1"

## ENet 的連線上限。實際可玩人數由 PlayerSlot.MAX_SLOTS 決定，
## 這裡留餘裕是為了讓第四個人連得進來、再被明確拒絕，而不是連線逾時。
const MAX_CLIENTS := 7

var mode: Mode = Mode.OFFLINE
var last_error: String = ""

## 網路模擬設定（TD-10）。0 = 關閉。開房／加入的當下生效，中途改不會影響
## 已經建立的連線——那需要重連，而測試中途換條件本來就會讓結果沒有意義。
var sim_latency_ms: float = 0.0
var sim_loss: float = 0.0


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


# --- 對外介面 ---------------------------------------------------------------

func host_game(port: int = DEFAULT_PORT) -> bool:
	leave()
	var peer := _create_server_peer(port)
	if peer == null:
		return false
	multiplayer.multiplayer_peer = _wrap_simulation(peer)
	mode = Mode.HOST
	print("[Net] 開伺服器於 port %d，本機 peer_id = %d" % [port, local_peer_id()])
	hosted.emit()
	return true


func join_game(address: String = DEFAULT_ADDRESS, port: int = DEFAULT_PORT) -> bool:
	leave()
	var peer := _create_client_peer(address, port)
	if peer == null:
		return false
	multiplayer.multiplayer_peer = _wrap_simulation(peer)
	mode = Mode.CLIENT
	print("[Net] 連線至 %s:%d ..." % [address, port])
	return true


func leave() -> void:
	if mode == Mode.OFFLINE:
		return
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	mode = Mode.OFFLINE
	print("[Net] 已離線")
	disconnected.emit()


## 模擬開著就包一層 LagPeer，否則原樣回傳。
##
## 兩端都要包：延遲只在收端做，所以 host 包一層負責「host 收到客戶端的封包」，
## 客戶端包一層負責「客戶端收到 host 的封包」，加起來才是完整的來回延遲。
func _wrap_simulation(peer: MultiplayerPeer) -> MultiplayerPeer:
	if sim_latency_ms <= 0.0 and sim_loss <= 0.0:
		return peer
	var wrapper := LagPeer.new()
	wrapper.configure(peer, sim_latency_ms, sim_loss)
	print("[Net] 網路模擬：延遲 %.0f ms、丟包 %.1f%%" % [sim_latency_ms, sim_loss * 100.0])
	return wrapper


## 目前模擬設定的一行描述，給大廳顯示用。關閉時回空字串。
func simulation_label() -> String:
	if sim_latency_ms <= 0.0 and sim_loss <= 0.0:
		return ""
	return "%.0f ms latency, %.1f%% loss" % [sim_latency_ms, sim_loss * 100.0]


func is_online() -> bool:
	return mode != Mode.OFFLINE


## 這台機器在區網裡的位址，給 host 唸給朋友聽。
##
## 沒有這個的話，開房之後畫面上沒有任何地方寫著「連這裡」——測試當下最常見的
## 卡關就是「所以我要連什麼」。過濾掉 127.x 與 IPv6，只留看起來像區網的位址。
func local_addresses() -> PackedStringArray:
	var out := PackedStringArray()
	for entry in IP.get_local_addresses():
		var address: String = entry
		if address.contains(":") or address.begins_with("127."):
			continue
		if (
			address.begins_with("192.168.")
			or address.begins_with("10.")
			or address.begins_with("172.")
		):
			out.append(address)
	return out


func is_host() -> bool:
	return mode == Mode.HOST


## 這一端該不該模擬場景物理。host 與單機為 true，客戶端為 false。
##
## 與 is_host() 分開是因為時機問題：場景物件在主場景載入時就 _ready 了，
## 那時還沒開房，is_host() 還是 false。物件若在 _ready 當下就決定要不要凍結，
## 開房後 host 的箱子會全部卡住不動。
func simulates_world() -> bool:
	return mode != Mode.CLIENT


func local_peer_id() -> int:
	if multiplayer.multiplayer_peer == null:
		return 1
	return multiplayer.get_unique_id()


# --- 傳輸層（換 Steam 時只動這兩個函式）--------------------------------------

func _create_server_peer(port: int) -> MultiplayerPeer:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		last_error = "Could not host on port %d (error %d)" % [port, err]
		push_error(last_error)
		join_failed.emit(last_error)
		return null
	return peer


func _create_client_peer(address: String, port: int) -> MultiplayerPeer:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		last_error = "Could not reach %s:%d (error %d)" % [address, port, err]
		push_error(last_error)
		join_failed.emit(last_error)
		return null
	return peer


# --- 訊號轉發 ---------------------------------------------------------------

func _on_peer_connected(peer_id: int) -> void:
	print("[Net] peer %d 進來了" % peer_id)
	peer_joined.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	print("[Net] peer %d 離開了" % peer_id)
	peer_left.emit(peer_id)


func _on_connected_to_server() -> void:
	print("[Net] 連線成功，本機 peer_id = %d" % local_peer_id())
	joined.emit()


func _on_connection_failed() -> void:
	last_error = "Connection failed - nobody is hosting there, or a firewall blocked it"
	push_warning(last_error)
	multiplayer.multiplayer_peer = null
	mode = Mode.OFFLINE
	join_failed.emit(last_error)


func _on_server_disconnected() -> void:
	last_error = "Disconnected from the host"
	push_warning(last_error)
	multiplayer.multiplayer_peer = null
	mode = Mode.OFFLINE
	disconnected.emit()
