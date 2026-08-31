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

## 離開地面之後還有多久可以跳，以及提早按跳會被記住多久。
##
## 物理跑 120 Hz——沒有這兩個的話，早按或晚按**一個 tick（8.3 毫秒）**
## 就整個丟掉，而人根本按不準到 8 毫秒。本作的核心動詞正是「疊高跳上平台」，
## 那是最需要抓準時機的動作，也就最需要這兩個緩衝。
##
## 0.12 秒是常見的取值：足以蓋掉人類的反應誤差，又短到不會變成「二段跳」。
const COYOTE_TIME := 0.12
const JUMP_BUFFER := 0.12

## 掉到這個高度以下就自動重生。斷崖底在 −12，留一段餘裕讓玩家看完那一段墜落
## （掉下去是自己的錯，但要看得到自己掉下去，不然只會覺得遊戲當掉了）。
const VOID_Y := -22.0

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

## 起跳時身體拉長的量（與命中縮放共用同一個通道，正數＝拉長）。
const JUMP_STRETCH := 0.10

## 腳步的步幅＝身高 × 這個比例。矮的動物步伐短，節奏才對得上。
const STRIDE_RATIO := 0.62

## 慢到這個速度以下就不出腳步聲——輕微的推擠或滑動不該一直踩。
const STEP_MIN_SPEED := 1.2

## 腳步的音量。一秒會響好幾次，一定要壓得比其他音效低很多。
const STEP_VOLUME_DB := -15.0

## 移動傾斜：橫向加速與轉向時身體往內傾多少（弧度）。
## 純表演，不影響碰撞——傾斜的是 Visual，不是 CharacterBody3D。
const LEAN_MAX := 0.16
const LEAN_TIME := 0.12

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

## 鏡頭的參數全部搬到 player_camera.gd。這個檔案只負責「要看誰」跟「震多大」。

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
var _coyote: float = 0.0
var _jump_buffer: float = 0.0
var _step_distance: float = 0.0
var _was_grounded: bool = true
var _lean: Vector2 = Vector2.ZERO
var _last_horizontal: Vector3 = Vector3.ZERO
var _base_label: String = ""
var _intent := PlayerIntent.new()

@onready var carry_anchor: Node3D = $Visual/CarryAnchor
@onready var grab_probe: Area3D = $Visual/GrabProbe
@onready var stack_anchor: Node3D = $StackAnchor

@onready var _brain: AiBrain = $AiBrain
@onready var _attack: AttackController = $Visual/AttackController
@onready var _character: CharacterVisual = $Visual/Character
@onready var _collision: CollisionShape3D = $Collision
@onready var _visual: Node3D = $Visual
@onready var _label: Label3D = $NameLabel
@onready var _camera: PlayerCamera = $Camera3D
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
	# 只上備援膠囊，**不要**用 find_children 掃整個 Visual。
	#
	# 現在掃也只會掃到這兩個（模型是執行期 add_child 的，根節點沒有 owner，
	# find_children 的 owned 預設值 true 會連同整個子樹一起跳過），但那是
	# 巧合不是設計——哪天模型改成場景裡擺好的，material_override 就會蓋掉
	# CharacterVisual 逐 surface 設好的材質，貼圖、描邊、命中閃白會同時失效，
	# 而且不會有任何錯誤訊息。寫死這兩個節點，意圖就跟行為一致了。
	for path in ["Body", "Nose"]:
		var mesh := _visual.get_node_or_null(path) as MeshInstance3D
		if mesh != null:
			mesh.material_override = material

	# M0 一個 peer 只負責一個 slot，所以這樣就夠。
	# 本地分屏（TD-04）時要改成每個 slot 一個 SubViewport，不是靠 current。
	_camera.current = is_multiplayer_authority() and not is_ai
	# 鏡頭脫離角色的座標系，改成自己平滑追上去。
	# 硬綁在角色身上時，角色每個物理幀的位移會原封不動變成鏡頭的抖動。
	_camera.bind(self)

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
	_clear_air_state()
	if holder_slot >= 0:
		velocity = Vector3.ZERO


