class_name Prop
extends RigidBody3D

## 場景中的可搬物件。host 權威（TD-02）：只有 host 跑物理，
## 客戶端凍結成 kinematic 並插值跟隨，避免兩端各自模擬導致位置分歧。

const SYNC_HZ := 20.0
const REMOTE_LERP := 14.0
const TELEPORT_DISTANCE := 2.0

## 這個物件在重量階梯上的位置（WeightLadder）。決定誰抓得動它。
@export var carry_weight: float = WeightLadder.CRATE

var net_position: Vector3 = Vector3.ZERO
var net_rotation: Vector3 = Vector3.ZERO

## 被場景結構固定住了（例如原木卡進橋的插槽）。
##
## 一定要有這個旗標，不能讓固定它的人直接寫 freeze——下面每幀都會依連線身分
## 重算 freeze，外面設的值撐不過一幀。橋因此只有在客戶端成立，host 那端
## 原木會馬上掉回去，而且不會有任何錯誤訊息。
var pinned: bool = false


func _ready() -> void:
	add_to_group("props")
	var carryable := get_node_or_null("Carryable") as Carryable
	if carryable != null:
		carryable.weight = carry_weight
	_setup_synchronizer()
	set_multiplayer_authority(1)
	net_position = global_position
	net_rotation = global_rotation
	# 被抓著時要能推開別的東西，所以凍結型態一律用 KINEMATIC。
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC


func _setup_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	for property in [".:net_position", ".:net_rotation"]:
		var path := NodePath(property)
		config.add_property(path)
		config.property_set_spawn(path, false)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	var sync := MultiplayerSynchronizer.new()
	sync.name = "Synchronizer"
	sync.replication_config = config
	sync.replication_interval = 1.0 / SYNC_HZ
	add_child(sync)


func _physics_process(delta: float) -> void:
	var simulating := NetworkService.simulates_world()
	var carryable := get_node_or_null("Carryable") as Carryable
	var held := carryable != null and carryable.is_held()

	# 凍結狀態每幀依連線身分重算。開房／加入是執行期才發生的事，
	# 在 _ready 決定一次會讓 host 的箱子永遠卡住。
	# 只在真的要改變時才寫入——重複設定同一個值會反覆重建物理狀態。
	var want_frozen := pinned or held or not simulating
	if freeze != want_frozen:
		freeze = want_frozen

	if simulating:
		net_position = global_position
		net_rotation = global_rotation
		return
	if held or pinned:
		return

	if global_position.distance_to(net_position) > TELEPORT_DISTANCE:
		global_position = net_position
	else:
		global_position = global_position.lerp(net_position, clampf(REMOTE_LERP * delta, 0.0, 1.0))
	global_rotation = net_rotation
