class_name ArmGuard
extends SkeletonModifier3D

## 防撞層：手撞到另一隻手、軀幹、頭，就連續地推開。掛在修改器堆疊的**最後**。
##
## 為什麼要有這一層：走路片段本身兩手相距 64–94 公分，不打架；打架來自後面疊上去
## 的每一層——職業姿態、副手 IK、生成的攻擊姿勢、鏡像的第二段、轉身傾斜、扛東西。
## 每一支都是人寫的角度，沒有任何一層知道另一隻手在哪、軀幹有多粗。逐格改角度
## 的話下一支動作又撞，所以改成在最後放一層**知道身體形狀**的守門員。
##
## 形狀從網格量（`body_shape.gd`）：軀幹是繞軸 16 個方向、上下兩段的剖面（豬的
## 背後有尾巴，圓的不行）、頭一顆球、每隻手一顆球。每幀對每隻手找一個「在身體外面、
## 又搆得到」的點（`_resolve()`），先用餘弦定理把手肘預彎、再用 CCD（`limb_ik.gd`）
## 把手臂帶過去，手骨的朝向寫回解之前的值——武器焊在手上，朝向不能被防撞改掉。
##
## **持械手是錨。** 兩手相撞時只有空手／副手讓；持械手只躲軀幹與頭，而且先處理，
## 空手看到的才是它最後的位置。不然兩隻手互推會來回抖，而且武器的位置是 `HandIk`
## 穩定過的，不該被空手推走。握著雙手武器時兩手允許靠到握點那麼近（`set_gripping`）。
##
## 推力**沒有阻尼**，每幀算多少推多少。試過兩種阻尼都是錯的：進去時阻尼（0.04 秒）
## 讓攻擊蓄力格一幀插進身體 25–40 公分、推力追了十幾幀才到；放開時阻尼更糟——
## 留著上一幀的推力向量，姿勢一轉那個方向就指進身體裡，量到的是**防撞層自己把手
## 推進肚子 10 公分**。推的量本來就是姿勢的連續函數（穿多深→推多遠是連續的，
## 找到的角度也是二分磨細的），不需要阻尼，加了反而引進上一幀的狀態。
##
## 不推的：前臂對軀幹、武器對身體、腿——`hand_probe` 的 `[Clash]` 表有印前臂，
## 看了再說。

## 分離之後再留多少（公尺）。太小的話兩個球剛好相切，描邊會黏在一起。
const MARGIN := 0.015

## CCD 輪數。出招時一幀要推二三十公分，三輪還差 2 公分，六輪才進到半公分內。
const PASSES := 6

## 推的鏈：上臂、前臂。鎖骨不動——聳肩躲手看起來很怪。
const CHAIN := ["%sUpperArm", "%sLowerArm"]

## 推力小於這個就當沒有，省一次 CCD。
const DEAD_ZONE := 0.0005

## 直接推幾輪（見 `_resolve()`）。
const DIRECT_STEPS := 4

## 握著雙手武器時，兩手允許比握點距離再近這麼多（公尺），IK 的殘差才不會觸發推力。
const GRIP_SLACK := 0.02

## 繞肩膀轉開的掃描：每步幾度、最多幾步（見 `_resolve()`），以及二分磨細幾輪。
## 5 度 × 36 步 = 180 度，整個半球；二分 6 輪把 5 度磨到 0.08 度。
const SWEEP_STEP := deg_to_rad(5.0)
const SWEEP_STEPS := 36
const BISECT_STEPS := 6

## 推超過這麼多（公尺）就讓 CCD 先由根往末端掃一遍（`LimbIk.solve` 的 reach_first）。
const REACH_FIRST_ABOVE := 0.03

var _shape: Dictionary = {}
var _hands: Array[Dictionary] = []
var _enabled := true
var _grip_distance := 0.0
var _hips := -1
var _neck := -1
var _head := -1
var _built := false


## `shape` 是 `BodyShape.measure()` 的結果。
func configure(shape: Dictionary) -> void:
	_shape = shape


## 現在該不該推。由 `CharacterVisual` 每幀餵（布娃娃期間關）。跟 `active` 分開：
## `active` 是外面的總開關（探針的 `--guard=0`），這個是角色狀態的閘門，兩個不打架。
func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	if not enabled:
		for entry in _hands:
			entry["push"] = Vector3.ZERO