## 土狼時間與跳躍緩衝在離開「自己走路」這個狀態時一定要歸零。
##
## 被扛、疊高、倒地都會跳過 _process_authority，計時器就會停在最後一次
## 落地的值——被丟出去的人一落地就會白得一次跳躍，而且看起來像 bug 不像 feature。
func _clear_air_state() -> void:
	_coyote = 0.0
	_jump_buffer = 0.0
	_step_distance = 0.0


func apply_throw(release_velocity: Vector3) -> void:
	velocity = release_velocity


func is_carrying() -> bool:
	return CarrySystem.held_carryable(slot_id) != null


## 給場景中的互動物件（任務看板之類）問的。
##
## 只有本機有權威的角色才會有意圖——遠端角色的 _intent 每幀都被清空
## （見 _physics_process），問了永遠是 false。
func wants_interact() -> bool:
	return is_multiplayer_authority() and not is_ai and _intent.interact


## 換場之後把角色放到新世界的出生點。
##
## 一定要連 spawn_position 一起改，否則按 R 脫困會把人送回上一張地圖的座標，
## 也就是新世界裡的隨便一個地方（通常是空中或牆裡）。
func teleport_to(target: Vector3) -> void:
	if StackSystem.is_stacked(slot_id):
		StackSystem.detach(slot_id)
	StackSystem.collapse_above(slot_id)
	spawn_position = target
	global_position = target
	velocity = Vector3.ZERO
	net_position = target
	net_velocity = Vector3.ZERO
	_clear_air_state()


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
	_apply_lean(delta)
	_character.drive(0.0 if is_downed else Vector3(velocity.x, 0.0, velocity.z).length())
	_process_ground_feel(delta)
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
	# 掉出世界就自動重生。
	#
	# 以前沒有任何高度下限，掉進斷崖會**一直掉**，只能自己按 R。沒人抱怨是因為
	# 關卡太平、大家根本不會往下看；斷崖現在讀得出來是斷崖了，就會有人掉下去。
	# 這等同於自動幫你按一次 R，不是新機制。
	if global_position.y < VOID_Y:
		DownSystem.request_respawn.rpc_id(1, slot_id)
		return


	# 每一幀都問，不能只在著地時問——手把的 just_pressed 是自己做的邊緣偵測，
	# 漏問幾幀狀態就會過期，導致「握著跳鍵落地後跳不起來」。
	# 緩衝一定要餵 _intent.jump，**不能**再問一次 GameInput.is_just_pressed——
	# 手把的邊緣偵測是消耗式的，同一幀問第二次就把狀態吃掉了（見 player_intent.gd）。
	_coyote = COYOTE_TIME if is_on_floor() else maxf(_coyote - delta, 0.0)
	_jump_buffer = JUMP_BUFFER if _intent.jump else maxf(_jump_buffer - delta, 0.0)
	var can_jump := _coyote > 0.0 and _jump_buffer > 0.0

	if can_jump and StackSystem.rider_of(slot_id) >= 0:
		# 底層跳躍 → 整柱潰散（docs/04）。要在跳之前送，
		# 否則上層會先跟著飛起來再被拆，看起來像 bug。
		# 先確認頭上真的有人再送——疊高狀態是廣播同步的，客戶端本來就知道。
		StackSystem.request_collapse.rpc_id(1, slot_id)
	if can_jump:
		velocity.y = JUMP_VELOCITY
		# 兩個都要消耗掉。緩衝不清會在起跳後的第一個空中幀再滿足一次，
		# 土狼不清則會變成二段跳。
		_jump_buffer = 0.0
		_coyote = 0.0
		_on_jumped()
	elif is_on_floor():
		# 著地時一定要歸零。原本只在跳躍時才寫 velocity.y，
		# 落地後那個很大的負值會一直留著——走下平台的瞬間會像被吸下去。
		velocity.y = 0.0
	else:
		velocity.y -= _gravity * (FALL_MULTIPLIER if velocity.y < 0.0 else 1.0) * delta

	# AI 沒有鏡頭，直接給世界方向；真人的輸入相對鏡頭。
	var wish := Vector3(_intent.move.x, 0.0, _intent.move.y)
	if not _intent.world_move:
		wish = _camera.basis_yaw() * wish
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
	_camera.add_shake(float(spec.get("shake", 0.0)), direction)
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
			_camera.add_shake(CombatSpec.HURT_SHAKE, impulse)
			GameInput.rumble(device_id, &"hurt")
	if NetworkService.is_host() and damage > 0.0:
		DownSystem.apply_damage(slot_id, damage, impulse)


