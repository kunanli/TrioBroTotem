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

## 攻擊中的移動懲罰。不完全鎖住，因為 Overcooked 基準要的是能一直動。
const ATTACK_MOVE_PENALTY := 0.35

## 落地速度低於這個值不受傷；超出的部分每 1 m/s 換算成多少傷害。
## 這是 M0 唯一的傷害來源——沒有它就驗不了倒地與救援。
## 落地聲的速度門檻。比 SAFE_FALL_SPEED 低很多——有聲音跟有傷害是兩回事。
const LAND_SOUND_SPEED := 3.0

const SAFE_FALL_SPEED := 11.0
const FALL_DAMAGE_PER_SPEED := 9.0

## 扶起隊友要按住多久（與 DownSystem.REVIVE_TIME 對齊）。
const REVIVE_RANGE := 2.2

## 頭部看向的偵測半徑。超過這個距離就不轉頭了——遠處的隊友不值得一直盯著。
const LOOK_RANGE := 9.0

## CombatSpec 的段名 → 生成動畫的片段名（TD-12）。
## 兩邊都由 CombatSpec 驅動，所以段的時間軸與動畫的時間軸是同一組數字。
const ATTACK_CLIPS := {
	&"light_1": &"attack1",
	&"light_2": &"attack2",
	&"heavy_3": &"attack3",
	&"dash": &"attack_dash",
	&"air": &"attack_air",
}

## 倒地時模型往前趴的角度。這是 ragdoll 的暫代表現——
## 真正的 PhysicalBone3D 是下一步，先把網路模型驗起來（TD-06）。
const DOWNED_PITCH := -80.0

## 疊高偵測的往下探測長度（從腳底往下），以及送出請求的最短間隔。
const STACK_PROBE_LENGTH := 0.5
const STACK_REQUEST_INTERVAL := 0.2

## --- 鏡頭 ---
## 距離與注視高度都用「角色身高的幾倍／幾成」表示，不用絕對值——
## 三隻身高差 1.4 到 1.7 公尺，固定值會讓矮的看起來特別遠、高的被切到頭。
##
## 覺得角色太小：把 CAMERA_DISTANCE_RATIO 調小（拉近），
## 或把 CAMERA_FOV 調小（縮視角，等於拉近但比較不犧牲看隊友的範圍）。
const CAMERA_DISTANCE_RATIO := 3.1
const CAMERA_TARGET_RATIO := 0.7

## 水平與垂直分開追隨，垂直**刻意慢很多**。
## 用同一個值的話，跳躍與走斜坡時鏡頭會跟著上下彈——那是最明顯的暈眩來源。
const CAMERA_FOLLOW_TIME := 0.09
const CAMERA_VERTICAL_TIME := 0.28

## 仰角範圍（弧度）。下限不設負太多，否則鏡頭會鑽到地板下面。
const CAMERA_PITCH_MIN := -0.10
const CAMERA_PITCH_MAX := 1.15
const CAMERA_PITCH_DEFAULT := 0.42

## 視野角度。Godot 預設 75 偏廣，主角會顯得小又遠。
const CAMERA_FOV := 62.0

const MOUSE_SENSITIVITY := 0.0032
const STICK_LOOK_SPEED := 2.6

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

## 這個 slot 演哪隻動物，以及牠的身高。碰撞體、鏡頭、攜帶錨點都依身高換算，
## 因為三隻的高度差很多（1.4 到 1.7 公尺）。
var character_id: StringName = &""
var character_height: float = 1.8

## 正被誰扛著，-1 表示沒有。由 host 透過 CarrySystem 廣播寫入。
var carried_by_slot: int = -1

## 正踩在誰頭上，-1 表示沒有。由 host 透過 StackSystem 廣播寫入。
var stacked_on: int = -1

## 是否倒地。由 host 透過 DownSystem 廣播寫入。
var is_downed: bool = false

## 由 main.gd 在生成時填。卡住重生（R）要回到這裡。
var spawn_position: Vector3 = Vector3.ZERO

# --- 被複製的狀態（權威端寫，其他人讀）---
var net_position: Vector3 = Vector3.ZERO
var net_velocity: Vector3 = Vector3.ZERO
var net_yaw: float = 0.0

