extends Node3D

## M0 的進入點。負責：把名冊（PlayerRegistry）的內容變成場上的角色。
##
## 生成一律由 host 發動（TD-02）。客戶端不自行生成任何角色，
## MultiplayerSpawner 會把 host 的生成結果複製過去，
## 也會在新玩家連進來時補上已存在的角色。

const PLAYER_SCENE := preload("res://scenes/player/player.tscn")

## 關卡沒有提供出生點時的退路。正常情況下由關卡的 SpawnPoints 決定——
## 第一章是線性的，出生點放錯邊會直接跳過第一個關卡（藤蔓牆），
## 而且沒有任何錯誤訊息，只會覺得「這關怎麼沒作用」。
const SPAWN_POINTS: Array[Vector3] = [
	Vector3(-2.5, 1.2, 0.0),
	Vector3(0.0, 1.2, 0.0),
	Vector3(2.5, 1.2, 0.0),
]

@onready var _world: Node3D = $World
@onready var _players_root: Node3D = $Players
@onready var _spawner: MultiplayerSpawner = $PlayerSpawner


func _ready() -> void:
	_spawner.spawn_function = _spawn_player
	PlayerRegistry.slots_changed.connect(_on_slots_changed)
	NetworkService.disconnected.connect(_clear_players)
	GameFlow.phase_changed.connect(_on_phase_changed)
	_apply_cmdline()


## 換世界。**只換 World 底下的子樹，不換整個場景**——理由見 game_flow.gd：
## change_scene_to_file 會連 Players 與 MultiplayerSpawner 一起銷毀，
## 而 CombatSystem 傳的是節點路徑字串，那些路徑會全部失效。
##
## 每一端各自載入同一個場景檔，所以節點路徑在三台機器上是一樣的——
## 這是「只廣播階段、不同步世界內容」能成立的前提。
func _on_phase_changed(phase: int) -> void:
	for child in _world.get_children():
		# 先 remove 再 free：queue_free 是延後的，不先移出去的話
		# 新舊兩個世界會在同一幀共存，物理與出生點都會讀到舊的那一份。
		_world.remove_child(child)
		child.queue_free()
	var path := GameFlow.world_path(phase)
	if path.is_empty():
		# 開始畫面沒有世界，也就沒有出生點可以搬過去。
		return
	var scene: PackedScene = load(path)
	_world.add_child(scene.instantiate())
	_place_players()


## 換世界之後把角色搬到新世界的出生點。
##
## 每一端只搬自己有權威的那些——host 去寫客戶端角色的位置沒有用，
## 下一個同步封包就會被 net_position 蓋回去。
func _place_players() -> void:
	# 沒有 peer 就直接算了。host 中離時 NetworkService 會先把
	# multiplayer_peer 設成 null 再送 disconnected，於是 GameFlow 切回 Title，
	# 一路走到這裡——而 is_multiplayer_authority() 在沒有 peer 的情況下
	# 是硬錯誤（"No multiplayer peer is assigned"），每個角色噴一次。
	if multiplayer.multiplayer_peer == null:
		return
	for child in _players_root.get_children():
		var player: PlayerCharacter = child
		if player.is_multiplayer_authority():
			player.teleport_to(_spawn_point(player.slot_id))


## 讓多開不用每次都手動點按鈕：
##   godot --path . -- --host
##   godot --path . -- --join=127.0.0.1
##
## 兩份參數清單都掃：user_args 只有 `--` 之後的東西，但編輯器的
## 「Customize Run Instances」把 Launch Arguments 直接接在命令列上，
## 不一定會加那個分隔符——只認一種的話，在編輯器裡設了參數卻沒反應，
## 而且不會有任何錯誤訊息。
func _apply_cmdline() -> void:
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	# 分兩趟：網路模擬一定要在開房／加入之前設好，否則包不到那一層。
	# 同一趟處理的話，--host --lag=80 這種順序會讓模擬完全沒生效，
	# 而且不會有任何錯誤訊息——測出來的是假的區網成績。
	for arg in args:
		if arg.begins_with("--lag="):
			NetworkService.sim_latency_ms = float(arg.split("=", true, 1)[1])
		elif arg.begins_with("--loss="):
			NetworkService.sim_loss = float(arg.split("=", true, 1)[1])

	for arg in args:
		if arg == "--host":
			NetworkService.host_game()
			return
		if arg.begins_with("--join"):
			var address := NetworkService.DEFAULT_ADDRESS
			if arg.contains("="):
				address = arg.split("=", true, 1)[1]
			NetworkService.join_game(address)
			return


func _on_slots_changed() -> void:
	# 接手／交還 AI 只是換欄位，每一端都要照做，這樣三邊算出來的
	# 權威歸屬才一致。生成與回收仍然只有 host 動。
	_sync_existing()
	if NetworkService.is_host():
		_reconcile_players()


func _sync_existing() -> void:
	for slot in PlayerRegistry.slots:
		var player := _find_player(slot.slot_id)
		if player != null:
			player.reassign(slot.peer_id, slot.is_ai, slot.display_name)


func _reconcile_players() -> void:
	var wanted := {}
	for slot in PlayerRegistry.slots:
		wanted[slot.slot_id] = slot

	for child in _players_root.get_children():
		if not wanted.has(child.slot_id):
			child.queue_free()

	for slot_id in wanted:
		if _find_player(slot_id) == null:
			_spawner.spawn(wanted[slot_id].to_dict())


func _find_player(slot_id: int) -> PlayerCharacter:
	for child in _players_root.get_children():
		if child is PlayerCharacter and child.slot_id == slot_id:
			return child
	return null


func _clear_players() -> void:
	for child in _players_root.get_children():
		child.queue_free()


## 這個函式在每一台機器上都會跑（host 生成時、客戶端收到複製時）。
## 因此節點名與初始位置必須是資料的純函式，不能依賴本機狀態。
func _spawn_player(data: Variant) -> Node:
	var slot := PlayerSlot.from_dict(data)
	var player: PlayerCharacter = PLAYER_SCENE.instantiate()
	player.name = "Player%d" % slot.slot_id
	player.slot_id = slot.slot_id
	player.owner_peer_id = slot.peer_id
	player.device_id = slot.device_id
	player.is_ai = slot.is_ai
	player.display_name = slot.display_name

	var spawn_position := _spawn_point(slot.slot_id)
	player.position = spawn_position
	player.net_position = spawn_position
	player.spawn_position = spawn_position
	return player


## 關卡自己說要從哪裡開始。場景在每一端都一樣，所以這仍然是資料的純函式
## （見 _spawn_player 的註解）。
func _spawn_point(slot_id: int) -> Vector3:
	var markers := get_tree().get_nodes_in_group("spawn_points")
	if not markers.is_empty():
		markers.sort_custom(func(a: Node, b: Node) -> bool: return a.name < b.name)
		var marker: Node3D = markers[slot_id % markers.size()]
		return marker.global_position
	return SPAWN_POINTS[slot_id % SPAWN_POINTS.size()]
