class_name GaitBob
extends SkeletonModifier3D

## 讓身體跟著步子起伏，站著的時候換腳承重。
##
## ## 為什麼需要
##
## 走路片段裡 Hips 的位置軌是**一格死的**（九到十一條位置軌全是單格、範圍 0），
## 只有旋轉在動。人走路時髖每一步升降兩到四公分、跑步還有騰空；這裡的角色是
## 腿在下面動、身體像放在軌道上滑過去——那是「素材直接套上去」最大的一個訊號。
##
## ## 振幅從幾何算，不猜
##
## 兩腳前後分得越開，等長的腿能撐起的髖就越低：`drop = L − √(L² − (d/2)²)`。
## `L` 是腿長、`d` 是兩腳踝在角色空間的前後距離。走路 d ≈ L ≈ 0.53 → 6.9 公分，
## 乘上 `WALK_SHARE`（真人還有膝蓋吸收）就是真人那個量。相位免費附送：雙腳併攏
## 最高、分最開最低。
##
## **走路與跑步的相位相反，這是物理不是口味。** 走路是倒單擺：腳分開時低。
## 跑步是彈簧：腳分開時是**騰空**（高）、腳併攏時是中站立期的壓縮（低）。
## 所以同一個幾何量，走路帶負號往下沉，跑帶正號繞著平均值上下。
##
## 走路**只能往下沉不能往上抬**：這支走路片段的腿本來就快打直（行程／腿長
## 0.99，見 `motion_clips.gd`），往上抬會把腳帶離地面。跑步的騰空往上抬時
## 腳離地是對的。
##
## ## 掛在 FootIk 之前
##
## 這一層移動髖，然後由 `FootIk` 把踏地的腳留在地上（它多鎖了一個「只擋下沉」
## 的垂直方向），膝蓋自然彎。順序反了就是腳跟著髖一起上下飄。
##
## ## 髖的位置每幀寫 `rest + offset`，絕不累加
##
## 動畫沒有 Hips 的位置軌、`RagdollRecovery` 只寫旋轉——所以沒有人會把髖的位置
## 還原。在當下值上加位移的話會逐幀累積成無限上升。

## 走路時往下沉多少（幾何算出來的 drop 的比例）。0.4 讓走路的起伏落在真人的
## 2–3 公分。
const WALK_SHARE := 0.4

## 跑步時繞著平均值上下多少。比走路小——跑步的 d 大很多，drop 本身就大。
const RUN_SHARE := 0.3

## 跑步的平均值用多長的時間常數追。要涵蓋至少一個循環（衝刺約 0.2 秒）。
const RUN_MEAN_TIME := 0.5

## 左右重心：往比較低的那隻腳那一側移多少（公尺），以及兩腳高度差多少算吃滿。
## 連續值、沒有門檻——`foot_ik.gd` 檔頭寫過門檻為什麼會壞。
const SWAY_AMOUNT := 0.015
const SWAY_RANGE := 0.08

## 頭的穩定：走路時 Hips 轉 22 度、Spine 19 度，頭跟著晃。把頭在角色空間的 yaw
## 做指數平滑（`hand_ik.gd` 同一招，只做 yaw），壓掉一半。
const HEAD_STEADY := 0.5
const HEAD_TIME := 0.25

## 站著不動時的重心轉移：往一側移多少、微微下沉多少、多久換一次、換多快。
const SHIFT_X := 0.025
const SHIFT_DIP := 0.008
const SHIFT_EVERY := Vector2(4.0, 7.0)
const SHIFT_TIME := 0.6

## 這一層本身的淡入淡出，以及走↔跑相位切換的混合時間。
const FADE_TIME := 0.12
const BAND_TIME := 0.3

## 出招時髖怎麼走（角色空間，公尺；角色面向 −Z，所以往前是負的 Z）。
##
## 生成的攻擊片段只有手臂與脊椎的旋轉軌——髖、腿、腳從頭到尾不動，上半身在一尊
## 不動的下半身上揮手。這裡補的是重心：蓄力時往後拉開，出手那一刻壓上去（往前
## 往下），收招收過頭再站定。**時間軸就是 CombatSpec 那一筆**（`strike()` 收的
## `spec`），跟片段同源，不會有第二個時鐘；髖往前壓時 `FootIk` 把兩腳留在原地，
## 腿才會彎成弓步——那才是「腿有動」。
const STRIKE_BACK := 0.03
const STRIKE_FORWARD := 0.08
const STRIKE_DOWN := 0.04
const STRIKE_OVERSHOOT := 0.02
## 蓄力在前搖的這個比例到位（與 `motion_forge._swing_keys()` 的 0.85 一致），
## 過衝在後搖的這個比例（與 `MotionClips.FOLLOW_AT` 一致）。
const STRIKE_LOAD_AT := 0.85
const STRIKE_OVERSHOOT_AT := 0.35