## 副手現在握在武器上的話，握點離持械手多遠（公尺；0 = 沒握）。由 `CharacterVisual`
## 每幀餵。握著時兩手允許靠到握點那麼近（再留 GRIP_SLACK）——弓手拉弦的手本來就
## 離弓不遠，用兩顆手球的相切距離去推就是跟 IK 打架；但握點很遠的（法杖 38 公分）
## 仍然照推，IK 淡入時副手橫過身體的那幾幀才不會撞上持械手。
func set_gripping(distance: float) -> void:
	_grip_distance = distance


## 每隻手現在被推了多少（骨架空間）。探針讀這個看有沒有震盪。
func pushes() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for entry in _hands:
		out.append(entry["push"] as Vector3)
	return out


func _process_modification() -> void:
	var skeleton := get_skeleton()
	if skeleton == null or _shape.is_empty() or not _enabled:
		return
	if not _built:
		_build(skeleton)
		if not _built:
			active = false
			return
	var hips := skeleton.get_bone_global_pose(_hips)
	var neck := skeleton.get_bone_global_pose(_neck).origin
	var head_centre: Vector3 = (
		skeleton.get_bone_global_pose(_head) * (_shape["head_centre"] as Vector3)
	)
	var hand_r := float(_shape["hand"])
	# 持械手（錨）先躲軀幹與頭，空手後：空手看到的才是錨**最後**的位置。反過來的話
	# 錨被軀幹推開那一下會撞回剛讓好的空手（青蛙第二段攻擊兩手疊 7 公分就是這樣）。
	for entry in _hands:
		var hand := int(entry["hand"])
		var chain: Array[int] = entry["chain"]
		var here := skeleton.get_bone_global_pose(hand).origin
		var other := Vector3.INF
		if not bool(entry["anchor"]):
			other = skeleton.get_bone_global_pose(int(entry["other"])).origin
		var root := skeleton.get_bone_global_pose(chain[0]).origin
		var goal := _resolve(
			here, root, float(entry["span"]) * LimbIk.REACH_LIMIT,
			hips, neck, head_centre, other, hand_r
		)
		var push := goal - here
		entry["push"] = push
		if push.length() < DEAD_ZONE:
			continue
		var pose := skeleton.get_bone_global_pose(hand)
		var target := goal
		_prebend(skeleton, chain, hand, target, hips)
		# 推得遠（出招時常常一次二十公分）就先由根往末端掃一遍，不然 CCD 從
		# 彎著的手臂開始每輪只削掉一點（limb_ik.gd 的 reach_first 就是為這個）。
		LimbIk.solve(
			skeleton, chain, hand, target, PASSES, float(entry["span"]),
			push.length() > REACH_FIRST_ABOVE
		)
		# 朝向寫回：手是鏈的末端，轉它不影響前面幾根；位置用 CCD 解完的實際值。
		skeleton.set_bone_global_pose(
			hand, Transform3D(pose.basis, skeleton.get_bone_global_pose(hand).origin)
		)


func _build(skeleton: Skeleton3D) -> void:
	_hips = skeleton.find_bone("Hips")
	_neck = skeleton.find_bone("Neck")
	_head = skeleton.find_bone("Head")
	if _hips < 0 or _neck < 0 or _head < 0:
		push_warning("[ArmGuard] 缺軀幹骨（Hips／Neck／Head），這一層關掉")
		return
	var anchor := skeleton.find_bone("RightHand")
	var weapons := WeaponRack.mounted(skeleton)
	if not weapons.is_empty() and int(weapons[0]["bone"]) >= 0:
		anchor = int(weapons[0]["bone"])
	var order: Array[String] = ["Right", "Left"]
	if skeleton.get_bone_name(anchor).begins_with("Left"):
		order = ["Left", "Right"]  # 錨排前面
	for side in order:
		var hand := skeleton.find_bone("%sHand" % side)
		var other := skeleton.find_bone("%sHand" % ("Right" if side == "Left" else "Left"))
		var names: Array = []
		for pattern in CHAIN:
			names.append(String(pattern) % side)
		var chain := LimbIk.find_chain(skeleton, names)
		if hand < 0 or other < 0 or chain.is_empty():
			push_warning("[ArmGuard] 缺 %s 的手臂骨，這一層關掉" % side)
			_hands.clear()
			return
		_hands.append({
			"hand": hand,
			"other": other,
			"chain": chain,
			"span": LimbIk.chain_length(skeleton, chain, hand),
			"push": Vector3.ZERO,
			"anchor": hand == anchor,
		})
	_built = true