var _yaw: float = 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _throw_charge: float = 0.0
var _struggle: float = 0.0
var _next_stack_request: float = 0.0
var _revive_progress: float = 0.0
var _previous_fall_speed: float = 0.0
var _ragdoll_rumble: float = 0.0
var _base_label: String = ""
var _intent := PlayerIntent.new()

## 鏡頭角度與追隨中的注視點。純本機狀態，不同步——每個人的鏡頭本來就該各自獨立。
var _camera_yaw: float = 0.0
var _camera_pitch: float = CAMERA_PITCH_DEFAULT
var _camera_anchor: Vector3 = Vector3.ZERO

## 鏡頭震的狀態。強度與經過時間分開存，時長才能與強度解耦（見 CombatSpec）。
## _shake_seed 讓每一下的相位不同，連擊時才不會每次都震出一模一樣的軌跡。
var _shake_peak: float = 0.0
var _shake_elapsed: float = CombatSpec.SHAKE_TIME
var _shake_seed: Vector2 = Vector2.ZERO

## 沿命中方向的一次性偏轉，已經換算成鏡頭空間的（右, 上）。
var _kick_screen: Vector2 = Vector2.ZERO
var _kick_elapsed: float = CombatSpec.KICK_TIME

@onready var carry_anchor: Node3D = $Visual/CarryAnchor
@onready var grab_probe: Area3D = $Visual/GrabProbe
@onready var stack_anchor: Node3D = $StackAnchor

@onready var _brain: AiBrain = $AiBrain
@onready var _attack: AttackController = $Visual/AttackController
@onready var _character: CharacterVisual = $Visual/Character
@onready var _collision: CollisionShape3D = $Collision
@onready var _visual: Node3D = $Visual
@onready var _label: Label3D = $NameLabel
@onready var _camera: Camera3D = $Camera3D
@onready var _carryable: Carryable = $Carryable


func _ready() -> void:
	add_to_group("player_characters")
	_setup_character()
	_attack.setup(self)
	_carryable.weight = weight

	_setup_synchronizer()
	# 權威要在 synchronizer 建好之後才設，才會遞迴傳給它。
	set_multiplayer_authority(owner_peer_id)

	_label.text = display_name if not display_name.is_empty() else "Slot %d" % slot_id
	_base_label = _label.text
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
	_camera.fov = CAMERA_FOV
	_camera_anchor = _focus_target()
	_place_camera()

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


## 由 Main 在名冊變動時呼叫。真人中途接手 AI 時只換這兩個欄位，
## 角色的位置、血量、手上拿的東西全部原封不動（TD-04）。
func reassign(peer_id: int, ai: bool, label: String) -> void:
	if owner_peer_id == peer_id and is_ai == ai and display_name == label:
		return
	owner_peer_id = peer_id
	is_ai = ai
	display_name = label
	_base_label = label
	set_multiplayer_authority(peer_id)
	_camera.current = is_multiplayer_authority() and not is_ai
	_intent.clear()


## 依角色身高調整碰撞體、鏡頭與攜帶錨點，再載入模型。
##
## 模型的原點在腳底，而角色本體的原點在膠囊中心，所以模型要往下移半個身高。
## 之所以不把本體原點改到腳底：鏡頭、攜帶錨點、抓取偵測區、出生點高度
## 全部是繞著中心調出來的，改原點等於全部重調。
func _setup_character() -> void:
	character_id = CharacterRoster.id_for_slot(slot_id)
	var entry := CharacterRoster.entry(character_id)
	weight = float(entry.get("weight", WeightLadder.for_slot(slot_id)))
	character_height = float(entry.get("height", 1.8))

	var capsule := _collision.shape.duplicate() as CapsuleShape3D
	if capsule != null:
		capsule.height = character_height
		capsule.radius = minf(character_height * 0.22, character_height * 0.5 - 0.01)
		_collision.shape = capsule  # 一定要 duplicate，否則三隻共用同一份形狀

	carry_anchor.position.y = character_height * 0.95
	stack_anchor.position.y = character_height * 0.5
	_label.position.y = character_height * 0.62

	if _character.load_character(character_id):
		_character.position.y = -character_height * 0.5
		for mesh in [$Visual/Body, $Visual/Nose]:
			mesh.visible = false  # 模型載入成功才收起膠囊，失敗時仍看得到東西
	else:
		push_warning("[Player] %s 的模型載入失敗，保留膠囊" % character_id)


