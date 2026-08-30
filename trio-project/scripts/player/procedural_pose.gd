class_name ProceduralPose
extends SkeletonModifier3D

## 程序化姿態層：在動畫寫完骨骼之後，再疊上呼吸、重心擺動、看向與職業姿態。
##
## 為什麼需要：Meshy 目前只給了走路一支動畫，三隻角色都沒有 idle。
## 站著不動時如果什麼都不做，畫面上就是三尊雕像。與其等美術補動畫，
## 不如把「站著時的生命感」做成程式——順便讓戰士／弓手／法師光看剪影就分得出來。
##
## 為什麼是 SkeletonModifier3D：它由引擎保證在 AnimationPlayer 寫完姿勢「之後」才跑
## （Godot 4.3+ 專門為這件事加的節點）。用普通 Node 在 _process 裡改骨骼會跟動畫搶，
## 誰先誰後看節點順序，很難調。
##
## 座標約定與換算都在 bone_space.gd，生成動畫（motion_forge.gd）用的是同一份，
## 姿勢資料才能兩邊通用。簡述：角色空間的尤拉角，X 正＝抬頭、Y 正＝向左轉、
## Z 正＝往右手邊倒。

## 看向時三段骨骼分攤的比例。全部給頭會變成貓頭鷹。
const LOOK_SHARE := {
	&"Head": 0.6,
	&"Neck": 0.3,
	&"Chest": 0.1,
}

const LOOK_YAW_LIMIT := 70.0
const LOOK_PITCH_LIMIT := 25.0

## 超過上限之後再多這麼多度，看向就完全淡掉——目標繞到背後時
## 與其把脖子扭到極限僵在那裡，不如乾脆放棄，看起來自然得多。
const LOOK_YAW_FADE := 45.0

## 阻尼時間常數（秒）。用 exp 而不是固定步長，60 與 144 fps 的手感才會一致。
const LOOK_TIME := 0.18
const POSE_FADE_TIME := 0.2

## 呼吸與擺動在軀幹上的分配。
const BREATH_SPINE := 0.6
const BREATH_CHEST := 0.4
const SWAY_CHEST := -0.6
const SWAY_HEAD := 0.25

## 由 configure() 從角色名冊填入。
var breath_amplitude := 1.0
var breath_period := 3.4
var sway_amplitude := 1.5
var sway_period := 5.7
var look_speed := 1.0

## 骨骼名稱 -> Vector3（角色空間尤拉角，度）。
var class_pose: Dictionary = {}

## 用來定義「角色空間」的節點（CharacterVisual 本身）。
## 骨架自己的軸向被匯入流程轉過（Armature 的旋轉、模型的 yaw_offset），
## 拿它當基準會很難懂；改用角色節點，上面那組約定才成立。
var space: Node3D = null

var _bones: Array[int] = []
var _names: Array[StringName] = []
var _entries: Array[Dictionary] = []
var _base: Array[Quaternion] = []
var _written: Array[Quaternion] = []
var _index: Dictionary = {}  # StringName -> 在上面幾個陣列裡的位置

var _ready_frames := false
var _clock := 0.0
var _motion := 0.0
var _pose_weight := 1.0
var _pose_target := 1.0
var _look_valid := false
var _look_point := Vector3.ZERO
var _look_yaw := 0.0
var _look_pitch := 0.0


## entry 是 CharacterRoster 的那一筆；owner_space 是角色空間的基準節點。
func configure(entry: Dictionary, owner_space: Node3D) -> void:
	space = owner_space
	var pose: Dictionary = entry.get("pose", {})
	breath_amplitude = float(pose.get("breath_amplitude", breath_amplitude))
	breath_period = maxf(0.1, float(pose.get("breath_period", breath_period)))
	sway_amplitude = float(pose.get("sway_amplitude", sway_amplitude))
	sway_period = maxf(0.1, float(pose.get("sway_period", sway_period)))
	look_speed = float(pose.get("look_speed", look_speed))
	class_pose = pose.get("bones", {})


func set_look_target(point: Vector3) -> void:
	_look_point = point
	_look_valid = true


func clear_look_target() -> void:
	_look_valid = false


## 移動速度（0 到 1，1 代表走路速度以上）。移動時呼吸與擺動要讓位給走路動畫。
func set_motion(amount: float) -> void:
	_motion = clampf(amount, 0.0, 1.0)


## 播放單次動作（攻擊、受擊）時把職業姿態淡掉，免得跟手刻動作對打。
func set_acting(acting: bool) -> void:
	_pose_target = 0.0 if acting else 1.0