## 找一個「在身體外面、又搆得到」的點。
##
## 直接把手沿最短方向推出軀幹常常推到臂長之外——大頭身的手臂短，出招時本來就
## 伸直了，再往外推 CCD 只會把目標剪回臂長內、手還是插在肚子裡（實測殘差 1–7
## 公分，`reach 0.36 / 0.34`）。第二版用「推出身體、拉回球面」交替投影，手指著
## 身體正下方時會來回打轉（青蛙過頂重砍的下壓格仍穿 23 公分）：身體的外面不是
## 凸集，交替投影沒有保證。
##
## 現在分兩步。先**直接推**幾輪（穿 1 公分就推 1 公分，最省），推得到、又在臂長內
## 就用它。推不到（超出臂長）就**把手臂繞著肩膀轉開**：在幾個平面（推出方向、身體
## 前後、左右、上下各張一個）兩個轉向裡 5 度一步往外掃，第一個不穿身的角度二分
## 磨細，挑全部裡面轉得最少的。只掃一個平面的話，推的方向剛好沿著手臂時那個平面
## 是隨便選的，會把手轉到 56 公分外才找到出口（青蛙待機的副手就是這樣）。
## 伸展長度先試現在的、再試臂長上限。找不到就留在原地。
func _resolve(
	here: Vector3,
	root: Vector3,
	reach: float,
	hips: Transform3D,
	neck: Vector3,
	head_centre: Vector3,
	other: Vector3,
	hand_r: float
) -> Vector3:
	var out := _penetration(here, hips, neck, head_centre, other, hand_r)
	if out.length() < DEAD_ZONE:
		return here
	# 一、直接推。
	var direct := here
	for _step in DIRECT_STEPS:
		direct += _penetration(direct, hips, neck, head_centre, other, hand_r)
		if _clear(direct, hips, neck, head_centre, other, hand_r):
			if direct.distance_to(root) <= reach:
				return direct
			break
	# 二、繞肩膀轉。
	var arm := here - root
	var length := arm.length()
	if length < 1e-4:
		return here
	var direction := arm / length
	var planes: Array[Vector3] = []
	for hint in [out.normalized(), hips.basis.z, hips.basis.x, hips.basis.y]:
		var axis := direction.cross(hint)
		if axis.length_squared() > 1e-4:
			planes.append(axis.normalized())
	var best := here
	var best_angle := INF
	for extension in [minf(length, reach), reach]:
		for axis in planes:
			for sign in [1.0, -1.0]:
				var angle := _first_clear(
					root, direction, axis * sign, extension, hips, neck, head_centre, other, hand_r
				)
				if angle >= 0.0 and angle < best_angle:
					best_angle = angle
					best = root + Basis(axis * sign, angle) * direction * extension
		if best_angle < INF:
			return best  # 現在的伸展長度找得到就不必伸直
	return best


## 在一個平面上往外掃，回傳第一個不穿身的角度（二分磨細過）；掃到底都穿就回傳 −1。
func _first_clear(
	root: Vector3,
	direction: Vector3,
	axis: Vector3,
	extension: float,
	hips: Transform3D,
	neck: Vector3,
	head_centre: Vector3,
	other: Vector3,
	hand_r: float
) -> float:
	var previous := 0.0
	for step in range(1, SWEEP_STEPS + 1):
		var angle := step * SWEEP_STEP
		var candidate: Vector3 = root + Basis(axis, angle) * direction * extension
		if not _clear(candidate, hips, neck, head_centre, other, hand_r):
			previous = angle
			continue
		var low := previous
		var high := angle
		for _bisect in BISECT_STEPS:
			var mid := (low + high) * 0.5
			var probe: Vector3 = root + Basis(axis, mid) * direction * extension
			if _clear(probe, hips, neck, head_centre, other, hand_r):
				high = mid
			else:
				low = mid
		return high
	return -1.0


