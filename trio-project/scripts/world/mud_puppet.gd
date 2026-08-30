class_name MudPuppet
extends CharacterBody3D

## 泥偶：圖騰腐化溢出的雜兵（docs/05 小怪三層）。
##
## 一擊即散、打飛極遠，負責讓玩家爽。擊退倍率 ×2.0 是全遊戲最高的——
## 擊退距離直接反映敵人強度，玩家不用看血條就能讀出威脅等級。
##
## host 權威（TD-02）：只有 host 跑物理，客戶端插值跟隨。

const SYNC_HZ := 20.0
const REMOTE_LERP := 14.0
const TELEPORT_DISTANCE := 3.0

## 被打飛後多久消失。要夠久讓玩家看完那一段拋物線。
const DESPAWN_DELAY := 2.5

## 沒被打時的緩慢遊走。M0/M1 不做 AI，只要有東西會動就夠測打擊感。
const WANDER_SPEED := 1.2
const WANDER_INTERVAL := 2.0

var net_position: Vector3 = Vector3.ZERO
var is_broken: bool = false

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _gone := false
var _wander := Vector3.ZERO
var _wander_timer := 0.0
var _despawn := 0.0


func _ready() -> void:
	add_to_group("enemies")
	_setup_synchronizer()
	set_multiplayer_authority(1)
	net_position = global_position


func _setup_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	for property in [".:net_position", ".:is_broken"]:
		var path := NodePath(property)
		config.add_property(path)
		config.property_set_spawn(path, false)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	var sync := MultiplayerSynchronizer.new()
	sync.name = "Synchronizer"
	sync.replication_config = config
	sync.replication_interval = 1.0 / SYNC_HZ
	add_child(sync)


func combat_kind() -> StringName:
	return &"mud_puppet"


## 一擊即散（docs/05）。damage 不看數值，泥偶碰到就散。
func take_hit(_damage: float, impulse: Vector3) -> void:
	if is_broken:
		return
	is_broken = true
	velocity = impulse
	_despawn = DESPAWN_DELAY


func _physics_process(delta: float) -> void:
	# 消失的倒數每一端各自跑。不能用 queue_free——泥偶是場景擺好的節點，
	# 不是 MultiplayerSpawner 生成的，host 刪掉不會複製到客戶端，
	# 結果就是 host 看到消失、客戶端還站著一隻。
	if is_broken and not _gone:
		_despawn -= delta
		if _despawn <= 0.0:
			_vanish()

	if not NetworkService.simulates_world():
		if global_position.distance_to(net_position) > TELEPORT_DISTANCE:
			global_position = net_position
		else:
			global_position = global_position.lerp(net_position, 1.0 - exp(-REMOTE_LERP * delta))
		return

	if not is_on_floor():
		velocity.y -= _gravity * delta
	elif is_broken:
		velocity.x = move_toward(velocity.x, 0.0, 12.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 12.0 * delta)

	if not is_broken:
		_tick_wander(delta)

	move_and_slide()
	net_position = global_position




## 收起來而不是刪除。之後接上「被黏合的動物打倒後變回動物跑掉」（docs/05）
## 時，這裡就是那段演出的位置。
func _vanish() -> void:
	_gone = true
	visible = false
	set_collision_layer_value(4, false)


func _tick_wander(delta: float) -> void:
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_wander_timer = WANDER_INTERVAL
		var angle := randf() * TAU
		_wander = Vector3(cos(angle), 0.0, sin(angle)) * WANDER_SPEED
	velocity.x = _wander.x
	velocity.z = _wander.z
