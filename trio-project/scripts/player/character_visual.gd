class_name CharacterVisual
extends Node3D

## 載入角色模型並驅動它的動畫。
##
## 用 AnimationPlayer 直接切換加交叉淡入，不是 AnimationTree。
## AnimationTree 要在編輯器裡拉狀態機，現階段的需求（待機／移動／單次動作）
## 用 play(名稱, 混合時間) 就夠了，而且看得懂、改得動。
## 等到需要 BlendSpace 混合方向與速度時再升級（M1）。
##
## 站著不動的「活著的感覺」不在這裡，在 ProceduralPose——因為模型根本沒有
## idle 動畫。這裡負責把那一層掛上去並餵它移動速度與看向目標。

## 邏輯動畫名稱，以及在模型裡找不到精確名稱時用來比對的關鍵字。
##
## 美術管線（tools/blender_normalize.py）本來就會把動畫改名成 idle/walk/...，
## 但只要管線沒跑、跑壞、或以後換了生成工具，模型帶進來的就會是
## "Armature|Armature|Armature|walking_man|baselayer" 這種字串。
## 硬吃精確名稱的話，角色會變成一動也不動的雕像，而且不會有任何錯誤訊息。
## 這張表讓兩種情況都能動，不必為了管線的 bug 再改一次程式。
const CLIP_ALIASES := {
	&"idle": ["idle", "stand", "breath"],
	&"walk": ["walk"],
	&"run": ["run", "sprint", "jog"],
	&"attack1": ["attack1", "attack"],
	&"attack2": ["attack2"],
	&"attack3": ["attack3"],
	&"attack_dash": ["attack_dash", "dash"],
	&"attack_air": ["attack_air"],
	&"hurt": ["hurt", "damage", "flinch"],
	&"death": ["death", "die", "dead"],
	&"carry": ["carry", "lift", "hold"],
}

const LOCOMOTION: Array[StringName] = [&"idle", &"walk", &"run"]

## 切換動畫的交叉淡入時間。太短會有跳動，太長會拖。
const BLEND_TIME := 0.15

## 攻擊的混合時間要短得多。light_1 的前搖只有 0.08 秒（CombatSpec），
## 用 0.15 秒去混會把整個出手糊掉——玩家看到的是「動作還沒到就已經打中了」。
const ACTION_BLEND_TIME := 0.04

## 走路動畫「原本」對應的移動速度。用來讓播放速度跟著實際移動速度走，
## 否則腳會在地上滑。調到腳不滑為止。
const WALK_REFERENCE_SPEED := 1.6

const SPEED_SCALE_RANGE := Vector2(0.6, 1.8)

## 低於這個速度算站著不動。
const IDLE_SPEED := 0.15

## 模型實際高度與名冊身高容許的落差。超過就在程式裡縮放補救。
const SIZE_TOLERANCE := 0.25

var character_id: StringName = &""

## 命中白閃用的材質。載入時複製一份，之後只切 emission——
## 每次命中才複製會在戰鬥中一直配置記憶體，而且原始材質是共用的，
## 直接改會讓三隻角色一起閃。
##
## TD-09 記的做法是 instance uniform，那需要自訂 shader；
## 匯入的模型用的是 StandardMaterial3D，改 emission 不必寫 shader 就能做到，
## 等 M2 真的要做卡通渲染時再一起換。
var _materials: Array[StandardMaterial3D] = []
var _flash_timer: float = 0.0
var _freeze_timer: float = 0.0

var _player: AnimationPlayer = null
var _model: Node3D = null
var _skeleton: Skeleton3D = null
var _pose: ProceduralPose = null
var _action: StringName = &""

## 邏輯名稱 -> 模型裡真正的動畫名稱。
var _clips: Dictionary = {}

## 沒有 idle 動畫時，走路動畫要停在哪一秒。
var _idle_hold := 0.0


