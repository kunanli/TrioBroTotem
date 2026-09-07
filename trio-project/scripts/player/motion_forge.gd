class_name MotionForge
extends RefCounted

## 用程式建戰鬥動畫，時間軸直接從 CombatSpec 算出來（TD-12）。
##
## 為什麼不烘進 GLB：烘死的檔案不會跟著調過的數字走。判定窗口只有 0.08 秒，
## 動畫與判定一旦分成兩個來源，每次調手感都要兩邊對一次，遲早會飄。
## 這裡的每一格關鍵影格都是「相位起點 + 比例 × 相位長度」，改 CombatSpec 的
## windup，動畫自己跟著變。
##
## 為什麼在載入時建而不是存成資源：骨骼名稱已經是 SkeletonProfileHumanoid，
## 同一份姿勢資料三隻角色通用；軌道路徑則要看模型匯入後的實際結構，寫死會壞。

const LIBRARY_NAME := &"forged"

## 收招時多插一格「站不穩」的中間點。只有 recovery 夠長的招式用得上
## （見 MotionClips.COMBO_SHAPE 的 settle）。
const SETTLE_AT := 0.45
const SETTLE_FACTOR := -0.18

## 不屬於攻擊的生成動畫：自己的時長 ＋ 自己的姿勢資料。
##
## `_phase_keys()` 只讀 windup／active／recovery 三個 key，所以這裡直接寫字面值，
## 不必假裝它是一份 CombatSpec。
##
##   hurt   要快——被打到之後越快回到可控狀態越好，拖長會變成硬直
##   death  慢一倍，倒下要看得出重量
##   jump   蹲 0.05 蹬 0.08，起跳前的預備動作不能長，長了會覺得按下去沒反應
##   land   衝擊是瞬間的（active 0），吸收與站直放在 recovery
const NON_COMBAT := {
	&"hurt": {
		"spec": {"windup": 0.04, "active": 0.06, "recovery": 0.16},
		"frames": MotionClips.HURT,
	},
	&"death": {
		"spec": {"windup": 0.06, "active": 0.34, "recovery": 0.52},
		"frames": MotionClips.DEATH,
	},
	&"jump": {
		"spec": {"windup": 0.05, "active": 0.08, "recovery": 0.20},
		"frames": MotionClips.JUMP,
	},
	&"land": {
		"spec": {"windup": 0.01, "active": 0.06, "recovery": 0.22},
		"frames": MotionClips.LAND,
	},
}

## 從走路改出來的移動片段。步幅倍率、手臂擺動倍率、疊上去的固定姿勢。
##
## 兩支的**步幅一樣**：`RUN_STRIDE` 已經頂到解剖學上限（見 MotionClips 的說明），
## 衝刺買的是姿勢不是步幅。全速那一段靠步頻。
const GAITS := [
	{
		"clip": &"run",
		"stride": MotionClips.RUN_STRIDE,
		"arm_swing": MotionClips.RUN_ARM_SWING,
		"lean": MotionClips.RUN_LEAN,
	},
	{
		"clip": &"sprint",
		"stride": MotionClips.RUN_STRIDE,
		"arm_swing": MotionClips.SPRINT_ARM_SWING,
		"lean": MotionClips.SPRINT_LEAN,
	},
]


## 待機片段的長度。內容是靜態的（呼吸與擺動由 ProceduralPose 疊），
## 所以這個數字只決定「首尾兩格隔多遠」，多長都一樣——但不能是 0，
## `_forge()` 會把長度 0 的片段當成沒東西丟掉。
const IDLE_LENGTH := 2.0