## 名牌兼狀態顯示。M0 還沒有 HUD（docs/06 那一套要等 M1），
## 但「誰倒了、扶到哪了」不回饋的話根本測不動。
func _update_label() -> void:
	if is_downed:
		_label.text = "%s  (down)" % _base_label
	elif _revive_progress > 0.0:
		_label.text = "%s  reviving %d%%" % [
			_base_label, int(_revive_progress / DownSystem.REVIVE_TIME * 100.0)
		]
	else:
		_label.text = "%s  %d" % [_base_label, int(DownSystem.health_of(slot_id))]


## 落地傷害。M0 沒有敵人，這是唯一的傷害來源，也是驗證倒地與救援的方式。
##
## 用「上一幀的下墜速度」而不是當幀的：move_and_slide 撞到地面時會把
## velocity.y 歸零，當幀讀到的永遠是 0。
func _process_fall_damage() -> void:
	if is_on_floor() and _previous_fall_speed > SAFE_FALL_SPEED:
		DownSystem.request_fall_damage.rpc_id(1, slot_id, _previous_fall_speed)


## 加速與轉向時身體往內傾。
##
## 傾斜的是 Visual 不是 CharacterBody3D——碰撞膠囊要保持直立，
## 否則走快一點就會卡到門框，那是手感變好卻讓關卡壞掉的典型換法。
##
## 用「速度的變化」而不是「現在的速度」：等速直線前進時人是直的，
## 只有起步、煞車、轉彎才傾。這也讓遠端角色不必額外同步——
## net_velocity 本來就同步，變化量自己算得出來。
func _apply_lean(delta: float) -> void:
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var target := Vector2.ZERO
	# 倒地時 Visual 的 x 旋轉被 DOWNED_PITCH 佔用，這裡不能去搶。
	if not is_downed and stacked_on < 0 and carried_by_slot < 0 and delta > 0.0:
		var accel := (horizontal - _last_horizontal) / delta
		# 換算到角色自己的座標系：往前加速就往前傾，往右轉就往右倒。
		var facing := Basis(Vector3.UP, _yaw)
		var local := facing.inverse() * accel
		target = Vector2(local.x, -local.z) / (SPEED / ACCEL_TIME) * LEAN_MAX
		target = target.limit_length(LEAN_MAX)
	_last_horizontal = horizontal
	_lean = _lean.lerp(target, 1.0 - exp(-delta / LEAN_TIME))
	if is_downed:
		return
	_visual.rotation.x = _lean.y
	_visual.rotation.z = -_lean.x


## 起跳的表演。只有權威端會走到這裡（跳躍判定在 _process_authority），
## 但拉長與聲音在每一端都該看得到，所以走 _play_liftoff 廣播。
func _on_jumped() -> void:
	_play_liftoff()
	if multiplayer.has_multiplayer_peer() and not multiplayer.get_peers().is_empty():
		_play_liftoff.rpc()


## 起跳：身體先拉長一下。與命中縮放共用同一個通道，正數是拉長。
@rpc("any_peer", "call_remote", "unreliable")
func _play_liftoff() -> void:
	_character.punch(JUMP_STRETCH)
	_character.play_action(&"jump")
	Sfx.play(&"jump", global_position, randf_range(0.95, 1.08), -6.0)


