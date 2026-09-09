class_name BodyShape
extends RefCounted

## 身體有多粗：從蒙皮網格量出軀幹剖面、頭、手的半徑，給防撞層（`arm_guard.gd`）用。
##
## 為什麼不寫死在名冊：三隻的胸寬、頭大小差很多，而且**看骨頭猜不出來**——
## 大頭身的肩骨貼在脊椎旁，兩肩骨距離量出來只有 3–4 公分，那根本不是胸寬。
## `tools/fix_skin_bleed.py` 那一輪已經證明從網格量比看骨頭猜可靠。
##
## 做法：讀 `MeshInstance3D` 的頂點與蒙皮權重（`surface_get_arrays()`），每個頂點
## 歸給權重最大的那根骨，分三群量：
##
##   torso   主骨**不是**手臂／腿／頭、投影落在 Hips→Neck 軸 5%–85% 之間的頂點，
##           到軸的徑向距離；**繞軸分 16 個方向、上下兩段**，各取 90 百分位，再做
##           環狀三格中位數（把只佔一格的尾巴拿掉）。軀幹不是圓的：豬的側面 22、
##           臀 31、正後方的尾巴 61，用一個半徑不是把手推到天邊就是讓手插進肚子。
##   head    主骨是頭的頂點的包圍盒：中心當頭心、三個半長取平均當半徑
##   hand    主骨是手的頂點到「前臂→手」那條線的距離的**中位數**——手的厚度
##
## 幾個「不能直接量」的教訓，第一版全踩過：
##   軀幹用「主骨是 Hips 的頂點到線段的距離」量成 59–61 公分：Meshy 把腿的一半
##   權重給了 Hips（腳離髖 40 公分），肩高的手臂上也有 Hips 為主的頂點。所以改成
##   「投影在軸的 5%–85% 之間、又不是四肢或頭」——用位置挑，不信權重；上限 85%
##   躲掉肩高那一圈的手臂。單一半徑再被尾巴撐大，所以分方向。
##   頭用「到頭心的 95 百分位」會被貓的耳朵撐到 67 公分——所以用包圍盒的平均半長。
##   手用「到手骨原點的距離」會把整截袖子算進來（青蛙的手量成 30 公分）——所以量
##   到前臂軸線的距離；再用中位數而不是 95 百分位，寬袖口才不會把手撐大。
##
## 全部在**骨架的靜置空間**量，一次性，載入時做。量不到（沒有蒙皮、骨名對不上）
## 就回傳 `ok = false`，呼叫端退回身高比例的預設值並警告——不能靜靜地用 0。

const PERCENTILE := 0.90
const HAND_PERCENTILE := 0.5

## 軀幹剖面繞軸分幾個方向。方向 0 是髖骨的 +Z（模型面向 +Z，名冊的 yaw_offset
## 才把它轉成 Godot 的 −Z），順著 +Y 軸的右手定則往下數。
const SECTORS := 16

## 軀幹只收投影落在 Hips→Neck 軸這一段的頂點；上限躲掉肩高那一圈的手臂。
## 軸的下半段是 low、上半段是 high（胸比髖寬，或是反過來——看角色）。
const TORSO_BAND := Vector2(0.05, 0.85)
const TORSO_SPLIT := 0.45

const HEAD_BONES: Array[StringName] = [&"Head", &"head_end", &"headfront"]
const LIMB_BONES: Array[StringName] = [
	&"LeftShoulder", &"LeftUpperArm", &"LeftLowerArm", &"LeftHand",
	&"RightShoulder", &"RightUpperArm", &"RightLowerArm", &"RightHand",
	&"LeftUpperLeg", &"LeftLowerLeg", &"LeftFoot", &"LeftToes",
	&"RightUpperLeg", &"RightLowerLeg", &"RightFoot", &"RightToes",
]

## 量不到時退回的半徑（乘以身高）。三隻量出來的值除以身高大約就是這些。
const FALLBACK := {
	"torso": 0.12,
	"head": 0.30,
	"hand": 0.05,
}


