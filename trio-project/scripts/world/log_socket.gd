class_name LogSocket
extends Area3D

## 原木橋的插槽：把原木放進來就自動架成橋。
##
## 為什麼要用插槽而不是「自己把原木擺好」：原木是 RigidBody3D，放手就會滾。
## 要玩家把一根七公尺的木頭精準橫跨在斷崖上，是在考驗耐性不是考驗合作——
## 而這一段要教的是「兩個人一起搬東西」，不是「擺放技巧」。
##
## 所以只要放進插槽範圍就吸附定位。玩家的挑戰在「怎麼把它搬過來」，
## 搬到了就一定成功。
##
## host 權威（TD-02）：只有 host 判定，狀態同步。

signal bridged

const SYNC_HZ := 10.0

var is_bridged: bool = false

var _applied := false
var _log: Node3D = null


func _ready() -> void:
	add_to_group("log_sockets")
	_setup_synchronizer()
	set_multiplayer_authority(1)


func _setup_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	var path := NodePath(".:is_bridged")
	config.add_property(path)
	config.property_set_spawn(path, false)
	config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	var sync := MultiplayerSynchronizer.new()
	sync.name = "Synchronizer"
	sync.replication_config = config
	sync.replication_interval = 1.0 / SYNC_HZ
	add_child(sync)


func _physics_process(_delta: float) -> void:
	# 每一端都要套用架橋的結果——is_bridged 是同步欄位，
	# 客戶端讀到它變 true 就自己把橋擺好，不必額外的 RPC。
	if is_bridged and not _applied:
		_applied = true
		_place()
		bridged.emit()
		Sfx.play(&"stack", global_position, 0.8)
	if is_bridged or not NetworkService.is_host():
		return

	for body in get_overlapping_bodies():
		var carryable := body.get_node_or_null("Carryable") as Carryable
		if carryable == null or carryable.weight < WeightLadder.LOG:
			continue
		# 還被扛著就不算數——要放手才算架上去。
		if carryable.is_held():
			continue
		_log = body
		is_bridged = true
		return


## 把原木吸附到插槽的位置並固定住。
func _place() -> void:
	if _log == null:
		_log = _find_log()
	if _log == null:
		return
	var prop := _log as Prop
	if prop != null:
		# 先凍再擺。反過來的話中間會夾一次物理步進，原木的兩端本來就埋在
		# 岸裡，Jolt 會把它往上推出來——實測歪了 11 公分，橋面就多一道坎。
		#
		# pinned 與 freeze 兩個都要寫：freeze 讓「這一幀」就停住，
		# pinned 讓它撐過下一幀（Prop 每幀依連線身分重算 freeze）。
		prop.pinned = true
		prop.freeze = true
		prop.linear_velocity = Vector3.ZERO
		prop.angular_velocity = Vector3.ZERO
	_log.global_transform = global_transform
	if prop != null:
		prop.net_position = prop.global_position
		prop.net_rotation = prop.global_rotation
	# 架好的橋不能再被抓走——不然踩在上面的人會跟著橋一起被搬走。
	var carryable := _log.get_node_or_null("Carryable") as Carryable
	if carryable != null:
		carryable.locked = true


## 客戶端沒有 _log 的參照（判定在 host），自己找最近的那根。
func _find_log() -> Node3D:
	var best: Node3D = null
	var best_distance := INF
	for node in get_tree().get_nodes_in_group("props"):
		var prop: Node3D = node
		var carryable := prop.get_node_or_null("Carryable") as Carryable
		if carryable == null or carryable.weight < WeightLadder.LOG:
			continue
		var distance := global_position.distance_to(prop.global_position)
		if distance < best_distance:
			best_distance = distance
			best = prop
	return best