## 建出這隻角色的全部生成動畫，掛進 AnimationPlayer。
##
## 回傳建了幾支。skeleton 找不到需要的骨頭時會少建幾條軌，但不會失敗——
## 少一根手臂總比整個攻擊沒有動畫好。
static func attach(player: AnimationPlayer, skeleton: Skeleton3D, space: Node3D,
		character_id: StringName) -> int:
	if player == null or skeleton == null or space == null:
		return 0
	var swing: Dictionary = MotionClips.SWINGS.get(character_id, MotionClips.PIG_SWING)
	var clips := _build_all(swing)

	var track_root := _track_prefix(player, skeleton)
	if track_root == "":
		push_warning("[Forge] 算不出骨架的軌道路徑，跳過生成動畫")
		return 0

	var library := AnimationLibrary.new()
	var built := 0
	for key in clips:
		var clip_name: StringName = key
		var animation := _forge(clips[clip_name], skeleton, space, track_root)
		if animation == null:
			continue
		library.add_animation(clip_name, animation)
		built += 1

	# 待機與跑步不走 `_build_all()`：一個是靜態的持械架式、一個是從匯入的走路
	# 循環改出來的，兩者都不是「windup → active → recovery」那個形狀。
	var idle := _forge_hold(MotionClips.IDLE.get(character_id, {}), skeleton, space, track_root)
	if idle != null:
		library.add_animation(&"idle", idle)
		built += 1
	# 跑步與衝刺都是從匯入的走路改出來的，只是外插的倍率與疊上去的姿勢不同。
	var walk := _imported_walk(player)
	for recipe in GAITS:
		var gait: Dictionary = recipe
		var made := _forge_gait(walk, skeleton, space, gait)
		if made != null:
			library.add_animation(gait["clip"], made)
			built += 1

	if built > 0:
		if player.has_animation_library(LIBRARY_NAME):
			player.remove_animation_library(LIBRARY_NAME)
		player.add_animation_library(LIBRARY_NAME, library)
	return built


## 靜態的持械站姿。首尾兩格內容一樣，所以循環起來不會跳格。
static func _forge_hold(pose: Dictionary, skeleton: Skeleton3D, space: Node3D,
		track_root: String) -> Animation:
	if pose.is_empty():
		return null
	var animation := _forge(
		[{"time": 0.0, "pose": pose}, {"time": IDLE_LENGTH, "pose": pose}],
		skeleton, space, track_root
	)
	if animation != null:
		animation.loop_mode = Animation.LOOP_LINEAR
	return animation


## 模型自己帶進來的走路片段。生成的那一份不算——名字裡也有 "walk" 的話
## 會撞到，所以只找不在生成 library 裡的。
static func _imported_walk(player: AnimationPlayer) -> Animation:
	for item in player.get_animation_list():
		var name: String = item
		if name.begins_with("%s/" % LIBRARY_NAME):
			continue
		if name.to_lower().contains("walk"):
			return player.get_animation(name)
	return null


## 跑步／衝刺：把走路循環的每一格繞著它自己的平均姿勢外插放大，再疊固定姿勢。
##
## 為什麼不手刻：走路是這三份 GLB 唯一帶進來的動畫，而它有真正的落腳時機。
## 外插的作法把那個節奏原封不動保留下來，只是把步幅與擺手放大——手刻一支
## 跑步最容易露餡的正是落腳的時機，而那正是這裡不需要碰的部分。
##
## 放大是**繞著這條軌自己的平均姿勢**做的，不是繞著骨架的靜置姿勢。
##
## 這一點差很多。第一版是繞靜置姿勢放大：腿沒問題（靜置的腿本來就是直立的，
## 跟走路循環的平均值幾乎一樣），但**手臂的靜置姿勢是平舉的 T 字**，繞著它
## 放大等於「跑得越快、手張得越開」，跑起來像在滑翔。繞平均姿勢放大就只是
## 「同一個擺動、幅度更大」，那才是跑步跟走路真正的差別。
##
## 數學：每一格是 `q`，這條軌的平均是 `mean`，放大後是 `mean.slerp(q, 1.45)`
## ——slerp 的參數超過 1 就是外插，方向不變、轉得更多。最後再乘上前傾。
static func _forge_gait(
	walk: Animation, skeleton: Skeleton3D, space: Node3D, recipe: Dictionary
) -> Animation:
	if walk == null or skeleton == null:
		return null
	var run: Animation = walk.duplicate(true)
	var lean: Dictionary = recipe["lean"]
	var frames := BoneSpace.frames(skeleton, space, lean.keys())
	var touched := 0
	for track in run.get_track_count():
		if run.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			continue
		var bone := StringName(run.track_get_path(track).get_subname(0))
		var index := skeleton.find_bone(String(bone))
		if index < 0:
			continue
		var stretch := float(recipe["stride"])
		if MotionClips.ARM_BONES.has(bone):
			stretch = float(recipe["arm_swing"])
		var mean := _mean_rotation(run, track)
		# 前傾是左乘上去的角色空間旋轉，跟 `_forge()` 寫關鍵影格時同一個約定。
		# 這裡不必再乘 rest——`mean.slerp(value, ...)` 本來就已經是含靜置的完整姿勢。
		var extra := Quaternion.IDENTITY
		if frames.has(bone):
			extra = BoneSpace.local(frames[bone], lean[bone])
		for key in run.track_get_key_count(track):
			var value: Quaternion = run.track_get_key_value(track, key)
			run.track_set_key_value(track, key, (extra * mean.slerp(value, stretch)).normalized())
			touched += 1
	# 數的是**關鍵影格**不是軌道數。被匯入流程壓縮過的軌道還在，只是一格都
	# 讀不到——數軌道的話這裡會通過，然後回傳一支跟走路一模一樣的「跑步」。
	if touched == 0:
		# 走路片段被匯入流程壓縮過就會走到這裡（壓縮軌讀不到關鍵影格）。
		# 靜靜地回傳一支跟走路一模一樣的東西比較糟——那正是這一輪在修的病。
		push_warning("[Forge] 走路片段裡沒有讀得到的旋轉軌，%s 生不出來" % recipe["clip"])
		return null
	run.loop_mode = Animation.LOOP_LINEAR
	return run