## 回傳是否成功載入模型。失敗時呼叫端應該保留膠囊當備援。
func load_character(id: StringName) -> bool:
	character_id = id
	var entry := CharacterRoster.entry(id)
	if entry.is_empty():
		push_warning("[Visual] 名冊裡沒有 %s" % id)
		return false

	var scene: PackedScene = load(String(entry["model"]))
	if scene == null:
		push_warning("[Visual] 載入失敗：%s" % entry["model"])
		return false

	_model = scene.instantiate()
	_model.rotation.y = deg_to_rad(float(entry.get("yaw_offset", 0.0)))
	add_child(_model)

	if not _fit_size(float(entry.get("height", 1.8))):
		_model.queue_free()
		_model = null
		return false

	_cache_materials(bool(entry.get("alpha", false)))
	_attach_pose(entry)
	_fix_cull_bounds(float(entry.get("height", 1.8)))

	_player = _model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _player == null:
		push_warning("[Visual] %s 裡沒有 AnimationPlayer——模型沒有動畫" % id)
		return true

	# 生成的戰鬥動畫要在查表之前掛上去，這樣它們以精確名稱勝出；
	# 之後美術補進來的 idle/walk/run 仍然走關鍵字比對（TD-12）。
	if _skeleton != null:
		var forged := MotionForge.attach(_player, _skeleton, self, id)
		if forged == 0:
			push_warning("[Visual] %s 沒建出任何生成動畫" % id)
	_resolve_clips()
	# 匯入的動畫預設不循環，移動類的要自己打開，否則走一步就停住。
	for logical in LOCOMOTION:
		var clip := _clip(logical)
		if clip != &"":
			_player.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	_idle_hold = _hold_time(float(entry.get("idle_hold", 0.0)))
	_player.animation_finished.connect(_on_animation_finished)
	return true


## 量模型的真實外框，跟名冊身高對不上就縮放補救。
##
## 為什麼要有這一關：Meshy 的匯出單位不固定，管線沒跑或跑壞就會出現
## 只有 1.5 公分高的角色。那種模型「載入成功」，膠囊備援被收起來，
## 畫面上只剩名字標籤浮在空中——完全看不出是哪裡壞了。
##
## 選擇縮放而不是直接判失敗，是因為這樣遊戲當下就能玩；warning 會一直喊，
## 錯誤不會靜靜溜過去。正解仍然是重跑 tools/run_blender.py normalize-all。
func _fit_size(target_height: float) -> bool:
	var actual := _measure_height()
	if actual <= 0.0001:
		push_warning("[Visual] %s 量不到尺寸，保留膠囊" % character_id)
		return false
	var ratio := target_height / actual
	if absf(ratio - 1.0) <= SIZE_TOLERANCE:
		return true
	_model.scale *= ratio
	# 用 print 不是只用 push_warning：push_warning 只進「偵錯器」分頁，
	# 而大家看的是「輸出」分頁——訊息印在沒人看的地方等於沒印。
	print(
		(
			"[Visual] %s 的模型實際只有 %.4f 公尺，名冊寫 %.2f 公尺，已在程式裡縮放 %.1f 倍補救。"
			+ "正解是重跑美術管線：python tools/run_blender.py normalize-all"
		)
		% [character_id, actual, target_height, ratio]
	)
	return true


## 模型的實際高度（公尺）。
##
## 量骨架的靜置姿勢，不是量網格外框：
##  - 這跟 tools/inspect_model.py 的 gltf_skeleton_height() 算的是同一個東西，
##    也是美術管線 --target-height 實際套用的對象，三邊的數字才對得起來。
##  - 蒙皮網格的 get_aabb() 是綁定空間的範圍，跟節點縮放的關係不直觀，
##    量出來的數字會差好幾個數量級（實測過）。
## 沒有骨架的模型（道具之類）才退回量網格。
func _measure_height() -> float:
	var skeletons := _model.find_children("*", "Skeleton3D", true, false)
	if not skeletons.is_empty():
		var skeleton: Skeleton3D = skeletons[0]
		var count := skeleton.get_bone_count()
		if count > 0:
			var to_model := _relative_transform(skeleton)
			var low := INF
			var high := -INF
			for index in count:
				var y := (to_model * skeleton.get_bone_global_rest(index).origin).y
				low = minf(low, y)
				high = maxf(high, y)
			if high > low:
				return high - low
	return _model_aabb().size.y