## 量一副骨架底下所有蒙皮網格。回傳：
##   ok            量到了沒有
##   torso_low / torso_high   PackedFloat32Array(SECTORS)，各方向的半徑（公尺）
##   head / hand   半徑（公尺）
##   head_centre   頭心，**Head 骨的局部座標**——執行期用當下的 Head 姿勢乘回去
##   vertices      用了幾個頂點（探針印出來當佐證）
static func measure(skeleton: Skeleton3D) -> Dictionary:
	var out := fallback(skeleton)
	if skeleton == null:
		return out
	var hips := skeleton.find_bone("Hips")
	var neck := skeleton.find_bone("Neck")
	var head := skeleton.find_bone("Head")
	var hands := [skeleton.find_bone("LeftHand"), skeleton.find_bone("RightHand")]
	var elbows := [skeleton.find_bone("LeftLowerArm"), skeleton.find_bone("RightLowerArm")]
	if hips < 0 or neck < 0 or head < 0 or int(hands[0]) < 0 or int(hands[1]) < 0:
		return out
	if int(elbows[0]) < 0 or int(elbows[1]) < 0:
		return out

	var hips_rest := skeleton.get_bone_global_rest(hips)
	var neck_at := skeleton.get_bone_global_rest(neck).origin
	var hand_at: Array[Vector3] = []
	var forearm: Array[Vector3] = []
	for side in 2:
		hand_at.append(skeleton.get_bone_global_rest(hands[side]).origin)
		var elbow_at := skeleton.get_bone_global_rest(elbows[side]).origin
		forearm.append((hand_at[side] - elbow_at).normalized())

	var low: Array = []
	var high: Array = []
	for _sector in SECTORS:
		low.append([] as Array[float])
		high.append([] as Array[float])
	var head_low := Vector3(INF, INF, INF)
	var head_high := -head_low
	var head_count := 0
	var hand_d: Array[float] = []
	var used := 0
	for node in skeleton.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.skin == null or mesh_instance.mesh == null:
			continue  # 武器零件沒有蒙皮，跳過
		var to_skeleton := _relative(mesh_instance, skeleton)
		var bind_bone := _bind_bones(mesh_instance.skin, skeleton)
		for surface in mesh_instance.mesh.get_surface_count():
			var arrays := mesh_instance.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var bones = arrays[Mesh.ARRAY_BONES]
			var weights = arrays[Mesh.ARRAY_WEIGHTS]
			if vertices.is_empty() or bones == null or weights == null:
				continue
			@warning_ignore("integer_division")
			var per: int = bones.size() / vertices.size()
			if per <= 0:
				continue
			for index in vertices.size():
				var best := -1
				var best_weight := 0.0
				for slot in per:
					var weight := float(weights[index * per + slot])
					if weight > best_weight:
						best_weight = weight
						best = int(bones[index * per + slot])
				if best < 0 or best >= bind_bone.size():
					continue
				var bone := int(bind_bone[best])
				if bone < 0:
					continue
				var name := skeleton.get_bone_name(bone)
				var point: Vector3 = to_skeleton * vertices[index]
				used += 1
				if name == &"LeftHand":
					hand_d.append(_line_gap(point, hand_at[0], forearm[0]))
				elif name == &"RightHand":
					hand_d.append(_line_gap(point, hand_at[1], forearm[1]))
				elif HEAD_BONES.has(name):
					head_count += 1
					head_low = head_low.min(point)
					head_high = head_high.max(point)
				elif not LIMB_BONES.has(name):
					var polar := torso_polar(point, hips_rest, neck_at)
					if polar.x < TORSO_BAND.x or polar.x > TORSO_BAND.y:
						continue  # 腿、脖子、肩高的手臂：不是軀幹的粗細
					var side: Array = low if polar.x < TORSO_SPLIT else high
					var bucket: Array[float] = side[sector_of(polar.y)]
					bucket.append(polar.z)
	if head_count == 0 or hand_d.is_empty():
		return out
	var low_profile := _profile(low)
	var high_profile := _profile(high)
	if low_profile.is_empty() or high_profile.is_empty():
		return out
	var half := (head_high - head_low) * 0.5
	var centre := (head_high + head_low) * 0.5
	out["ok"] = true
	out["torso_low"] = low_profile
	out["torso_high"] = high_profile
	out["head"] = (half.x + half.y + half.z) / 3.0
	out["hand"] = _percentile(hand_d, HAND_PERCENTILE)
	out["head_centre"] = skeleton.get_bone_global_rest(head).affine_inverse() * centre
	out["vertices"] = used
	return out