## 每支動畫的關鍵影格：{片段名: [{"time": 秒, "pose": {骨名: 角度}}, …]}
static func _build_all(swing: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for index in MotionClips.COMBO_SHAPE.size():
		var shape: Dictionary = MotionClips.COMBO_SHAPE[index]
		out[StringName("attack%d" % (index + 1))] = _swing_keys(
			CombatSpec.step(index), swing, shape
		)
	out[&"attack_dash"] = _swing_keys(
		CombatSpec.DASH_ATTACK, swing, MotionClips.DASH_SHAPE
	)
	out[&"attack_air"] = _swing_keys(
		CombatSpec.AIR_ATTACK, swing, MotionClips.AIR_SHAPE
	)
	# 非攻擊的動作各自寫明時長，不再借 CombatSpec.step(0)。
	#
	# 借的那個寫法只是「找了一個現成的數字」——受擊、倒下、跳躍的節奏跟
	# 「第一段輕擊」沒有任何關係，綁在一起的後果是調連擊會連帶改到跳躍。
	for name in NON_COMBAT:
		var entry: Dictionary = NON_COMBAT[name]
		out[name] = _phase_keys(entry["spec"], entry["frames"], 1.0)
	return out


## 把一次揮擊展開成關鍵影格。時間點全部由 spec 決定。
static func _swing_keys(spec: Dictionary, swing: Dictionary, shape: Dictionary) -> Array:
	var windup := float(spec.get("windup", 0.08))
	var active := float(spec.get("active", 0.08))
	var recovery := float(spec.get("recovery", 0.16))
	var factor := float(shape.get("scale", 1.0))
	var mirror := float(shape.get("mirror", 1.0))

	var charged: Dictionary = MotionClips.scaled(swing["windup"], factor)
	var impact: Dictionary = MotionClips.scaled(swing["impact"], factor)
	if mirror < 0.0:
		charged = MotionClips.mirrored(charged)
		impact = MotionClips.mirrored(impact)

	var keys: Array = [
		{"time": 0.0, "pose": {}},
		# 蓄力在相位結束前就到位，留一小段停頓——停頓才讓人看得出「要出手了」
		{"time": windup * 0.85, "pose": charged},
		# 判定打開的那一刻正好是最極端的姿勢
		{"time": windup, "pose": impact},
		{"time": windup + active, "pose": MotionClips.scaled(impact, 0.9)},
	]
	if bool(shape.get("settle", false)) and recovery > 0.2:
		keys.append({
			"time": windup + active + recovery * SETTLE_AT,
			"pose": MotionClips.scaled(impact, SETTLE_FACTOR),
		})
	keys.append({"time": windup + active + recovery, "pose": {}})
	return keys


## 把「相位 + 比例」的資料換算成秒。stretch 讓同一組資料能拉長成慢動作。
static func _phase_keys(spec: Dictionary, frames: Array, stretch: float) -> Array:
	var windup := float(spec.get("windup", 0.08)) * stretch
	var active := float(spec.get("active", 0.08)) * stretch
	var recovery := float(spec.get("recovery", 0.16)) * stretch
	var starts := {&"windup": 0.0, &"active": windup, &"recovery": windup + active}
	var lengths := {&"windup": windup, &"active": active, &"recovery": recovery}

	var keys: Array = []
	for entry in frames:
		var frame: Dictionary = entry
		var phase: StringName = frame.get("phase", &"active")
		var start := float(starts.get(phase, 0.0))
		var length := float(lengths.get(phase, 0.0))
		keys.append({
			"time": start + length * float(frame.get("at", 0.0)),
			"pose": frame.get("pose", {}),
		})
	return keys


## 關鍵影格 → Animation。每根出現過的骨頭一條 rotation_3d 軌。
static func _forge(keys: Array, skeleton: Skeleton3D, space: Node3D,
		track_root: String) -> Animation:
	# 每一格都先疊上共同底姿（把手臂從 T 字放下來）。**不能只疊有寫到手臂的
	# 那幾格**——沒疊到的那一格手會彈回平舉，而中間是插值，看起來就是甩手。
	var posed: Array = []
	for entry in keys:
		var key: Dictionary = entry
		posed.append({"time": key["time"], "pose": _with_stance(key["pose"])})

	var names: Array = []
	var length := 0.0
	for entry in posed:
		var key: Dictionary = entry
		length = maxf(length, float(key["time"]))
		for bone in key["pose"]:
			if not names.has(bone):
				names.append(bone)
	if names.is_empty() or length <= 0.0:
		return null

	var frames := BoneSpace.frames(skeleton, space, names)
	if frames.is_empty():
		return null

	var animation := Animation.new()
	animation.length = length
	animation.loop_mode = Animation.LOOP_NONE
	for key in frames:
		var bone: StringName = key
		var entry: Dictionary = frames[bone]
		var rest := skeleton.get_bone_rest(int(entry["index"])).basis.get_rotation_quaternion()
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track, NodePath("%s:%s" % [track_root, bone]))
		animation.track_set_interpolation_type(track, Animation.INTERPOLATION_CUBIC)
		for item in posed:
			var frame: Dictionary = item
			var pose: Dictionary = frame["pose"]
			var offset: Vector3 = pose.get(bone, Vector3.ZERO)
			var value := BoneSpace.local(entry, offset) * rest
			animation.rotation_track_insert_key(track, float(frame["time"]), value.normalized())
	return animation


