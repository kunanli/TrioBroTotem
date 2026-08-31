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

## 被打中之後先頓住多久才飛出去。
##
## 泥偶沒有 AnimationPlayer，所以「頓幀」對它而言就是**把擊退按住幾幀**：
## 衝擊先讀出來，然後才發射。只有 host 跑物理、客戶端靠 net_position 跟，
## 所以這個停頓不必多加同步欄位就會自動複製過去。
const HITSTOP := 3.0 / 60.0

var net_position: Vector3 = Vector3.ZERO
var is_broken: bool = false

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _gone := false
var _wander := Vector3.ZERO
var _wander_timer := 0.0
var _despawn := 0.0
var _hitstop := 0.0
var _broken_seen := false
var _flash := 0.0
var _material: StandardMaterial3D = null
var _base_emission_on := false
var _base_emission := Color.BLACK
var _base_emission_energy := 1.0

@onready var _mesh: MeshInstance3D = $Mesh


func _ready() -> void:
	add_to_group("enemies")
	# 一定要 duplicate。mud_puppet.tscn 的材質是 [sub_resource] 而且沒有
	# resource_local_to_scene，PackedScene 的每一個實例共用同一份——
	# 直接改的話打一隻會四隻一起白閃。
	# 同樣的坑在 player_character.gd 的碰撞形狀與 character_visual.gd 的
	# 材質快取已經各踩過一次了。
	_material = _mesh.material_override.duplicate()
	# 敵人也要描邊：docs/09 要求「半畫面尺寸下仍須可辨識」，而混戰時最需要
	# 一眼分辨的就是「哪個是敵人」。場景方塊沒有描邊，所以描了邊的就是會動的東西。
	_material.next_pass = Outline.material()
	# 記下常駐的發光，白閃結束時要還原成這個，不是還原成「關掉」。
	_base_emission_on = _material.emission_enabled
	_base_emission = _material.emission
	_base_emission_energy = _material.emission_energy_multiplier
	_mesh.material_override = _material
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
##
## 這個函式在每一端都會跑（CombatSystem._apply_hit 是廣播），所以表演寫在
## _on_broken() 裡由狀態驅動，這裡只負責改狀態。
func take_hit(_damage: float, impulse: Vector3) -> void:
	if is_broken:
		return
	is_broken = true
	velocity = impulse
	_hitstop = HITSTOP


## 攻擊者在本機的樂觀回饋，不等 host 確認。
##
## 這正是 combat_system.gd 註解說的那條路：「客戶端可以樂觀播特效，
## 但扣血一律等 host」。攻擊者 0 毫秒就看到閃光與火花，其他人 RTT 之後看到。
func on_hit_predicted(direction: Vector3) -> void:
	if is_broken or _broken_seen:
		return
	_flash_now()
	Vfx.burst(&"hit_spark", global_position + Vector3.UP * 0.4, direction)


## 命中白閃。
##
## 存下再還原，**不要切 emission_enabled 這個 bool**——泥偶現在是常駐發紫光的
## （腐化，docs/02），把 bool 關掉會在第一次被打之後永久熄滅，而且不會有任何
## 錯誤訊息，只是那隻泥偶從此比別隻暗。
func _flash_now() -> void:
	_flash = CombatSpec.FLASH_TIME
	_material.emission_enabled = true
	_material.emission = Color.WHITE
	_material.emission_energy_multiplier = 1.6


func _flash_done() -> void:
	_material.emission_enabled = _base_emission_on
	_material.emission = _base_emission
	_material.emission_energy_multiplier = _base_emission_energy


## 被打中的那一刻，每一端各自播。用「第一次看到 is_broken 變 true」驅動，
## 不是在 take_hit 裡直接播——理由見 _physics_process。
func _on_broken() -> void:
	_flash_now()
	Sfx.play(&"hit", global_position)


func _physics_process(delta: float) -> void:
	if _flash > 0.0:
		_flash -= delta
		if _flash <= 0.0:
			_flash_done()

	# 倒數在「第一次觀察到 is_broken 變 true」時起算，**不是**在 take_hit 裡設。
	#
	# is_broken 同時走兩條路到客戶端：MultiplayerSynchronizer（20 Hz）與
	# CombatSystem._apply_hit 這個 reliable RPC。兩條是不同的 ENet 通道，
	# 沒有先後保證。同步先到的那一端會拿到 is_broken = true 而 _despawn = 0，
	# 下一個 tick 就直接 _vanish()——host 看到 2.5 秒的拋物線，
	# 那台機器看到泥偶原地閃掉。晚加入的玩家也必然踩到。
	if is_broken and not _broken_seen:
		_broken_seen = true
		_despawn = DESPAWN_DELAY
		_on_broken()

	# 消失的倒數每一端各自跑。不能用 queue_free——泥偶是場景擺好的節點，
	# 不是 MultiplayerSpawner 生成的，host 刪掉不會複製到客戶端，
	# 結果就是 host 看到消失、客戶端還站著一隻。
	if _broken_seen and not _gone:
		_despawn -= delta
		if _despawn <= 0.0:
			_vanish()

	if not NetworkService.simulates_world():
		if global_position.distance_to(net_position) > TELEPORT_DISTANCE:
			global_position = net_position
		else:
			global_position = global_position.lerp(net_position, 1.0 - exp(-REMOTE_LERP * delta))
		return

	# 頓一下再飛。位置不動，net_position 也就不動，客戶端自然跟著停。
	if _hitstop > 0.0:
		_hitstop -= delta
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
##
## 碎屑是純本機表演，各端自己生成、自己回收，不進同步——每一端都是由
## 同步過的 is_broken 驅動走到這裡的，時間點本來就一致。
func _vanish() -> void:
	_gone = true
	Vfx.burst(&"shatter", global_position + Vector3.UP * 0.4, Vector3.UP)
	Sfx.play(&"shatter", global_position)
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
