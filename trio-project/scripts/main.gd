extends Node3D

## M0 的進入點。負責：把名冊（PlayerRegistry）的內容變成場上的角色。
##
## 生成一律由 host 發動（TD-02）。客戶端不自行生成任何角色，
## MultiplayerSpawner 會把 host 的生成結果複製過去，
## 也會在新玩家連進來時補上已存在的角色。

const PLAYER_SCENE := preload("res://scenes/player/player.tscn")

## M0 的三個出生點，之後由關卡資料提供。
const SPAWN_POINTS: Array[Vector3] = [
	Vector3(-2.5, 1.2, 0.0),
	Vector3(0.0, 1.2, 0.0),
	Vector3(2.5, 1.2, 0.0),
]

@onready var _players_root: Node3D = $Players
@onready var _spawner: MultiplayerSpawner = $PlayerSpawner


func _ready() -> void:
	_spawner.spawn_function = _spawn_player
	PlayerRegistry.slots_changed.connect(_on_slots_changed)
	NetworkService.disconnected.connect(_clear_players)
	_apply_cmdline()


## 讓「開三個實例」不用每次都手動點按鈕：
##   godot --path . -- --host
##   godot --path . -- --join=127.0.0.1
func _apply_cmdline() -> void:
	for arg in OS.get_cmdline_user_args():
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

	var spawn_position: Vector3 = SPAWN_POINTS[slot.slot_id % SPAWN_POINTS.size()]
	player.position = spawn_position
	player.net_position = spawn_position
	return player