## 一條旋轉軌的平均姿勢。
##
## 四元數不能直接相加平均——`q` 與 `−q` 是同一個旋轉，混著加會互相抵消成
## 一團亂。所以先把每一格都翻到跟第一格同一個半球（內積為負就取負），
## 再相加正規化。走路循環的擺動幅度不大，這個近似夠用。
static func _mean_rotation(animation: Animation, track: int) -> Quaternion:
	var count := animation.track_get_key_count(track)
	if count == 0:
		return Quaternion.IDENTITY
	var first: Quaternion = animation.track_get_key_value(track, 0)
	var sum := Quaternion(0.0, 0.0, 0.0, 0.0)
	for key in count:
		var value: Quaternion = animation.track_get_key_value(track, key)
		if value.dot(first) < 0.0:
			value = -value
		sum = Quaternion(sum.x + value.x, sum.y + value.y, sum.z + value.z, sum.w + value.w)
	var length := Vector4(sum.x, sum.y, sum.z, sum.w).length()
	if length < 0.0001:
		return first
	return Quaternion(sum.x / length, sum.y / length, sum.z / length, sum.w / length)


## 共同底姿加上這一格自己的偏移。
static func _with_stance(pose: Dictionary) -> Dictionary:
	var out: Dictionary = MotionClips.STANCE.duplicate()
	for key in pose:
		var bone: StringName = key
		out[bone] = (out.get(bone, Vector3.ZERO) as Vector3) + (pose[bone] as Vector3)
	return out


## 軌道路徑要相對於 AnimationPlayer 的 root_node，不能寫死。
## 匯入的場景結構每個模型不保證一樣（有的多一層 Armature，有的沒有）。
static func _track_prefix(player: AnimationPlayer, skeleton: Skeleton3D) -> String:
	var root := player.get_node_or_null(player.root_node)
	if root == null:
		return ""
	return String(root.get_path_to(skeleton))