## 落地與腳步的表演層。**每一端、每一個角色都跑**，不分權威。
##
## 這一段本來寫在 _process_fall_damage() 裡，而那個函式只從 _process_authority
## 呼叫——所以遠端隊友的落地在你這端是完全無聲無形的。三人遊戲裡三分之二的
## 落地都不見了，而落地是走路之外最常發生的事。
##
## 遠端角色的 velocity 來自 net_velocity（30 Hz 同步），拿來判斷「在不在地上」
## 已經夠用。不要為了這個再開一條網路欄位——這是表演，差幾十毫秒沒有人看得出來。
func _process_ground_feel(delta: float) -> void:
	var grounded := is_on_floor() if is_multiplayer_authority() else absf(velocity.y) < 0.5
	if grounded and not _was_grounded and _previous_fall_speed > LAND_SOUND_SPEED:
		_land_feedback()
	_was_grounded = grounded
	# 滯空與扛東西都是**疊加姿勢**，每一端每一個角色都要跑——遠端隊友在你畫面上
	# 扛著東西時手也該抬起來。兩者都沒有固定長度，所以不能是一次性片段。
	_character.set_airborne(not grounded and not is_downed)
	_character.set_carrying(is_carrying())
	_previous_fall_speed = -minf(velocity.y, 0.0)
	_tick_footsteps(delta, grounded)


func _land_feedback() -> void:
	# 摔得越重震越大。鏡頭震重寫成「時長固定、強度可調」之後這裡才有意義——
	# 舊版 0.16 的震動只會持續 29 毫秒，等於沒有。
	var weight := clampf(
		inverse_lerp(LAND_SOUND_SPEED, SAFE_FALL_SPEED, _previous_fall_speed), 0.0, 1.0
	)
	Sfx.play(&"land", global_position, 1.0 - minf(_previous_fall_speed / 30.0, 0.3))
	_character.punch(lerpf(CombatSpec.PUNCH_LAND_MIN, CombatSpec.PUNCH_LAND_MAX, weight))
	_character.play_action(&"land")
	Vfx.burst(
		&"land_dust", global_position - Vector3.UP * (character_height * 0.5),
		Vector3.UP, lerpf(0.6, 1.6, weight)
	)
	if is_multiplayer_authority() and not is_ai:
		_camera.add_shake(CombatSpec.LAND_SHAKE_MAX * weight, Vector3.DOWN)
		GameInput.rumble(device_id, &"land")


## 腳步的節奏來源是「走了多遠」，不是動畫時間軸。
##
## 動畫時間軸看起來比較「對」，但三隻角色的走路動畫來源不同（程式生成的與
## 匯入的），落腳的時間點各不相同，要維護一張每隻角色的落腳表——而那張表
## 會在美術重新匯出模型時靜靜地過期，沒有人會發現。
##
## 距離則是所有角色、AI、遠端角色都成立的同一件事，而且節奏會自動跟著速度
## 變快變慢，不必另外處理。步幅依身高，矮的動物步伐短，聽起來才對。
func _tick_footsteps(delta: float, grounded: bool) -> void:
	if not grounded or is_downed or stacked_on >= 0 or carried_by_slot >= 0:
		_step_distance = 0.0
		return
	var speed := Vector3(velocity.x, 0.0, velocity.z).length()
	if speed < STEP_MIN_SPEED:
		return
	_step_distance += speed * delta
	var stride := character_height * STRIDE_RATIO
	if _step_distance < stride:
		return
	_step_distance -= stride
	# 音量壓得很低：一秒會響好幾次，用命中音的音量會非常可怕。
	Sfx.play(&"step", global_position, randf_range(0.88, 1.16), STEP_VOLUME_DB)
	Vfx.burst(
		&"step_puff", global_position - Vector3.UP * (character_height * 0.5), Vector3.UP, 0.5
	)


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
	_clear_air_state()
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
	_clear_air_state()
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