## 量不到時用的預設：身高比例、圓的。`ok` 是 false，讓呼叫端知道要警告。
static func fallback(skeleton: Skeleton3D) -> Dictionary:
	var height := 1.5
	if skeleton != null:
		var low := INF
		var high := -INF
		for index in skeleton.get_bone_count():
			var y := skeleton.get_bone_global_rest(index).origin.y
			low = minf(low, y)
			high = maxf(high, y)
		if high > low:
			height = high - low
	var round := PackedFloat32Array()
	round.resize(SECTORS)
	round.fill(float(FALLBACK["torso"]) * height)
	return {
		"ok": false,
		"torso_low": round,
		"torso_high": round.duplicate(),
		"head": float(FALLBACK["head"]) * height,
		"hand": float(FALLBACK["hand"]) * height,
		"head_centre": Vector3(0.0, float(FALLBACK["head"]) * height * 0.5, 0.0),
		"vertices": 0,
	}


## 一行成績單。軀幹印各段最細與最粗的方向。
static func describe(shape: Dictionary) -> String:
	var low: PackedFloat32Array = shape["torso_low"]
	var high: PackedFloat32Array = shape["torso_high"]
	return "軀幹 髖 %.0f–%.0f 胸 %.0f–%.0f　頭 %.1f　手 %.1f cm（%s）" % [
		_lowest(low) * 100.0, _highest(low) * 100.0,
		_lowest(high) * 100.0, _highest(high) * 100.0,
		float(shape["head"]) * 100.0,
		float(shape["hand"]) * 100.0,
		("%d 個頂點" % int(shape["vertices"])) if bool(shape["ok"]) else "**量不到，用預設**",
	]


# --- 執行期查詢（防撞層與探針共用） ---------------------------------------------


## 一個點相對軀幹軸的柱座標：(投影 t, 繞軸角度, 徑向距離)。
## 角度以髖骨的 +Z 為 0、繞髖骨的 +Y 算，靜置與執行期都用同一個約定。
static func torso_polar(point: Vector3, hips: Transform3D, neck: Vector3) -> Vector3:
	var axis := neck - hips.origin
	var len2 := maxf(axis.length_squared(), 1e-9)
	var t := (point - hips.origin).dot(axis) / len2
	var radial := point - (hips.origin + axis * t)
	var up := axis.normalized()
	var forward := hips.basis.z - up * hips.basis.z.dot(up)
	if forward.length_squared() < 1e-6:
		forward = hips.basis.x  # 髖骨的 Z 跟軸平行（不會，但不能除以零）
	forward = forward.normalized()
	var right := up.cross(forward)
	var angle := atan2(radial.dot(right), radial.dot(forward))
	return Vector3(t, angle, radial.length())


## 角度落在哪個方向格。
static func sector_of(angle: float) -> int:
	return posmod(int(floor(angle / TAU * SECTORS + 0.5)), SECTORS)


## 這個方向的軀幹半徑（相鄰兩格線性插值）。
static func torso_radius(profile: PackedFloat32Array, angle: float) -> float:
	var slot := angle / TAU * SECTORS
	var base := int(floor(slot))
	var blend := slot - base
	var a := profile[posmod(base, SECTORS)]
	var b := profile[posmod(base + 1, SECTORS)]
	return lerpf(a, b, blend)


