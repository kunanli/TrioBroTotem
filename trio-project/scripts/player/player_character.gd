class_name PlayerCharacter
extends CharacterBody3D

## M0 的膠囊角色。零美術、零動畫、零 shader（TD-09）。
##
## 權威模型（TD-02）：自己的角色由自己的 client 說了算。
## 權威端跑輸入與物理，把結果寫進 net_* 變數；
## MultiplayerSynchronizer 把 net_* 送給其他人，其他人只做插值。
##
## 抓取與投擲**不走**這條路徑——那是 host 權威，見 CarrySystem。
## 這裡只負責「送出請求」與「被抓時不要自己亂動」。

const SPEED := 6.0
const JUMP_VELOCITY := 5.4

## 手感參數一律用「時間」而不是「加速度」表示——
## 「0.1 秒到全速」比「每秒 60 單位」好調得多，改速度時也不必連帶重算。
## 基準是 Overcooked：回饋速度優先，不要重量感（docs/05）。
const ACCEL_TIME := 0.10   ## 靜止到全速
const STOP_TIME := 0.07    ## 全速到靜止，比加速更快，急停才俐落
const TURN_TIME := 0.07    ## 轉向到位

## 空中還保有多少控制力。0 = 完全不能轉向，1 = 與地面相同。
## 太高的話被丟出去的人可以自己飛回來，投擲就沒意義了。
const AIR_CONTROL := 0.25

## 下墜時的重力倍率。上升慢、下墜快是跳躍手感的標準做法——
## 等速拋物線會讓角色在空中「飄」，與 Overcooked 基準相反。
const FALL_MULTIPLIER := 1.7

## 同步頻率。物理跑 60Hz，網路送 30Hz——M0 要調的就是這個數字。
const SYNC_HZ := 30.0

## 遠端角色追向 net_position 的速度。太低會拖影，太高會抖。
const REMOTE_LERP := 18.0

## 差距超過這個距離就直接瞬移。延遲尖峰後若只靠 lerp 會滑行很久。
const TELEPORT_DISTANCE := 3.0

## 投擲蓄力到滿所需的秒數。
const THROW_CHARGE_TIME := 0.8

## 掙扎到這個量就掙脫。被抓者狂推搖桿約兩秒。
const STRUGGLE_TO_BREAK := 2.4

## 扛著東西時的移動懲罰。扛人比扛箱子更明顯——這是喜劇來源，不是平衡數值。
const CARRY_SPEED_PENALTY := 0.7

## 鏡頭：距離、高度、看向角色身上多高的點。
const CAMERA_DISTANCE := 6.5
const CAMERA_HEIGHT := 3.0
const CAMERA_TARGET_HEIGHT := 1.2

## 鏡頭追上角色所需的時間。0 = 硬綁在身上（會很跳），太大會拖泥帶水。
const CAMERA_FOLLOW_TIME := 0.10

const MOUSE_SENSITIVITY := 0.005
const STICK_LOOK_SPEED := 2.5

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

## 重量即規則（docs/01）。抓取、疊高順序、擊退距離都讀這個值。
var weight: float = WeightLadder.PIG

## 正被誰扛著，-1 表示沒有。由 host 透過 CarrySystem 廣播寫入。
var carried_by_slot: int = -1

# --- 被複製的狀態（權威端寫，其他人讀）---
var net_position: Vector3 = Vector3.ZERO
var net_velocity: Vector3 = Vector3.ZERO
var net_yaw: float = 0.0

var _yaw: float = 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _throw_charge: float = 0.0
var _struggle: float = 0.0

## 鏡頭的水平角度。純本機狀態，不同步——每個人的鏡頭本來就該各自獨立。
var _camera_yaw: float = 0.0

@onready var carry_anchor: Node3D = $Visual/CarryAnchor
@onready var grab_probe: Area3D = $Visual/GrabProbe
@onready var _visual: Node3D = $Visual
@onready var _label: Label3D = $NameLabel
@onready var _camera: Camera3D = $Camera3D
@onready var _carryable: Carryable = $Carryable


