class_name CorruptionPool
extends Area3D

## 腐化的毒液。站在裡面就掉血。
##
## docs/02 說土地正在腐化，而斷崖底下那層紫色的霧氣是全關唯一看得到「地底下
## 有什麼」的地方。這一池就是那個東西滲上來了——同一個顏色、同一個意思。
##
## ## 複製面是零
##
## 沒有 MultiplayerSynchronizer、沒有 RPC、沒有 set_multiplayer_authority。
## host 每一跳對重疊的玩家呼叫 `DownSystem.apply_damage()`，而那支函式本來
## 就是 host-only 而且會廣播血量。**這是三個機關裡最便宜的一個。**
##
## 表演每一端自己跑：毒池是 Area3D，每一端都看得到誰站在裡面，所以回饋不需要
## 任何一條訊息。相位在兩端差幾十毫秒，沒有人看得出來。
##
## ## 三條設計規則
##
##  - 池子沿著前進方向不超過 8 公尺，**倒下的人離乾地永遠不超過 4 公尺**。
##  - 倒地的人**可以被扛走**（Carryable 那條路已經有了），先拖出來再扶。
##  - **沒有任何一個池子是致命的，也沒有任何一拍需要站在池子裡**——要在池子
##    中央做的事（踩壓力板）都可以從乾岸用丟的。這一章沒有檢查點，全隊倒地
##    就退回營地重來，所以毒池只能是代價，不能是門檻。

## 幾秒扣一次。連續扣的話血條會像在漏水，一跳一跳才讀得出「又中了一次」。
const TICK := 0.5

## 水面離地多高、多厚。**薄薄一片鋪在正常地面上，不是坑。**
const SURFACE_Y := 0.035
const SURFACE_THICKNESS := 0.08

## 水面的透明度，以及往 corrupt_glow 那個霓虹紫混多少。
##
## **直接用 corrupt_glow 太亮**：(0.80, 0.28, 0.90) 不透明度 0.30 鋪在地上是
## 一張洋紅色的地毯，不是液體——而且它跟泥偶搶同一個顏色的注意力。
## 混一半深紫 corrupt (0.21, 0.15, 0.26) 之後才讀得出來是「髒掉的水」，
## 霓虹紫留給上面飄的霧氣。
const SURFACE_ALPHA := 0.24
const SURFACE_GLOW_MIX := 0.5

## 霧氣粒子。**要小要多**。
##
## 粒子是沒有貼圖的 QuadMesh（整個專案都是），所以只要一片大到看得出形狀，
## 它就是一個半透明的方塊，不是霧。一公尺寬那一版在凹室裡整片都是方格子。
## 縮到三十公分、數量加倍之後才讀成一層浮塵。
const MIST_COUNT := 26
const MIST_LIFETIME := 3.6
const MIST_QUAD := 0.3
const MIST_ALPHA := 0.14

## 每秒扣多少血。
##
## **12 剛好是玩家一記輕擊的傷害**（CombatSpec.COMBO 第一段），所以「站在裡面
## 一秒等於被揍一拳」是一句可以直接講給人聽的話。要調難度先動這個數字，
## 不要動版型——池子的寬度是別的東西（投擲距離、倒地的人離岸多遠）在決定的。
@export var damage_per_second: float = 12.0

var _clock := 0.0


func _ready() -> void:
	add_to_group("hazards")
	_dress_surface()
	_spawn_mist()


func _physics_process(delta: float) -> void:
	_clock += delta
	if _clock < TICK:
		return
	_clock -= TICK
	var soaking := _soaking()
	# 每一端都演，不發任何訊息。
	for body in soaking:
		_sting(body)
	if not NetworkService.is_host():
		return
	for body in soaking:
		# 倒地的人 apply_damage 自己會 no-op——躺在池子裡的人不會被繼續磨，
		# 等人把他拖出去就好。
		DownSystem.apply_damage(int(body.get("slot_id")), damage_per_second * TICK, Vector3.ZERO)


