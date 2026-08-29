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

const DEFAULT_PORT := 27015
const DEFAULT_ADDRESS := "127.0.0.1"

## ENet 的連線上限。實際可玩人數由 PlayerSlot.MAX_SLOTS 決定，
## 這裡留餘裕是為了讓第四個人連得進來、再被明確拒絕，而不是連線逾時。
const MAX_CLIENTS := 7

enum Mode { OFFLINE, HOST, CLIENT }

var mode: Mode = Mode.OFFLINE
var last_error: String = ""


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
	multiplayer.multiplayer_peer = peer
	mode = Mode.HOST
	print("[Net] 開伺服器於 port %d，本機 peer_id = %d" % [port, local_peer_id()])
	hosted.emit()
	return true


func join_game(address: String = DEFAULT_ADDRESS, port: int = DEFAULT_PORT) -> bool:
	leave()
	var peer := _create_client_peer(address, port)
	if peer == null:
		return false
	multiplayer.multiplayer_peer = peer
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


func is_online() -> bool:
	return mode != Mode.OFFLINE


func is_host() -> bool:
	return mode == Mode.HOST


func local_peer_id() -> int:
	if multiplayer.multiplayer_peer == null:
		return 1
	return multiplayer.get_unique_id()


# --- 傳輸層（換 Steam 時只動這兩個函式）--------------------------------------

func _create_server_peer(port: int) -> MultiplayerPeer:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		last_error = "無法在 port %d 開伺服器（錯誤碼 %d）" % [port, err]
		push_error(last_error)
		join_failed.emit(last_error)
		return null
	return peer


func _create_client_peer(address: String, port: int) -> MultiplayerPeer:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		last_error = "無法連線至 %s:%d（錯誤碼 %d）" % [address, port, err]
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
	last_error = "連線失敗（對方沒開伺服器，或被防火牆擋住）"
	push_warning(last_error)
	multiplayer.multiplayer_peer = null
	mode = Mode.OFFLINE
	join_failed.emit(last_error)


func _on_server_disconnected() -> void:
	last_error = "與伺服器斷線"
	push_warning(last_error)
	multiplayer.multiplayer_peer = null
	mode = Mode.OFFLINE
	disconnected.emit()