## 這個點有沒有穿進身體。
func _clear(
	point: Vector3,
	hips: Transform3D,
	neck: Vector3,
	head_centre: Vector3,
	other: Vector3,
	hand_r: float
) -> bool:
	return _penetration(point, hips, neck, head_centre, other, hand_r).length() < DEAD_ZONE


## 這個點穿進身體多少：軀幹、頭、另一隻手（錨不看另一隻手）三個推力相加。
func _penetration(
	point: Vector3,
	hips: Transform3D,
	neck: Vector3,
	head_centre: Vector3,
	other: Vector3,
	hand_r: float
) -> Vector3:
	var out := BodyShape.torso_push(_shape, point, hips, neck, hand_r + MARGIN)
	out += _out_of_sphere(point, head_centre, float(_shape["head"]) + hand_r + MARGIN)
	if other.is_finite():
		var apart := hand_r * 2.0 + MARGIN
		if _grip_distance > 0.0:
			apart = minf(apart, maxf(_grip_distance - GRIP_SLACK, 0.0))
		out += _out_of_sphere(point, other, apart)
	return out


## 先把手肘彎到「上臂＋前臂剛好搆到目標」的角度，再交給 CCD。
##
## CCD 對**打直的手臂**沒轍：目標比現在近的時候要彎手肘，但打直時「肘→手」跟
## 「肘→目標」幾乎同方向，`_aim` 算出來的旋轉趨近於零，每輪只削一點（實測貓的
## 手臂伸到 0.41 倍、上限 0.40，六輪還差 5 公分）。餘弦定理直接算出該彎多少，
## 彎的方向沿現在的彎法；完全打直沒有彎法可循時往身體前方彎（手肘本來就往前）。
static func _prebend(
	skeleton: Skeleton3D, chain: Array[int], hand: int, target: Vector3, hips: Transform3D
) -> void:
	if chain.size() < 2:
		return
	var root := skeleton.get_bone_global_pose(chain[0]).origin
	var elbow_pose := skeleton.get_bone_global_pose(chain[1])
	var elbow := elbow_pose.origin
	var tip := skeleton.get_bone_global_pose(hand).origin
	var upper := elbow - root
	var lower := tip - elbow
	var a := upper.length()
	var b := lower.length()
	var d := root.distance_to(target)
	if a < 1e-4 or b < 1e-4 or d < 1e-4:
		return
	var wanted := acos(clampf((a * a + b * b - d * d) / (2.0 * a * b), -1.0, 1.0))
	var current := acos(clampf((-upper).normalized().dot(lower.normalized()), -1.0, 1.0))
	if absf(wanted - current) < 0.01:
		return
	var axis := upper.cross(lower)
	if axis.length_squared() < 1e-6:
		axis = upper.cross(hips.basis.z)  # 打直了：往身體前方彎
		if axis.length_squared() < 1e-6:
			axis = upper.cross(hips.basis.x)
	axis = axis.normalized()
	# 轉哪一邊才會讓內角變成 wanted：兩邊都試，挑對的。
	var best := elbow_pose.basis
	var best_error := INF
	for sign in [1.0, -1.0]:
		var spun := Basis(axis, sign * (current - wanted)) * elbow_pose.basis
		var new_tip: Vector3 = elbow + (Basis(axis, sign * (current - wanted)) * lower)
		var interior := acos(
			clampf((-upper).normalized().dot((new_tip - elbow).normalized()), -1.0, 1.0)
		)
		var error := absf(interior - wanted)
		if error < best_error:
			best_error = error
			best = spun
	skeleton.set_bone_global_pose(chain[1], Transform3D(best, elbow))


## 點在球裡的話，把它推出來的最短向量；剛好在球心就往前推（手通常在身前）。
static func _out_of_sphere(point: Vector3, centre: Vector3, radius: float) -> Vector3:
	var offset := point - centre
	var distance := offset.length()
	if distance >= radius:
		return Vector3.ZERO
	if distance < 1e-5:
		return Vector3.FORWARD * radius
	return offset / distance * (radius - distance)