## 模型底下所有網格的合併外框，換算回模型自己的座標系。
##
## 用逐層相乘而不是 global_transform：這個函式在 add_child() 之後馬上被呼叫，
## global_transform 需要節點已經在場景樹裡，時機一有變動就會噴
## "Condition !is_inside_tree()" 然後回傳單位矩陣，量出來的尺寸全錯。
## 相對變換不依賴場景樹，什麼時候呼叫都對。
func _model_aabb() -> AABB:
	var box := AABB()
	var started := false
	for node in _model.find_children("*", "MeshInstance3D"):
		var mesh: MeshInstance3D = node
		var piece := _relative_transform(mesh) * mesh.get_aabb()
		if started:
			box = box.merge(piece)
		else:
			box = piece
			started = true
	return box


## node 相對於 _model 的變換，沿著父節點一路乘上去。
func _relative_transform(node: Node3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var walker: Node3D = node
	while walker != null and walker != _model:
		result = walker.transform * result
		walker = walker.get_parent() as Node3D
	return result


## 修正蒙皮網格的剔除範圍。
##
## 這是「角色明明是 1.6 公尺卻整個不畫」的真正原因。
##
## 匯出檔把頂點寫在 1/100 的尺度，再用 100 倍的 inverse bind 矩陣補回來
## （實測：頂點外框 0.0150、bind_pose 尺度 100、蒙皮後 1.5046）。這在 glTF 裡
## 合法，但 Godot 拿來做視錐剔除的是 mesh.get_aabb()，也就是**沒有蒙皮**的原始
## 頂點範圍——比真正的幾何小 100 倍。引擎因此以為那是一個 1.6 公分的東西，
## 鏡頭一移動、那個小盒子離開視錐，整隻角色就消失，而且不會有任何錯誤訊息。
##
## 用骨骼靜置範圍算出真實外框並明寫 custom_aabb。留 60% 餘裕給舉手過頭之類
## 超出靜置姿勢的動作。重跑美術管線把頂點寫回正常尺度之後，這一段會算出
## 幾乎一樣的結果，留著也不會有壞處。
func _fix_cull_bounds(target_height: float) -> void:
	if _skeleton == null:
		return
	var low := Vector3(INF, INF, INF)
	var high := -low
	for index in _skeleton.get_bone_count():
		var point := _skeleton.get_bone_global_rest(index).origin
		low = Vector3(minf(low.x, point.x), minf(low.y, point.y), minf(low.z, point.z))
		high = Vector3(maxf(high.x, point.x), maxf(high.y, point.y), maxf(high.z, point.z))
	if not (high.y > low.y):
		return
	var centre := (low + high) * 0.5
	var size := (high - low) * 1.6
	size = Vector3(maxf(size.x, size.y * 0.8), size.y, maxf(size.z, size.y * 0.8))

	for node in _skeleton.find_children("*", "MeshInstance3D", true, false):
		var mesh: MeshInstance3D = node
		if mesh.skin == null:
			continue
		# custom_aabb 是網格自己的區域座標；網格掛在骨架底下，換算過去。
		var to_local := mesh.transform.affine_inverse()
		mesh.custom_aabb = AABB(to_local * (centre - size * 0.5), size)
		# 剖面盒同時也是 LOD 的依據：1.6 公分的盒子在 5 公尺外，引擎算出來的
		# 螢幕佔比幾乎是 0，會挑最粗的 LOD——粗到可能一個三角形都不畫。
		# 視錐剔除只有整個盒子離開畫面才會生效，LOD 卻是「在畫面裡但畫成空的」，
		# 更符合「標籤看得到、人看不到」的症狀。兩個都堵起來。
		mesh.lod_bias = 128.0
		# 真正有效的那一個。custom_aabb 蓋不掉——骨架掛上去之後，引擎每幀會從
		# 骨骼的外框重算實例的剖面盒，把我們設的值覆蓋掉。extra_cull_margin 是
		# 加在「重算之後」的結果上，所以蓋得住，也正是 Godot 文件給這個情況
		# （網格被骨架變形到超出自己的 AABB）開的藥。
		#
		# 實測（重跑正規化之後的資產）：幾何體 1.6000 公尺、剔除盒 0.0159 公尺。
		# 差距來自 inverse bind 矩陣帶的 100 倍——網格座標系與骨骼座標系差 100 倍，
		# 而剖面盒取的是網格座標系。這與資產尺寸無關，重跑管線也修不掉。
		# 餘裕用「公尺」算，不要用骨架空間的單位——這個骨架一單位是 1 公分，
		# 拿它乘出來會得到 1024 這種看不懂的數字。
		mesh.extra_cull_margin = target_height * 4.0


## 把程序化姿態層掛到骨架底下。SkeletonModifier3D 必須是 Skeleton3D 的子節點，
## 引擎才會在動畫寫完姿勢之後呼叫它。
func _attach_pose(entry: Dictionary) -> void:
	var skeletons := _model.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		push_warning("[Visual] %s 沒有 Skeleton3D，跳過程序化姿態" % character_id)
		return
	_skeleton = skeletons[0]
	_pose = ProceduralPose.new()
	_pose.name = "ProceduralPose"
	_pose.configure(entry, self)
	_skeleton.add_child(_pose)


## 建立「邏輯名稱 -> 模型裡真正的動畫名稱」。先找精確名稱，再退回關鍵字比對。
func _resolve_clips() -> void:
	_clips.clear()
	var list := _player.get_animation_list()
	for key in CLIP_ALIASES:
		var logical: StringName = key
		if _player.has_animation(logical):
			_clips[logical] = logical
			continue
		# 生成的片段掛在自己的 library 裡，名字是 "forged/attack1"。
		# 明確查一次，不要靠關鍵字比對去撞——那會隨動畫清單的排序而定。
		var forged := StringName("%s/%s" % [MotionForge.LIBRARY_NAME, logical])
		if _player.has_animation(forged):
			_clips[logical] = forged
			continue
		var keywords: Array = CLIP_ALIASES[logical]
		for item in list:
			var actual: String = item
			var lowered := actual.to_lower()
			for keyword in keywords:
				if lowered.contains(String(keyword)):
					_clips[logical] = StringName(actual)
					break
			if _clips.has(logical):
				break


func _clip(logical: StringName) -> StringName:
	return _clips.get(logical, &"")


## 沒有 idle 時要停在走路動畫的哪一秒。ratio 是 0 到 1 的片段比例。
func _hold_time(ratio: float) -> float:
	var walk := _clip(&"walk")
	if walk == &"":
		return 0.0
	return _player.get_animation(walk).length * clampf(ratio, 0.0, 1.0)


## 複製一份材質給這隻角色用，順便把不該有的半透明關掉。
##
## Meshy 匯出的 glTF 材質一律是 alphaMode: BLEND，Godot 匯入後變成
## TRANSPARENCY_ALPHA_DEPTH_PRE_PASS。但三張貼圖的 alpha 通道全是 1.0
## （實測最小 0.992），根本沒有半透明的內容。留著只有壞處：要逐物件排序、
## 排序錯了整片消失、陰影與深度都要多跑一遍。角色是實心的，關掉。
##
## cull_mode 保持匯入時的雙面，不去動它——關背面剔除頂多多畫幾個三角形，
## 開錯了卻會讓單面的耳朵、毛髮之類整片不見。
##
## 真的需要 alpha 的角色（毛髮卡片、玻璃）在名冊裡寫 "alpha": true。
func _cache_materials(keep_alpha: bool) -> void:
	for node in _model.find_children("*", "MeshInstance3D"):
		var mesh: MeshInstance3D = node
		for surface in mesh.get_surface_override_material_count():
			var source := mesh.get_active_material(surface) as StandardMaterial3D
			if source == null:
				continue
			var copy: StandardMaterial3D = source.duplicate()
			if not keep_alpha and copy.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
				copy.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			mesh.set_surface_override_material(surface, copy)
			_materials.append(copy)


## 命中白閃 0.05 秒（docs/05）。
func flash() -> void:
	_flash_timer = CombatSpec.FLASH_TIME
	for material in _materials:
		material.emission_enabled = true
		material.emission = Color.WHITE
		material.emission_energy_multiplier = 1.6


## 頓幀：只停動畫，不動引擎的 time_scale——那會連物理與網路一起停掉。
func freeze(seconds: float) -> void:
	_freeze_timer = maxf(_freeze_timer, seconds)


func _process(delta: float) -> void:
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			for material in _materials:
				material.emission_enabled = false
	if _freeze_timer > 0.0:
		_freeze_timer -= delta
		if _player != null:
			_player.speed_scale = 0.0 if _freeze_timer > 0.0 else 1.0


func available() -> PackedStringArray:
	return _player.get_animation_list() if _player else PackedStringArray()


## 看向目標（世界座標）。純表演，不同步——三台機器的角色位置本來就一致，
## 各自算的結果一樣，不值得占頻寬。
func set_look_target(point: Vector3) -> void:
	if _pose != null:
		_pose.set_look_target(point)


func clear_look_target() -> void:
	if _pose != null:
		_pose.clear_look_target()


## 依水平速度選待機或移動。單次動作播放中時不打斷它。
func drive(speed: float) -> void:
	if _pose != null:
		_pose.set_motion(speed / WALK_REFERENCE_SPEED)
	if _player == null or _action != &"" or _freeze_timer > 0.0:
		return

	if speed < IDLE_SPEED:
		_stand()
		return

	var wanted := _clip(&"run") if speed > WALK_REFERENCE_SPEED * 1.6 else &""
	if wanted == &"":
		wanted = _clip(&"walk")
	if wanted == &"":
		return
	if _player.current_animation != String(wanted):
		_player.play(wanted, BLEND_TIME)
	elif not _player.is_playing():
		_player.play(wanted)  # 從站姿的暫停狀態恢復
	_player.speed_scale = clampf(
		speed / WALK_REFERENCE_SPEED, SPEED_SCALE_RANGE.x, SPEED_SCALE_RANGE.y
	)


## 站著不動。有 idle 就播 idle；沒有就把走路停在一幀，剩下的交給 ProceduralPose。
##
## 舊版在這裡什麼都不做，結果走路動畫會繼續播——站著原地滑步。
## 也不能用 stop()：那會回到 rest pose，多半是張開手的 T-pose。
func _stand() -> void:
	var idle := _clip(&"idle")
	if idle != &"":
		if _player.current_animation != String(idle):
			_player.play(idle, BLEND_TIME)
		_player.speed_scale = 1.0
		return

	var walk := _clip(&"walk")
	if walk == &"":
		return
	if _player.current_animation != String(walk):
		_player.play(walk, BLEND_TIME)
	if _player.is_playing():
		_player.speed_scale = 1.0
		_player.seek(_idle_hold, true)
		_player.pause()


## 播一次就回到移動狀態的動作（攻擊、受擊等）。
func play_action(logical: StringName) -> bool:
	var clip := _clip(logical)
	if _player == null or clip == &"":
		return false
	_action = clip
	_player.speed_scale = 1.0
	_player.play(clip, ACTION_BLEND_TIME)
	if _pose != null:
		_pose.set_acting(true)
	return true


func _on_animation_finished(finished: StringName) -> void:
	if finished == _action:
		_action = &""
		if _pose != null:
			_pose.set_acting(false)