## 這一幀髖被壓低了多少（角色空間，公尺；往上抬時是負的）。`FootIk` 讀它，
## 把踏地的腳撐回去**剛好這麼多**——不多不少。多了會把動畫本身的腳往下踩
## 也一併撐起來，reach clamp 一介入水平的鎖就跟著丟了（實測貓的腳滑從 5% 惡化
## 到 15%）。
var sink := 0.0

var _space: Node3D = null
var _built := false
var _hips := -1
var _head := -1
var _left_foot := -1
var _right_foot := -1
var _leg := 0.0
var _hips_rest := Vector3.ZERO
var _parent_inverse := Basis.IDENTITY
var _to_space := Transform3D.IDENTITY
var _from_space := Transform3D.IDENTITY

var _enabled := false
var _moving := false
var _running := false
var _weight := 0.0
var _run_blend := 0.0
var _drop_mean := 0.0
var _drop_seen := false
var _head_yaw := 0.0
var _head_seen := false

## 出招衝量的關鍵點：[時間, 位移]，由 `strike()` 從 spec 建。空的就是沒在出招。
var _strike_keys: Array = []
var _strike_time := 0.0

var _rng := RandomNumberGenerator.new()
var _shift_side := 1.0
var _shift_timer := 0.0
var _shift := Vector3.ZERO


## `owner_space` 是角色空間的基準節點（`CharacterVisual`），與 ProceduralPose 同一個。
## seed 逐隻固定：純表演、不同步，但同一隻每次跑都一樣，方便對圖。
func configure(owner_space: Node3D, seed_name: String) -> void:
	_space = owner_space
	_rng.seed = hash(seed_name)
	_shift_timer = _rng.randf_range(SHIFT_EVERY.x, SHIFT_EVERY.y)


## 出招。`spec` 是 `CombatSpec` 的那一筆（windup／active／recovery，秒），
## `scale` 是 `MotionClips.COMBO_SHAPE` 的幅度倍率（重擊更大）。
func strike(spec: Dictionary, scale: float) -> void:
	var windup := float(spec.get("windup", 0.08))
	var active := float(spec.get("active", 0.08))
	var recovery := float(spec.get("recovery", 0.16))
	var hit := windup + active
	_strike_keys = [
		[0.0, Vector3.ZERO],
		[windup * STRIKE_LOAD_AT, Vector3(0.0, 0.0, STRIKE_BACK * scale)],
		[windup, Vector3(0.0, -STRIKE_DOWN * scale, -STRIKE_FORWARD * scale)],
		[hit, Vector3(0.0, -STRIKE_DOWN * scale, -STRIKE_FORWARD * scale)],
		[hit + recovery * STRIKE_OVERSHOOT_AT, Vector3(0.0, 0.0, STRIKE_OVERSHOOT * scale)],
		[hit + recovery, Vector3.ZERO],
	]
	_strike_time = 0.0


## 每幀由 `CharacterVisual.drive()` 餵。
##   enabled  該不該動——離地、布娃娃、扛東西、一次性動作時都不該
##   moving   在走還是站著（站著改做重心轉移）
##   running  在跑或衝刺（相位相反）
func set_state(enabled: bool, moving: bool, running: bool) -> void:
	_enabled = enabled
	_moving = moving
	_running = running


func _process_modification() -> void:
	var skeleton := get_skeleton()
	if skeleton == null or _space == null:
		return
	if not _built:
		_build(skeleton)
		if not _built:
			active = false
			return

	var delta := get_process_delta_time()
	_weight = lerpf(_weight, 1.0 if _enabled else 0.0, 1.0 - exp(-delta / FADE_TIME))
	_run_blend = lerpf(_run_blend, 1.0 if _running else 0.0, 1.0 - exp(-delta / BAND_TIME))
	if _weight < 0.01:
		_drop_seen = false
		_head_seen = false
		sink = 0.0
		_write_hips(skeleton, Vector3.ZERO)
		return

	var offset := (_gait_offset(skeleton, delta) if _moving else _shift_offset(delta)) * _weight
	offset += _strike_offset(delta) * _weight  # 與走路起伏相加：衝刺中出招兩者都要在
	sink = -offset.y
	_write_hips(skeleton, offset)
	if _moving:
		_steady_head(skeleton, delta)
	else:
		_head_seen = false


## 走路／跑步：髖該往哪裡移（角色空間，公尺）。
func _gait_offset(skeleton: Skeleton3D, delta: float) -> Vector3:
	var left: Vector3 = _to_space * skeleton.get_bone_global_pose(_left_foot).origin
	var right: Vector3 = _to_space * skeleton.get_bone_global_pose(_right_foot).origin
	var half := absf(left.z - right.z) * 0.5
	var drop := _leg - sqrt(maxf(_leg * _leg - half * half, 0.0))
	if not _drop_seen:
		_drop_mean = drop
		_drop_seen = true
	else:
		_drop_mean = lerpf(_drop_mean, drop, 1.0 - exp(-delta / RUN_MEAN_TIME))

	var walk_bob := -drop * WALK_SHARE
	var run_bob := (drop - _drop_mean) * RUN_SHARE
	# 往比較低的那隻腳那一側移。角色空間 +X 是角色的右手邊，所以左腳比較高
	# （右腳在地上）就往 +X。
	var sway := SWAY_AMOUNT * clampf((left.y - right.y) / SWAY_RANGE, -1.0, 1.0)
	# 站著的重心轉移要在開始走的時候收掉，不然會帶著一個歪掉的髖起步。
	_shift = _shift.lerp(Vector3.ZERO, 1.0 - exp(-delta / SHIFT_TIME))
	return Vector3(sway, lerpf(walk_bob, run_bob, _run_blend), 0.0) + _shift