func _process_modification() -> void:
	var skeleton := get_skeleton()
	if skeleton == null or space == null:
		return
	if not _ready_frames:
		_build(skeleton)
		if not _ready_frames:
			active = false  # 找不到任何人形骨骼，這一層沒有意義
			return

	var delta := get_process_delta_time()
	_clock += delta
	_pose_weight = lerpf(_pose_weight, _pose_target, 1.0 - exp(-delta / POSE_FADE_TIME))
	_advance_look(delta)

	var wanted := _accumulate()
	for slot in _bones.size():
		var euler: Vector3 = wanted.get(slot, Vector3.ZERO)
		var index := _bones[slot]
		var pose := skeleton.get_bone_pose_rotation(index)

		# 動畫沒有重寫這根骨頭時（例如 idle 用的是暫停的動畫），
		# 讀到的就是我們上一幀寫進去的值。直接往上疊會每幀累積，
		# 角色會慢慢扭成麻花。所以只有在姿勢真的被別人動過時才更新基準。
		if pose != _written[slot]:
			_base[slot] = pose

		if euler.is_zero_approx():
			skeleton.set_bone_pose_rotation(index, _base[slot])
			_written[slot] = _base[slot]
			continue

		var result := (BoneSpace.local(_entries[slot], euler) * _base[slot]).normalized()
		skeleton.set_bone_pose_rotation(index, result)
		_written[slot] = result


## 收集所有會用到的骨骼，換算矩陣交給 BoneSpace 算（只算一次）。
func _build(skeleton: Skeleton3D) -> void:
	var names: Array[StringName] = []
	for key in LOOK_SHARE:
		names.append(key)
	for key in [&"Hips", &"Spine", &"Chest"]:
		if not names.has(key):
			names.append(key)
	for key in class_pose:
		var bone: StringName = key
		if not names.has(bone):
			names.append(bone)

	var frames := BoneSpace.frames(skeleton, space, names)
	for bone in names:
		if not frames.has(bone):
			continue
		var entry: Dictionary = frames[bone]
		var index := int(entry["index"])
		_index[bone] = _bones.size()
		_bones.append(index)
		_names.append(bone)
		_entries.append(entry)
		_base.append(skeleton.get_bone_pose_rotation(index))
		_written.append(Quaternion.IDENTITY)  # 故意跟 _base 不同，第一幀會重新取基準
	_ready_frames = not _bones.is_empty()


func _advance_look(delta: float) -> void:
	var goal_yaw := 0.0
	var goal_pitch := 0.0
	if _look_valid:
		var local := space.global_transform.affine_inverse() * _look_point
		var flat := Vector2(local.x, local.z).length()
		var raw_yaw := rad_to_deg(atan2(-local.x, -local.z))
		var raw_pitch := rad_to_deg(atan2(local.y, maxf(flat, 0.001)))
		var reach := clampf(
			1.0 - (absf(raw_yaw) - LOOK_YAW_LIMIT) / LOOK_YAW_FADE, 0.0, 1.0
		)
		goal_yaw = clampf(raw_yaw, -LOOK_YAW_LIMIT, LOOK_YAW_LIMIT) * reach
		goal_pitch = clampf(raw_pitch, -LOOK_PITCH_LIMIT, LOOK_PITCH_LIMIT) * reach

	var blend := 1.0 - exp(-delta * maxf(look_speed, 0.01) / LOOK_TIME)
	_look_yaw = lerpf(_look_yaw, goal_yaw, blend)
	_look_pitch = lerpf(_look_pitch, goal_pitch, blend)


## 把四層疊成「骨骼位置 -> 尤拉角」。位置是 _bones 的索引，不是骨骼 id。
func _accumulate() -> Dictionary:
	var out: Dictionary = {}

	# ① 呼吸 ② 重心擺動：移動時交給走路動畫，這裡淡掉。
	var calm := 1.0 - _motion
	if calm > 0.01:
		var breath := sin(TAU * _clock / breath_period) * breath_amplitude * calm
		var sway := sin(TAU * _clock / sway_period) * sway_amplitude * calm
		_add(out, &"Spine", Vector3(breath * BREATH_SPINE, 0.0, 0.0))
		_add(out, &"Chest", Vector3(breath * BREATH_CHEST, 0.0, sway * SWAY_CHEST))
		_add(out, &"Hips", Vector3(0.0, 0.0, sway))
		_add(out, &"Head", Vector3(0.0, 0.0, sway * SWAY_HEAD))

	# ③ 看向
	for key in LOOK_SHARE:
		var bone: StringName = key
		var share := float(LOOK_SHARE[bone])
		_add(out, bone, Vector3(_look_pitch * share, _look_yaw * share, 0.0))

	# ④ 職業姿態。移動時減半——走路本身已經有姿態，全套疊上去會變成螃蟹。
	var weight := _pose_weight * (1.0 - 0.5 * _motion)
	if weight > 0.01:
		for key in class_pose:
			var bone: StringName = key
			var offset: Vector3 = class_pose[bone]
			_add(out, bone, offset * weight)
	return out


func _add(out: Dictionary, bone: StringName, euler: Vector3) -> void:
	if not _index.has(bone):
		return
	var slot: int = _index[bone]
	var current: Vector3 = out.get(slot, Vector3.ZERO)
	out[slot] = current + euler