func _ready() -> void:
	add_to_group("player_characters")
	weight = WeightLadder.for_slot(slot_id)
	_carryable.weight = weight

	_setup_synchronizer()
	# 權威要在 synchronizer 建好之後才設，才會遞迴傳給它。
	set_multiplayer_authority(owner_peer_id)

	_label.text = display_name if not display_name.is_empty() else "Slot %d" % slot_id
	var material := StandardMaterial3D.new()
	if slot_id >= 0:
		material.albedo_color = SLOT_COLORS[slot_id % SLOT_COLORS.size()]
	else:
		material.albedo_color = Color(0.6, 0.6, 0.6)
	for mesh in _visual.find_children("*", "MeshInstance3D"):
		mesh.material_override = material

	# M0 一個 peer 只負責一個 slot，所以這樣就夠。
	# 本地分屏（TD-04）時要改成每個 slot 一個 SubViewport，不是靠 current。
	_camera.current = is_multiplayer_authority() and not is_ai
	# 鏡頭脫離角色的座標系，改成自己平滑追上去。
	# 硬綁在角色身上時，角色每個物理幀的位移會原封不動變成鏡頭的抖動。
	_camera.top_level = true
	_camera.global_position = _camera_goal()
	_camera.look_at(_camera_focus(), Vector3.UP)

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


## 鏡頭看的目標點：角色身上稍高的位置，不是腳底。
func _camera_focus() -> Vector3:
	return global_position + Vector3.UP * CAMERA_TARGET_HEIGHT


## 鏡頭應該在的位置：以 _camera_yaw 繞著角色轉。
func _camera_goal() -> Vector3:
	var offset := Basis(Vector3.UP, _camera_yaw) * Vector3(0.0, CAMERA_HEIGHT, CAMERA_DISTANCE)
	return _camera_focus() + offset


## 鏡頭的水平基底。移動輸入要換算到這個座標系——
## 世界座標移動配上不會轉的鏡頭，在 3D 第三人稱裡一定會覺得怪。
func _camera_basis() -> Basis:
	return Basis(Vector3.UP, _camera_yaw)


func _input(event: InputEvent) -> void:
	if not _camera.current:
		return
	var motion := event as InputEventMouseMotion
	if motion == null:
		return
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		return
	_camera_yaw -= motion.relative.x * MOUSE_SENSITIVITY


func _process(delta: float) -> void:
	if not _camera.current:
		return
	_camera_yaw -= GameInput.get_look_delta(device_id) * STICK_LOOK_SPEED * delta
	# 指數平滑：不受影格率影響，60 與 144 fps 的追隨速度一致。
	var t := 1.0 - exp(-delta / CAMERA_FOLLOW_TIME)
	_camera.global_position = _camera.global_position.lerp(_camera_goal(), t)
	_camera.look_at(_camera_focus(), Vector3.UP)


## 面向的基底。投擲方向讀這個，不是讀 CharacterBody3D 的 transform——
## 本體不旋轉（旋轉會把鏡頭一起帶著轉），朝向只存在 Visual 上。
func facing_basis() -> Basis:
	return Basis(Vector3.UP, _yaw)


func facing_yaw() -> float:
	return _yaw


## 由 Carryable 呼叫，不要從別的地方寫。
func set_carried_by(holder_slot: int) -> void:
	carried_by_slot = holder_slot
	_struggle = 0.0
	if holder_slot >= 0:
		velocity = Vector3.ZERO


func apply_throw(release_velocity: Vector3) -> void:
	velocity = release_velocity


func is_carrying() -> bool:
	return CarrySystem.held_carryable(slot_id) != null


func _physics_process(delta: float) -> void:
	if carried_by_slot >= 0:
		_process_carried(delta)
	elif is_multiplayer_authority():
		_process_authority(delta)
	else:
		_process_remote(delta)
	_visual.rotation.y = _yaw