## 站著：每隔幾秒把重心換到另一隻腳上。
func _shift_offset(delta: float) -> Vector3:
	_shift_timer -= delta
	if _shift_timer <= 0.0:
		_shift_side = -_shift_side
		_shift_timer = _rng.randf_range(SHIFT_EVERY.x, SHIFT_EVERY.y)
	var wanted := Vector3(SHIFT_X * _shift_side, -SHIFT_DIP, 0.0)
	_shift = _shift.lerp(wanted, 1.0 - exp(-delta / SHIFT_TIME))
	_drop_seen = false
	return _shift


## 出招衝量這一幀的位移。關鍵點之間用 smoothstep——出手那一段本來就只有幾格，
## 線性會像平移，指數會拖。
func _strike_offset(delta: float) -> Vector3:
	if _strike_keys.is_empty():
		return Vector3.ZERO
	_strike_time += delta
	var last: Array = _strike_keys[_strike_keys.size() - 1]
	if _strike_time >= float(last[0]):
		_strike_keys = []
		return Vector3.ZERO
	for index in range(1, _strike_keys.size()):
		var next: Array = _strike_keys[index]
		if _strike_time > float(next[0]):
			continue
		var here: Array = _strike_keys[index - 1]
		var span := float(next[0]) - float(here[0])
		var u := 1.0 if span <= 0.0 else clampf((_strike_time - float(here[0])) / span, 0.0, 1.0)
		return (here[1] as Vector3).lerp(next[1], smoothstep(0.0, 1.0, u))
	return Vector3.ZERO


## 把角色空間的位移寫成 Hips 的局部位置：**永遠是 rest + offset**（理由見檔頭）。
func _write_hips(skeleton: Skeleton3D, offset: Vector3) -> void:
	var local := _parent_inverse * (_from_space.basis * offset)
	skeleton.set_bone_pose_position(_hips, _hips_rest + local)


## 頭的 yaw 在角色空間做指數平滑，往平滑值扳回一半。
func _steady_head(skeleton: Skeleton3D, delta: float) -> void:
	var pose := skeleton.get_bone_global_pose(_head)
	var in_space := (_to_space.basis * pose.basis).orthonormalized()
	var yaw := in_space.get_euler().y
	if not _head_seen:
		_head_yaw = yaw
		_head_seen = true
	else:
		_head_yaw = lerp_angle(_head_yaw, yaw, 1.0 - exp(-delta / HEAD_TIME))
	var fix := angle_difference(yaw, _head_yaw) * HEAD_STEADY * _weight
	if absf(fix) < 0.0005:
		return
	# 繞角色空間的 Y 轉，換回骨架空間再寫。頭是鏈的末端，轉它不影響別人。
	var spun := _from_space.basis * (Basis(Vector3.UP, fix) * in_space)
	skeleton.set_bone_global_pose(_head, Transform3D(spun.orthonormalized(), pose.origin))


func _build(skeleton: Skeleton3D) -> void:
	_hips = skeleton.find_bone("Hips")
	_head = skeleton.find_bone("Head")
	_left_foot = skeleton.find_bone("LeftFoot")
	_right_foot = skeleton.find_bone("RightFoot")
	var chain := LimbIk.find_chain(skeleton, ["LeftUpperLeg", "LeftLowerLeg"])
	if _hips < 0 or _head < 0 or _left_foot < 0 or _right_foot < 0 or chain.is_empty():
		return
	_to_space = BoneSpace.relative_transform(skeleton, _space)
	_from_space = _to_space.affine_inverse()
	# 腿長要用角色空間的尺度，跟 d 同一個單位——骨架空間的單位不見得是公尺。
	var hip_here: Vector3 = _to_space * skeleton.get_bone_global_rest(chain[0]).origin
	var ankle_here: Vector3 = _to_space * skeleton.get_bone_global_rest(_left_foot).origin
	var knee_here: Vector3 = _to_space * skeleton.get_bone_global_rest(chain[1]).origin
	_leg = hip_here.distance_to(knee_here) + knee_here.distance_to(ankle_here)
	_hips_rest = skeleton.get_bone_rest(_hips).origin
	var parent := skeleton.get_bone_parent(_hips)
	_parent_inverse = (
		skeleton.get_bone_global_rest(parent).basis.inverse() if parent >= 0 else Basis.IDENTITY
	)
	_built = _leg > 0.0
