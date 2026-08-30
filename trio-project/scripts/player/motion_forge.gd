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

	if built > 0:
		if player.has_animation_library(LIBRARY_NAME):
			player.remove_animation_library(LIBRARY_NAME)
		player.add_animation_library(LIBRARY_NAME, library)
	return built


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
	# 受擊與倒下沒有自己的 spec，借連擊第一段的節奏——它是全案最短的，
	# 受擊本來就該最快回到可控狀態。倒下再放慢一倍。
	out[&"hurt"] = _phase_keys(CombatSpec.step(0), MotionClips.HURT, 1.0)
	out[&"death"] = _phase_keys(CombatSpec.step(0), MotionClips.DEATH, 2.6)
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
	var names: Array = []
	var length := 0.0
	for entry in keys:
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
		for item in keys:
			var frame: Dictionary = item
			var pose: Dictionary = frame["pose"]
			var offset: Vector3 = pose.get(bone, Vector3.ZERO)
			var value := BoneSpace.local(entry, offset) * rest
			animation.rotation_track_insert_key(track, float(frame["time"]), value.normalized())
	return animation


## 軌道路徑要相對於 AnimationPlayer 的 root_node，不能寫死。
## 匯入的場景結構每個模型不保證一樣（有的多一層 Armature，有的沒有）。
static func _track_prefix(player: AnimationPlayer, skeleton: Skeleton3D) -> String:
	var root := player.get_node_or_null(player.root_node)
	if root == null:
		return ""
	return String(root.get_path_to(skeleton))