## 把一個點推出軀幹（含 `extra`：手的半徑加餘裕）的最短向量；在外面回傳零。
## 投影落在軸兩端之外的用端點當球心（膠囊的帽）。
static func torso_push(
	shape: Dictionary, point: Vector3, hips: Transform3D, neck: Vector3, extra: float
) -> Vector3:
	var polar := torso_polar(point, hips, neck)
	var profile: PackedFloat32Array = (
		shape["torso_low"] if polar.x < TORSO_SPLIT else shape["torso_high"]
	)
	var radius := torso_radius(profile, polar.y) + extra
	var t := clampf(polar.x, 0.0, 1.0)
	var centre := hips.origin + (neck - hips.origin) * t
	var offset := point - centre
	var distance := offset.length()
	if distance >= radius:
		return Vector3.ZERO
	if distance < 1e-5:
		return hips.basis.z.normalized() * radius
	return offset / distance * (radius - distance)


# --- 內部 -------------------------------------------------------------------


## 每個方向格取百分位；空的格用左右鄰居補（環狀）。全空就回傳空陣列。
static func _profile(buckets: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(SECTORS)
	var filled := PackedByteArray()
	filled.resize(SECTORS)
	var any := false
	for sector in SECTORS:
		var bucket: Array[float] = buckets[sector]
		if bucket.is_empty():
			continue
		out[sector] = _percentile(bucket)
		filled[sector] = 1
		any = true
	if not any:
		return PackedFloat32Array()
	for sector in SECTORS:
		if filled[sector]:
			continue
		var before := sector
		var after := sector
		while not filled[before]:
			before = posmod(before - 1, SECTORS)
		while not filled[after]:
			after = posmod(after + 1, SECTORS)
		out[sector] = (out[before] + out[after]) * 0.5
	# 環狀的三格中位數：細長的附屬物（豬的尾巴，正後方那一格 61 公分、兩鄰 31）
	# 只佔一格，中位數把它拿掉；佔三格以上的（青蛙背後的袍子）是真的粗，留著。
	var smoothed := PackedFloat32Array()
	smoothed.resize(SECTORS)
	for sector in SECTORS:
		var trio: Array[float] = [
			out[posmod(sector - 1, SECTORS)], out[sector], out[posmod(sector + 1, SECTORS)]
		]
		trio.sort()
		smoothed[sector] = trio[1]
	return smoothed


## 蒙皮的 bind 索引 → 骨骼索引。匯入的 GLB 通常用名字綁，兩種都處理。
static func _bind_bones(skin: Skin, skeleton: Skeleton3D) -> PackedInt32Array:
	var out := PackedInt32Array()
	for bind in skin.get_bind_count():
		var bone := skin.get_bind_bone(bind)
		if bone < 0:
			bone = skeleton.find_bone(String(skin.get_bind_name(bind)))
		out.append(bone)
	return out


## 網格節點相對於骨架的變換（沿父節點相乘，不碰 global_transform）。
static func _relative(node: Node3D, skeleton: Skeleton3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var walker: Node3D = node
	while walker != null and walker != skeleton:
		result = walker.transform * result
		walker = walker.get_parent() as Node3D
	return result


static func _percentile(values: Array[float], fraction := PERCENTILE) -> float:
	values.sort()
	return values[mini(int(values.size() * fraction), values.size() - 1)]


static func _lowest(profile: PackedFloat32Array) -> float:
	var out := INF
	for value in profile:
		out = minf(out, value)
	return out


static func _highest(profile: PackedFloat32Array) -> float:
	var out := -INF
	for value in profile:
		out = maxf(out, value)
	return out


## 點到一條（無限長）直線的距離。`direction` 要先正規化。
static func _line_gap(point: Vector3, through: Vector3, direction: Vector3) -> float:
	var offset := point - through
	return (offset - direction * offset.dot(direction)).length()