func _process_authority(delta: float) -> void:
	# 每一幀都問，不能只在著地時問——手把的 just_pressed 是自己做的邊緣偵測，
	# 漏問幾幀狀態就會過期，導致「握著跳鍵落地後跳不起來」。
	var jump_pressed := GameInput.is_jump_pressed(device_id)
	if is_on_floor():
		# 著地時一定要歸零。原本只在跳躍時才寫 velocity.y，
		# 落地後那個很大的負值會一直留著——走下平台的瞬間會像被吸下去。
		velocity.y = JUMP_VELOCITY if jump_pressed else 0.0
	else:
		velocity.y -= _gravity * (FALL_MULTIPLIER if velocity.y < 0.0 else 1.0) * delta

	var input := GameInput.get_move_vector(device_id)
	var wish := _camera_basis() * Vector3(input.x, 0.0, input.y)
	if wish.length() > 1.0:
		wish = wish.normalized()

	var speed := SPEED * (CARRY_SPEED_PENALTY if is_carrying() else 1.0)
	var moving := wish.length_squared() > 0.01
	# 水平速度整個向量一起算，不要拆成 x 與 z 各自 move_toward——
	# 分軸處理會讓斜向的加速度比正向快 √2 倍，轉向時也會有稜有角。
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var rate := speed / (ACCEL_TIME if moving else STOP_TIME)
	if not is_on_floor():
		rate *= AIR_CONTROL
	horizontal = horizontal.move_toward(wish * speed, rate * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z
	move_and_slide()

	if moving:
		_yaw = lerp_angle(_yaw, atan2(-wish.x, -wish.z), 1.0 - exp(-delta / TURN_TIME))

	_process_carry_input(delta)

	net_position = global_position
	net_velocity = velocity
	net_yaw = _yaw


## 只送請求，不自己決定結果。目標查詢與重量驗證都在 host（TD-02）。
func _process_carry_input(delta: float) -> void:
	if GameInput.is_grab_pressed(device_id):
		if is_carrying():
			CarrySystem.request_drop.rpc_id(1, slot_id)
		else:
			CarrySystem.request_grab.rpc_id(1, slot_id)

	if not is_carrying():
		_throw_charge = 0.0
		return

	if GameInput.is_throw_held(device_id):
		_throw_charge = minf(_throw_charge + delta / THROW_CHARGE_TIME, 1.0)
	elif _throw_charge > 0.0:
		CarrySystem.request_throw.rpc_id(1, slot_id, _throw_charge)
		_throw_charge = 0.0


## 被扛著時位置由 Carryable 決定，這裡只做兩件事：面向持有者的方向、累積掙扎。
func _process_carried(delta: float) -> void:
	var holder := CarrySystem.find_player(carried_by_slot)
	if holder != null:
		_yaw = holder.facing_yaw()
	velocity = Vector3.ZERO
	net_position = global_position
	net_yaw = _yaw

	if not is_multiplayer_authority():
		return
	# 掙扎在被抓者自己這端累積，滿了才送一次請求——
	# 每幀送搖桿量會是 60 packets/s，一個人被抓就吃掉整條頻寬。
	var struggle_input := GameInput.get_move_vector(device_id).length()
	_struggle += struggle_input * delta
	if _struggle >= STRUGGLE_TO_BREAK:
		_struggle = 0.0
		CarrySystem.request_struggle_break.rpc_id(1, carried_by_slot)


func _process_remote(delta: float) -> void:
	if global_position.distance_to(net_position) > TELEPORT_DISTANCE:
		global_position = net_position
	else:
		var weight_factor := 1.0 - exp(-REMOTE_LERP * delta)
		global_position = global_position.lerp(net_position, weight_factor)
	velocity = net_velocity
	_yaw = lerp_angle(_yaw, net_yaw, 1.0 - exp(-REMOTE_LERP * delta))