## 現在誰泡在裡面。
func _soaking() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for body in get_overlapping_bodies():
		if not body.is_in_group("player_characters"):
			continue
		if DownSystem.is_downed(int(body.get("slot_id"))):
			continue
		out.append(body)
	return out


## 中毒的回饋。**純本機**。
##
## 不要借 take_hit(0.0, …) 來偷回饋：那會連帶播受擊動畫、鏡頭震與手把震動，
## 每 0.5 秒來一次很難受，而且會把「我被打了」跟「我站在髒東西裡」混成同一個
## 訊號。這裡只要一聲悶哼加一撮火花——玩家自己看得到他站在紫色的水裡。
func _sting(body: Node3D) -> void:
	Sfx.play(&"hurt", body.global_position, 1.4, -7.0)
	Vfx.burst(&"hit_spark", body.global_position + Vector3.UP * 0.2, Vector3.UP, 0.5)


## 水面：一片薄的半透明紫，鋪在地面上方三公分。
##
## 做法照 scenery.gd 那層斷崖霧氣。**共用材質一定要先 duplicate()**——
## Palette.surface() 回傳的是快取的同一份，直接改會影響到別人。
func _dress_surface() -> void:
	var shape := _shape()
	if shape == null:
		return
	var mesh := BoxMesh.new()
	mesh.size = Vector3(shape.size.x, SURFACE_THICKNESS, shape.size.z)
	var material := Palette.surface(&"corrupt_glow").duplicate()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Palette.color(&"corrupt").lerp(
		Palette.color(&"corrupt_glow"), SURFACE_GLOW_MIX
	)
	material.albedo_color.a = SURFACE_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var surface := MeshInstance3D.new()
	surface.name = "Surface"
	surface.mesh = mesh
	surface.material_override = material
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(surface)
	surface.position = Vector3(0.0, SURFACE_Y - position.y, 0.0)


## 飄上來的霧氣。抄 campfire.gd 的煙。
##
## **不能用 Vfx.burst()**：那 16 個發射器全部是 one_shot 的一次性爆發池，
## 被一個持續性的效果占住就會餓死戰鬥的火花。持續的東西一律自己生一個。
func _spawn_mist() -> void:
	var shape := _shape()
	if shape == null:
		return
	var particles := CPUParticles3D.new()
	particles.name = "Mist"
	particles.amount = MIST_COUNT
	particles.lifetime = MIST_LIFETIME
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	particles.emission_box_extents = Vector3(shape.size.x * 0.5, 0.05, shape.size.z * 0.5)
	particles.direction = Vector3.UP
	particles.spread = 20.0
	# 霧往上飄，所以重力是**正的**。跟營火的煙同一個道理。
	particles.gravity = Vector3.UP * 0.25
	particles.initial_velocity_min = 0.2
	particles.initial_velocity_max = 0.6
	particles.scale_amount_min = 0.4
	particles.scale_amount_max = 0.9
	var ramp := Gradient.new()
	ramp.set_color(0, Color(Palette.color(&"corrupt_glow"), MIST_ALPHA))
	ramp.set_color(1, Color(Palette.color(&"corrupt_glow"), 0.0))
	particles.color_ramp = ramp
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# 少了這一行 color_ramp 完全不會生效，而且不會有任何錯誤訊息。
	material.vertex_color_use_as_albedo = true
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	particles.material_override = material
	var mesh := QuadMesh.new()
	mesh.size = Vector2(MIST_QUAD, MIST_QUAD)
	particles.mesh = mesh
	add_child(particles)
	particles.position = Vector3(0.0, SURFACE_Y - position.y, 0.0)


## 這一池的碰撞形狀。水面與霧氣都照它的大小長，所以只要在關卡檔裡改一次尺寸。
func _shape() -> BoxShape3D:
	var collision := get_node_or_null("Collision") as CollisionShape3D
	if collision == null:
		push_warning("[Pool] %s 底下沒有叫 Collision 的碰撞形狀" % name)
		return null
	return collision.shape as BoxShape3D