## 鏡頭要對準的點：角色身上稍高的位置，不是腳底。
func _focus_target() -> Vector3:
	return global_position + Vector3.UP * (character_height * CAMERA_TARGET_RATIO)


func _camera_distance() -> float:
	return character_height * CAMERA_DISTANCE_RATIO


## 鏡頭相對於注視點的位移。
func _orbit_offset() -> Vector3:
	var arm := Vector3(0.0, sin(_camera_pitch), cos(_camera_pitch)) * _camera_distance()
	return Basis(Vector3.UP, _camera_yaw) * arm


## 位置與注視點一起由 _camera_anchor 推導，兩者永遠剛性綁在一起。
##
## 之前的做法是位置做平滑、注視點直接用角色當下位置——角色橫move 時，
## 落後的鏡頭為了盯住角色會額外轉一個角度，整個畫面跟著晃。
## 改成只有注視點在平滑，鏡頭就只有位移延遲，沒有轉動晃動。
func _place_camera() -> void:
	_camera.global_position = _camera_anchor + _orbit_offset()
	_camera.look_at(_camera_anchor, Vector3.UP)
	var swing := _shake_swing()
	if swing == Vector2.ZERO:
		return
	# 一定要在 look_at **之後**才轉。舊版是在 look_at 之前位移鏡頭，
	# 而 look_at 每幀重新瞄準沒被震的錨點，等於自己把震動抵銷掉——
	# 角色因此永遠釘在畫面正中央，只有背景在輕微視差。
	_camera.rotate_object_local(Vector3.RIGHT, swing.y)
	_camera.rotate_object_local(Vector3.UP, swing.x)
	_camera.rotate_object_local(Vector3.BACK, swing.x * CombatSpec.SHAKE_ROLL)


## 這一幀的鏡頭偏轉（弧度），x 是左右、y 是上下。
##
## 用時間驅動的正弦而不是逐幀 randf：逐幀亂數在 144 fps 是雜訊、在 60 fps 是抖動，
## 兩台機器看到的根本不是同一件事。兩軸頻率比 1.37 是為了不讓它變成一條斜線。
func _shake_swing() -> Vector2:
	var out := Vector2.ZERO
	var envelope := CombatSpec.shake_envelope(_shake_elapsed)
	if envelope > 0.0:
		var phase := _shake_elapsed * CombatSpec.SHAKE_FREQUENCY * TAU
		var amplitude := _shake_peak * CombatSpec.SHAKE_ANGLE * envelope
		out += Vector2(
			sin(phase + _shake_seed.x), sin(phase * 1.37 + _shake_seed.y)
		) * amplitude
	if _kick_elapsed < CombatSpec.KICK_TIME:
		# 二次衰減：出去快、回中更快，讀起來像被推了一下而不是飄回來。
		var remain := 1.0 - _kick_elapsed / CombatSpec.KICK_TIME
		out += _kick_screen * CombatSpec.KICK_ANGLE * remain * remain
	return out


## 震一下鏡頭。direction 是世界空間的衝擊方向，Vector3.ZERO 表示不加方向偏轉。
##
## 只有本機自己的鏡頭該震。呼叫端要負責過濾——take_hit() 在每一端都會跑，
## 不過濾的話 30 公尺外隊友被打會震到你的畫面。
func add_shake(magnitude: float, direction: Vector3 = Vector3.ZERO) -> void:
	if magnitude <= 0.0:
		return
	# 取大的不累加：連擊時累加會越震越誇張，與 Overcooked 基準打架。
	if _shake_elapsed >= CombatSpec.SHAKE_TIME or magnitude > _shake_peak:
		_shake_peak = magnitude
		_shake_elapsed = 0.0
		_shake_seed = Vector2(randf() * TAU, randf() * TAU)
	if direction == Vector3.ZERO:
		return
	# 換算到鏡頭空間，這樣「往右被打」在畫面上就是往右偏，
	# 不會像舊版那樣依鏡頭朝向變成推拉。
	var unit := direction.normalized()
	var basis := _camera.global_basis
	_kick_screen = Vector2(basis.x.dot(unit), basis.y.dot(unit))
	_kick_elapsed = 0.0


