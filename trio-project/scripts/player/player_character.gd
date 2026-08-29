class_name PlayerCharacter
extends CharacterBody3D

## M0 的膠囊角色。零美術、零動畫、零 shader（TD-09）。
##
## 權威模型（TD-02）：自己的角色由自己的 client 說了算。
## 權威端跑輸入與物理，把結果寫進 net_* 變數；
## MultiplayerSynchronizer 把 net_* 送給其他人，其他人只做插值。
##
## 之後要加的抓取、投擲、疊高全部是 host 權威，不會走這條路徑。

const SPEED := 5.5
const ACCELERATION := 14.0
const JUMP_VELOCITY := 5.2
const TURN_SPEED := 14.0

## 同步頻率。物理跑 60Hz，網路送 30Hz——M0 要調的就是這個數字。
const SYNC_HZ := 30.0

## 遠端角色追向 net_position 的速度。太低會拖影，太高會抖。
const REMOTE_LERP := 18.0

## 差距超過這個距離就直接瞬移。延遲尖峰後若只靠 lerp 會滑行很久。
const TELEPORT_DISTANCE := 3.0

const SLOT_COLORS := [
	Color(0.90, 0.42, 0.32),  # 0 泥土色
	Color(0.36, 0.76, 0.48),  # 1 水草色
	Color(0.38, 0.58, 0.95),  # 2 天空色
]

var slot_id: int = -1
var owner_peer_id: int = 1
var device_id: int = -1
var is_ai: bool = false
var display_name: String = ""

# --- 被複製的狀態（權威端寫，其他人讀）---
var net_position: Vector3 = Vector3.ZERO
var net_velocity: Vector3 = Vector3.ZERO
var net_yaw: float = 0.0

var _yaw: float = 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

@onready var _visual: Node3D = $Visual
@onready var _label: Label3D = $NameLabel
@onready var _camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D


func _ready() -> void:
	_setup_synchronizer()
	# 權威要在 synchronizer 建好之後才設，才會遞迴傳給它。
	set_multiplayer_authority(owner_peer_id)

	_label.text = display_name if not display_name.is_empty() else "Slot %d" % slot_id
	var material := StandardMaterial3D.new()
	if slot_id >= 0:
		material.albedo_color = SLOT_COLORS[slot_id % SLOT_COLORS.size()]
	else:
		material.albedo_color = Color.WEBGRAY
	for mesh in _visual.find_children("*", "MeshInstance3D"):
		mesh.material_override = material

	# M0 一個 peer 只負責一個 slot，所以這樣就夠。
	# 本地分屏（TD-04）時要改成每個 slot 一個 SubViewport，不是靠 current。
	_camera.current = is_multiplayer_authority() and not is_ai

	if is_multiplayer_authority():
		net_position = global_position
		net_yaw = _yaw


## 複製設定用程式碼建，不寫進 .tscn。
## SceneReplicationConfig 的文字格式很容易寫錯，而且這裡寫成程式碼
## 剛好把「M0 要調的三個數字」擺在同一個畫面上。
func _setup_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	for property in [".:net_position", ".:net_velocity", ".:net_yaw"]:
		var path := NodePath(property)
		config.add_property(path)
		# 初始值由 spawn 資料帶，不靠 spawn 封包，避免相依於 spawner 的送出時機。
		config.property_set_spawn(path, false)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)

	var sync := MultiplayerSynchronizer.new()
	sync.name = "Synchronizer"
	sync.replication_config = config
	sync.replication_interval = 1.0 / SYNC_HZ
	add_child(sync)


func _physics_process(delta: float) -> void:
	if is_multiplayer_authority():
		_process_authority(delta)
	else:
		_process_remote(delta)
	_visual.rotation.y = _yaw


func _process_authority(delta: float) -> void:
	# 每一幀都問，不能只在著地時問——手把的 just_pressed 是自己做的邊緣偵測，
	# 漏問幾幀狀態就會過期，導致「握著跳鍵落地後跳不起來」。
	var jump_pressed := GameInput.is_jump_pressed(device_id)
	if not is_on_floor():
		velocity.y -= _gravity * delta
	elif jump_pressed:
		velocity.y = JUMP_VELOCITY

	var input := GameInput.get_move_vector(device_id)
	# M0 的鏡頭方向固定，所以直接用世界座標。
	# 鏡頭規則尚未定案（見 docs/08-multiplayer-camp.md 鏡頭規則），
	# 定案前不做鏡頭相對移動，免得改兩次。
	var wish := Vector3(input.x, 0.0, input.y)
	if wish.length() > 1.0:
		wish = wish.normalized()

	var target := wish * SPEED
	velocity.x = move_toward(velocity.x, target.x, ACCELERATION * delta)
	velocity.z = move_toward(velocity.z, target.z, ACCELERATION * delta)
	move_and_slide()

	if wish.length_squared() > 0.01:
		_yaw = lerp_angle(_yaw, atan2(-wish.x, -wish.z), TURN_SPEED * delta)

	net_position = global_position
	net_velocity = velocity
	net_yaw = _yaw


func _process_remote(delta: float) -> void:
	if global_position.distance_to(net_position) > TELEPORT_DISTANCE:
		global_position = net_position
	else:
		var weight := clampf(REMOTE_LERP * delta, 0.0, 1.0)
		global_position = global_position.lerp(net_position, weight)
	velocity = net_velocity
	_yaw = lerp_angle(_yaw, net_yaw, clampf(REMOTE_LERP * delta, 0.0, 1.0))