## 鏡頭的水平基底。移動輸入要換算到這個座標系——
## 世界座標移動配上不會轉的鏡頭，在 3D 第三人稱裡一定會覺得怪。
func _camera_basis() -> Basis:
	return Basis(Vector3.UP, _camera_yaw)


## 用 _unhandled_input 而不是 _input：UI 已經處理掉的點擊不會流到這裡，
## 所以點大廳按鈕不會順便鎖住滑鼠。
func _unhandled_input(event: InputEvent) -> void:
	if not _camera.current:
		return

	if event.is_action_pressed(&"ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return

	var click := event as InputEventMouseButton
	if click != null and click.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		# 點進畫面就鎖滑鼠，Esc 放開。M0 要在同一台機器上開三個視窗，
		# 所以一定要留一個放開的方式。
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	var motion := event as InputEventMouseMotion
	if motion == null:
		return
	var looking := (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
			or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
	if looking:
		_turn_camera(-motion.relative.x * MOUSE_SENSITIVITY, motion.relative.y * MOUSE_SENSITIVITY)


func _turn_camera(yaw_delta: float, pitch_delta: float) -> void:
	_camera_yaw += yaw_delta
	_camera_pitch = clampf(_camera_pitch + pitch_delta, CAMERA_PITCH_MIN, CAMERA_PITCH_MAX)


func _process(delta: float) -> void:
	if not _camera.current:
		return
	var stick := GameInput.get_look_delta(device_id)
	_turn_camera(-stick.x * STICK_LOOK_SPEED * delta, stick.y * STICK_LOOK_SPEED * delta)

	# 指數平滑：不受影格率影響，60 與 144 fps 的追隨速度一致。
	var target := _focus_target()
	var horizontal := 1.0 - exp(-delta / CAMERA_FOLLOW_TIME)
	var vertical := 1.0 - exp(-delta / CAMERA_VERTICAL_TIME)
	_camera_anchor.x = lerpf(_camera_anchor.x, target.x, horizontal)
	_camera_anchor.z = lerpf(_camera_anchor.z, target.z, horizontal)
	_camera_anchor.y = lerpf(_camera_anchor.y, target.y, vertical)
	_shake_elapsed += delta
	_kick_elapsed += delta
	_place_camera()


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
	# 意圖每幀只收集一次。手把的 just_pressed 是自己做的邊緣偵測，
	# 在不同分支各問一次會把狀態吃掉，按鍵就會時靈時不靈。
	if is_multiplayer_authority():
		if is_ai:
			_brain.think(self, _intent)
		else:
			_intent.fill_from_input(device_id)
	else:
		_intent.clear()

	if is_downed and carried_by_slot < 0:
		_process_downed(delta)
	elif carried_by_slot >= 0:
		_process_carried(delta)
	elif stacked_on >= 0:
		_process_stacked()
	elif is_multiplayer_authority():
		_process_authority(delta)
	else:
		_process_remote(delta)
	_visual.rotation.y = _yaw
	_character.drive(0.0 if is_downed else Vector3(velocity.x, 0.0, velocity.z).length())
	_tick_ragdoll_rumble(delta)
	_update_look_target()
	_update_label()


## 挑一個看向的目標餵給程序化姿態層：有敵人先看敵人，沒有就看最近的隊友。
##
## 純表演，所以不同步也不分權威——每台機器各自算，位置本來就是同步的，
## 算出來的結果一致，不值得為了轉頭再開一條網路欄位。
func _update_look_target() -> void:
	if is_downed:
		_character.clear_look_target()
		return

	var target: Node3D = null
	var best := LOOK_RANGE
	for node in get_tree().get_nodes_in_group("enemies"):
		var enemy: Node3D = node
		if enemy.get("is_broken") == true:
			continue
		var distance := global_position.distance_to(enemy.global_position)
		if distance < best:
			best = distance
			target = enemy

	if target == null:
		best = LOOK_RANGE
		for node in get_tree().get_nodes_in_group("player_characters"):
			var other: PlayerCharacter = node
			if other == self:
				continue
			var distance := global_position.distance_to(other.global_position)
			if distance < best:
				best = distance
				target = other

	if target == null:
		_character.clear_look_target()
	else:
		# 看對方的頭，不是腳底——看腳底會變成全隊一直低頭。
		var lift := character_height * 0.55
		if target is PlayerCharacter:
			lift = (target as PlayerCharacter).character_height * 0.55
		_character.set_look_target(target.global_position + Vector3.UP * lift)


func _process_authority(delta: float) -> void:
	# 每一幀都問，不能只在著地時問——手把的 just_pressed 是自己做的邊緣偵測，
	# 漏問幾幀狀態就會過期，導致「握著跳鍵落地後跳不起來」。
	var jump_pressed := _intent.jump
	if jump_pressed and is_on_floor() and StackSystem.rider_of(slot_id) >= 0:
		# 底層跳躍 → 整柱潰散（docs/04）。要在跳之前送，
		# 否則上層會先跟著飛起來再被拆，看起來像 bug。
		# 先確認頭上真的有人再送——疊高狀態是廣播同步的，客戶端本來就知道。
		StackSystem.request_collapse.rpc_id(1, slot_id)
	if is_on_floor():
		# 著地時一定要歸零。原本只在跳躍時才寫 velocity.y，
		# 落地後那個很大的負值會一直留著——走下平台的瞬間會像被吸下去。
		velocity.y = JUMP_VELOCITY if jump_pressed else 0.0
	else:
		velocity.y -= _gravity * (FALL_MULTIPLIER if velocity.y < 0.0 else 1.0) * delta

	# AI 沒有鏡頭，直接給世界方向；真人的輸入相對鏡頭。
	var wish := Vector3(_intent.move.x, 0.0, _intent.move.y)
	if not _intent.world_move:
		wish = _camera_basis() * wish
	if wish.length() > 1.0:
		wish = wish.normalized()

	var speed := SPEED * (CARRY_SPEED_PENALTY if is_carrying() else 1.0)
	if _attack.busy():
		speed *= ATTACK_MOVE_PENALTY  # 出手時腳步收住，攻擊才有重量
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
	_process_stack_probe()
	_process_revive_input(delta)
	_process_fall_damage()

	# M0 還沒有敵人。沒有這個鍵就只能靠從高處跳下來驗倒地與救援。
	if GameInput.is_just_pressed(device_id, &"debug_down"):
		DownSystem.request_debug_knockdown.rpc_id(1, slot_id)

	net_position = global_position
	net_velocity = velocity
	net_yaw = _yaw


## 情境攻擊（docs/06）：不佔按鍵，變化來自「你正在做什麼」。
func _attack_context() -> StringName:
	if not is_on_floor():
		return &"air"
	if Vector3(velocity.x, 0.0, velocity.z).length() > CombatSpec.DASH_SPEED_THRESHOLD:
		return &"dash"
	return &"stand"


func on_attack_started(spec: Dictionary) -> void:
	var step: StringName = StringName(str(spec.get("name", "light_1")))
	var clip: StringName = ATTACK_CLIPS.get(step, &"attack1")
	var heavy := step == &"heavy_3"
	_play_swing(clip, heavy)
	# 攻擊動畫與揮空音本來只在攻擊者自己那台機器上發生：AttackController
	# 對非權威端直接 return，而 press() 只從 _process_authority 呼叫。
	# 結果是隊友在你畫面上站著不動、無聲無息，然後泥偶突然飛出去。
	# 倒地與受擊動畫走 _apply_hit / _apply_down 廣播，一直都有同步，只有攻擊沒有。
	if multiplayer.has_multiplayer_peer() and multiplayer.get_peers().size() > 0:
		_play_swing.rpc(clip, heavy)


## 揮拳的表演。用 unreliable：掉一次揮空動畫沒差，但塞進可靠通道之後，
## 80 ms 延遲下會變成一次到一整串，看起來像機器人抽搐。
## call_remote 而不是 call_local——本機已經自己播過了，再播一次會把動畫重頭跑。
@rpc("any_peer", "call_remote", "unreliable")
func _play_swing(clip: StringName, heavy: bool) -> void:
	_character.play_action(clip)
	# 第三段是重擊，音調壓低一點，聽得出來跟前兩段不同。
	Sfx.play(&"whoosh", global_position, 0.85 if heavy else 1.0)


## 命中回饋在本機立刻生效，不等 host——回饋速度優先（docs/05）。
##
## direction 是「我打向哪裡」的世界方向，用來讓鏡頭往那個方向頂一下。
## 方向在本機就算得出來（攻擊者與被打者的位置都在手上），不必等 host 回報。
func on_hit_landed(spec: Dictionary, direction: Vector3 = Vector3.ZERO) -> void:
	add_shake(float(spec.get("shake", 0.0)), direction)
	_character.freeze(float(spec.get("hitstop", 0.0)))
	_character.punch(CombatSpec.PUNCH_ATTACK)
	if not is_ai:
		GameInput.rumble(device_id, &"hit")
	Sfx.play(&"hit", global_position)


func combat_kind() -> StringName:
	return &"player"


## 被打到。擊退永遠生效，扣血由 host 依誤傷開關決定（docs/04）。
##
## ⚠️ **這個函式在每一端都會跑**（CombatSystem._apply_hit 是 authority + call_local
## 的廣播）。所以這裡分成兩類，分錯就會很明顯地壞掉：
##   - 大家都該看到的：白閃、受擊動畫、壓扁、聲音。不設條件。
##   - 只該發生在「我身上」的：鏡頭震、手把震動。**一定要 gate**，
##     否則 30 公尺外隊友被打會震你的畫面、抖你的手把。
func take_hit(damage: float, impulse: Vector3) -> void:
	_character.flash()
	_character.punch(CombatSpec.PUNCH_VICTIM)
	Sfx.play(&"hurt", global_position)
	Vfx.burst(&"hit_spark", global_position + Vector3.UP * (character_height * 0.55), impulse)
	if not is_downed:
		_character.play_action(&"hurt")
	if is_multiplayer_authority():
		velocity = impulse
		if not is_ai:
			add_shake(CombatSpec.HURT_SHAKE, impulse)
			GameInput.rumble(device_id, &"hurt")
	if NetworkService.is_host() and damage > 0.0:
		DownSystem.apply_damage(slot_id, damage, impulse)


## 名牌兼狀態顯示。M0 還沒有 HUD（docs/06 那一套要等 M1），
## 但「誰倒了、扶到哪了」不回饋的話根本測不動。
func _update_label() -> void:
	if is_downed:
		_label.text = "%s（倒地）" % _base_label
	elif _revive_progress > 0.0:
		_label.text = "%s 扶起中 %d%%" % [
			_base_label, int(_revive_progress / DownSystem.REVIVE_TIME * 100.0)
		]
	else:
		_label.text = "%s  %d" % [_base_label, int(DownSystem.health_of(slot_id))]


## 落地傷害。M0 沒有敵人，這是唯一的傷害來源，也是驗證倒地與救援的方式。
##
## 用「上一幀的下墜速度」而不是當幀的：move_and_slide 撞到地面時會把
## velocity.y 歸零，當幀讀到的永遠是 0。
func _process_fall_damage() -> void:
	var falling := -minf(velocity.y, 0.0)
	# 落地聲的門檻比傷害低得多——輕輕跳一下也該有聲音，那是「我碰到地了」的回饋。
	if is_on_floor() and _previous_fall_speed > LAND_SOUND_SPEED:
		Sfx.play(&"land", global_position, 1.0 - minf(_previous_fall_speed / 30.0, 0.3))
		# 摔得越重震越大。鏡頭震重寫成「時長固定、強度可調」之後，
		# 這裡才有意義——舊版 0.16 的震動只會持續 29 毫秒，等於沒有。
		var weight := clampf(
			inverse_lerp(LAND_SOUND_SPEED, SAFE_FALL_SPEED, _previous_fall_speed), 0.0, 1.0
		)
		if not is_ai:
			add_shake(CombatSpec.LAND_SHAKE_MAX * weight, Vector3.DOWN)
			GameInput.rumble(device_id, &"land")
		_character.punch(lerpf(CombatSpec.PUNCH_LAND_MIN, CombatSpec.PUNCH_LAND_MAX, weight))
		Vfx.burst(
			&"land_dust", global_position - Vector3.UP * (character_height * 0.5),
			Vector3.UP, lerpf(0.6, 1.6, weight)
		)
	if is_on_floor() and _previous_fall_speed > SAFE_FALL_SPEED:
		DownSystem.request_fall_damage.rpc_id(1, slot_id, _previous_fall_speed)
	_previous_fall_speed = falling


## 扶起隊友：按住互動鍵靠近倒地的人。累積在自己這端算，
## 滿了才送一次請求——每幀送在 120 Hz 下會是 120 packets/s。
func _process_revive_input(delta: float) -> void:
	if not _intent.interact:
		_revive_progress = 0.0
		return
	var target := _nearest_downed()
	if target < 0:
		_revive_progress = 0.0
		return
	_revive_progress += delta
	if _revive_progress >= DownSystem.REVIVE_TIME:
		_revive_progress = 0.0
		DownSystem.request_revive.rpc_id(1, slot_id, target)


func _nearest_downed() -> int:
	var best := -1
	var best_distance := REVIVE_RANGE
	for node in get_tree().get_nodes_in_group("player_characters"):
		if node == self or not node.is_downed or node.carried_by_slot >= 0:
			continue
		var distance := global_position.distance_to(node.global_position)
		if distance < best_distance:
			best_distance = distance
			best = node.slot_id
	return best


## 疊高不佔按鍵（docs/06）：往下探到隊友的頭就送出請求。
##
## 只在下墜時偵測。站著往旁邊走過去也會探到人，那時吸附會很突兀——
## 要有「跳上去」這個動作，疊高才像是玩家做的事而不是走路的副作用。
func _process_stack_probe() -> void:
	# AI 不主動疊高（docs/08 明列為「不需要會」）。它要能被踩，
	# 但不該自己跳到隊友頭上——那會變成玩家得先把 AI 趕下來。
	if is_ai or stacked_on >= 0 or velocity.y > 0.0 or is_on_floor():
		return
	# 節流。物理跑 120 Hz，落在隊友頭上的那段時間會送出幾十個一模一樣的
	# 請求——host 只會接受第一個，其餘全是白花的頻寬。
	var now := Time.get_ticks_msec() / 1000.0
	if now < _next_stack_request:
		return
	_next_stack_request = now + STACK_REQUEST_INTERVAL
	var feet := global_position - Vector3.UP * (character_height * 0.5)
	var query := PhysicsRayQueryParameters3D.create(feet, feet - Vector3.UP * STACK_PROBE_LENGTH)
	query.collision_mask = 2  # 只找玩家
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	# Dictionary 取值回傳 Variant，:= 會推導成 Variant——Godot 4.7 把這個
	# 警告當成錯誤，整支腳本會 parse error。一律標明型別。
	var other: Node = hit.get("collider")
	if other == null or not (other is PlayerCharacter):
		return
	StackSystem.request_stack.rpc_id(1, slot_id, other.slot_id)


## 只送請求，不自己決定結果。目標查詢與重量驗證都在 host（TD-02）。
func _process_carry_input(delta: float) -> void:
	# 攻擊：手上沒東西時才是攻擊，抓著東西時攻擊鍵是投擲（docs/06）。
	if not is_carrying() and _intent.attack:
		_attack.press(_attack_context())

	if _intent.respawn:
		DownSystem.request_respawn.rpc_id(1, slot_id)
		return

	if _intent.grab:
		if is_carrying():
			CarrySystem.request_drop.rpc_id(1, slot_id)
		else:
			CarrySystem.request_grab.rpc_id(1, slot_id)

	if not is_carrying():
		_throw_charge = 0.0
		return

	if _intent.throw_held:
		_throw_charge = minf(_throw_charge + delta / THROW_CHARGE_TIME, 1.0)
	elif _throw_charge > 0.0:
		CarrySystem.request_throw.rpc_id(1, slot_id, _throw_charge)
		_throw_charge = 0.0


## 由 DownSystem 呼叫，不要從別的地方寫。
func on_downed(impulse: Vector3) -> void:
	is_downed = true
	velocity = impulse
	_revive_progress = 0.0
	_throw_charge = 0.0
	# 真布娃娃優先；建不出來（模型沒有人形骨架）才退回把整個 Visual 壓下去。
	# 衝量由 DownSystem 廣播，三台機器的起始條件一致（TD-06）。
	Sfx.play(&"down", global_position)
	if not _character.start_ragdoll(impulse):
		_visual.rotation.x = deg_to_rad(DOWNED_PITCH)
		_character.play_action(&"death")


## 由 DownSystem 呼叫。把人送回出生點並解除所有狀態。
##
## 要解得夠乾淨：卡住的人常常同時是「被抓著」或「疊在別人身上」，
## 只搬位置的話下一幀又會被錨點拉回去。
func respawn() -> void:
	if StackSystem.is_stacked(slot_id):
		StackSystem.detach(slot_id)
	StackSystem.collapse_above(slot_id)
	if carried_by_slot >= 0 and NetworkService.is_host():
		CarrySystem.request_drop(carried_by_slot)
	on_revived()
	global_position = spawn_position
	velocity = Vector3.ZERO
	net_position = spawn_position
	net_velocity = Vector3.ZERO


func on_revived() -> void:
	is_downed = false
	_revive_progress = 0.0
	_ragdoll_rumble = 0.0
	_visual.rotation.x = 0.0
	_character.stop_ragdoll()
	if is_multiplayer_authority() and not is_ai:
		GameInput.stop_rumble(device_id)
	Sfx.play(&"revive", global_position)


## 布娃娃期間的持續低頻震動（docs/05 的表）。
##
## 不用 duration = 0 的無限震動：那要靠明確的 stop 才會停，遊戲當掉、
## 斷線或漏掉一個分支就會震到天荒地老。改成每 0.3 秒重發一次固定時長的，
## 最壞情況 300 毫秒自己停。
func _tick_ragdoll_rumble(delta: float) -> void:
	if not is_downed or not is_multiplayer_authority() or is_ai or device_id < 0:
		return
	_ragdoll_rumble -= delta
	if _ragdoll_rumble > 0.0:
		return
	_ragdoll_rumble = float(CombatSpec.RUMBLE[&"ragdoll"]["seconds"])
	GameInput.rumble(device_id, &"ragdoll")


## 倒地時仍受重力與碰撞影響——被丟出去的人要能滾下斜坡，
## 那是「事故就是內容」的一部分。但沒有輸入，也不能自行復活（docs/04）。
##
## 根位置由權威端算並同步（TD-06）。骨骼各機自算，姿勢不一樣無妨，
## 但「你倒在哪」必須一致——那決定隊友扶不扶得到你。
##
## 有布娃娃時，本體的位置跟著布娃娃的髖部走：人被打飛出去滾了三公尺，
## 扶起判定就該在三公尺外的那個位置，不是原地。
func _process_downed(delta: float) -> void:
	if not is_multiplayer_authority():
		_process_remote(delta)
		return
	if _character.has_ragdoll():
		var root := _character.ragdoll_root()
		if root != Vector3.ZERO:
			# 布娃娃的髖部大約在半身高，本體原點在膠囊中心，兩者對齊即可。
			global_position = root
			velocity = Vector3.ZERO
			net_position = global_position
			net_velocity = Vector3.ZERO
			return
	if not is_on_floor():
		velocity.y -= _gravity * FALL_MULTIPLIER * delta
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	horizontal = horizontal.move_toward(Vector3.ZERO, SPEED / STOP_TIME * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z
	move_and_slide()
	net_position = global_position
	net_velocity = velocity


## 由 StackSystem 呼叫，不要從別的地方寫。
func on_stacked(base_slot: int) -> void:
	stacked_on = base_slot
	velocity = Vector3.ZERO
	Sfx.play(&"stack", global_position)


func on_unstacked(push: Vector3) -> void:
	stacked_on = -1
	velocity = push


## 踩在別人頭上時，位置由下層的頭頂錨點推導（TD-05 邏輯附掛）。
##
## 不做 reparent、也不靠物理堆疊：位置是「下層錨點 + 自己的半身高」，
## 整柱只有底座在跑物理。這樣底座一動，上面的人自然跟著走，
## 而且三台機器算出來的結果完全一致——因為底座的位置本來就有同步。
func _process_stacked() -> void:
	var base := CarrySystem.find_player(stacked_on)
	if base == null:
		return
	global_position = base.stack_anchor.global_position + Vector3.UP * (character_height * 0.5)
	velocity = Vector3.ZERO
	net_position = global_position
	net_velocity = Vector3.ZERO

	if not is_multiplayer_authority():
		return
	# 上層仍保有鏡頭自由（docs/04 被抓者仍保有鏡頭旋轉，疊高同理），
	# 但移動輸入不推動角色——上層是乘客，不是共同施力者。
	if _intent.jump:
		StackSystem.request_dismount.rpc_id(1, slot_id)


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
	var struggle_input := _intent.move.length()
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
