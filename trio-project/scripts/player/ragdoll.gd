class_name Ragdoll
extends RefCounted

## 用程式從人形骨架生出布娃娃（TD-06）。
##
## 為什麼不用編輯器的 Create Physical Skeleton：那是一次性的產物，綁死在單一模型上。
## 這個專案的角色是生成的，而且會一直換——每換一隻就要重做一次，還要重調一次
## 碰撞形狀。改成從骨架推導，三隻共用同一份參數，之後多幾隻也不用動手。
##
## docs/13 的 TD-06 警告過「一鍵產物必定抽搐」。抽搐的來源是關節太多、形狀太胖、
## 角度沒限制。所以這裡刻意只模擬 13 根主要骨頭（手指、腳趾、脖子全部略過——
## Godot 會自動往上找最近的實體骨當關節父節點），膠囊半徑用身高比例算，
## 手肘與膝蓋用 HINGE 而不是 CONE。
##
## 同步（TD-06）：狀態與觸發衝量同步，骨骼各機自算，根位置 host 權威。
## 這裡只管「怎麼生、怎麼開關」，同步在 PlayerCharacter 那一端。

## 碰撞層：只跟世界（層 1）碰，不跟玩家膠囊或道具碰。
##
## 讓布娃娃跟自己的 CharacterBody3D 互撞會直接爆開——兩個都想佔同一個位置。
## 跟其他玩家互撞則會讓三台機器的模擬各自發散得更快，而 TD-06 本來就
## 不同步骨骼，撞在一起只會放大差異。
const LAYER := 1 << 4
const MASK := 1

## 每根要模擬的骨頭：tip 用來決定膠囊的長度與方向，radius 與 mass 是身高比例。
##
## 略過的骨頭（Neck、Hand、Toes、手指）不是漏掉，是刻意的：少一個關節就少一個
## 抽搐來源，而它們對「摔下去很好笑」這個目標沒有貢獻。
const SEGMENTS := [
	{"bone": &"Hips", "tip": &"Spine", "radius": 0.085, "mass": 0.14, "joint": &"none"},
	{
		"bone": &"Spine", "tip": &"Chest",
		"radius": 0.080, "mass": 0.10, "joint": &"cone", "swing": 22.0,
	},
	{
		"bone": &"Chest", "tip": &"UpperChest",
		"radius": 0.085, "mass": 0.12, "joint": &"cone", "swing": 16.0,
	},
	{
		"bone": &"UpperChest", "tip": &"Neck",
		"radius": 0.085, "mass": 0.10, "joint": &"cone", "swing": 14.0,
	},
	{
		"bone": &"Head", "tip": &"",
		"radius": 0.095, "mass": 0.08, "joint": &"cone", "swing": 32.0,
	},
	{
		"bone": &"LeftUpperArm", "tip": &"LeftLowerArm",
		"radius": 0.045, "mass": 0.030, "joint": &"cone", "swing": 75.0,
	},
	{
		"bone": &"LeftLowerArm", "tip": &"LeftHand",
		"radius": 0.038, "mass": 0.022, "joint": &"hinge",
	},
	{
		"bone": &"RightUpperArm", "tip": &"RightLowerArm",
		"radius": 0.045, "mass": 0.030, "joint": &"cone", "swing": 75.0,
	},
	{
		"bone": &"RightLowerArm", "tip": &"RightHand",
		"radius": 0.038, "mass": 0.022, "joint": &"hinge",
	},
	{
		"bone": &"LeftUpperLeg", "tip": &"LeftLowerLeg",
		"radius": 0.065, "mass": 0.095, "joint": &"cone", "swing": 55.0,
	},
	{
		"bone": &"LeftLowerLeg", "tip": &"LeftFoot",
		"radius": 0.052, "mass": 0.055, "joint": &"hinge",
	},
	{
		"bone": &"RightUpperLeg", "tip": &"RightLowerLeg",
		"radius": 0.065, "mass": 0.095, "joint": &"cone", "swing": 55.0,
	},
	{
		"bone": &"RightLowerLeg", "tip": &"RightFoot",
		"radius": 0.052, "mass": 0.055, "joint": &"hinge",
	},
]

## 葉端骨頭（頭）沒有子骨可以量，用身高比例補一段。
const LEAF_LENGTH := 0.13

## 整隻角色的質量（公斤）。SEGMENTS 的 mass 是佔比，加起來約 1.0。
const TOTAL_MASS := 60.0

## 阻尼。太低會抽搐個不停，太高會像在糖漿裡倒下——這兩個數字是要調的。
const LINEAR_DAMP := 0.35
const ANGULAR_DAMP := 1.2


## 在骨架底下建出模擬器與所有實體骨。回傳模擬器，失敗回 null。
##
## 尺寸全部從骨架自己推導，不必外面餵身高。
static func build(skeleton: Skeleton3D) -> PhysicalBoneSimulator3D:
	if skeleton == null:
		return null
	var unit := _skeleton_unit(skeleton)
	if unit <= 0.0:
		push_warning("[Ragdoll] 量不到骨架尺寸，跳過布娃娃")
		return null

	var simulator := PhysicalBoneSimulator3D.new()
	simulator.name = "Ragdoll"
	simulator.active = false  # 平時不介入，只有真的倒地才開
	skeleton.add_child(simulator)

	var built := 0
	for entry in SEGMENTS:
		var segment: Dictionary = entry
		if _make_bone(simulator, skeleton, segment, unit) != null:
			built += 1
	if built == 0:
		simulator.queue_free()
		return null
	return simulator


## 骨架空間的「一公尺是幾個單位」。
##
## 匯出的骨架不是以公尺為單位（實測 1.6 公尺的角色骨架高 160 單位，
## 因為 Armature 節點帶著 0.01 的縮放）。所有尺寸都要換算，
## 否則膠囊會比角色大一百倍。
static func _skeleton_unit(skeleton: Skeleton3D) -> float:
	var low := INF
	var high := -INF
	for index in skeleton.get_bone_count():
		var y := skeleton.get_bone_global_rest(index).origin.y
		low = minf(low, y)
		high = maxf(high, y)
	return high - low


static func _make_bone(simulator: PhysicalBoneSimulator3D, skeleton: Skeleton3D,
		segment: Dictionary, unit: float) -> PhysicalBone3D:
	var name: StringName = segment["bone"]
	var index := skeleton.find_bone(String(name))
	if index < 0:
		return null

	var rest := skeleton.get_bone_global_rest(index)
	var tip := _tip_offset(skeleton, index, segment["tip"], unit)
	var length := tip.length()
	if length <= 0.0001:
		return null

	var bone := PhysicalBone3D.new()
	bone.name = String(name)
	simulator.add_child(bone)
	bone.set("bone_name", String(name))

	# 膠囊沿著骨頭擺，方向從「骨頭指向子骨」算出來，不假設骨頭的區域 Y 軸朝上。
	# 匯入的骨架軸向不保證一致，假設錯了膠囊會橫著長。
	var along := tip.normalized()
	var basis := _basis_from_up(along)
	bone.body_offset = Transform3D(basis, tip * 0.5)
	bone.transform = rest * bone.body_offset

	var shape := CapsuleShape3D.new()
	shape.radius = float(segment["radius"]) * unit
	shape.height = maxf(length, shape.radius * 2.0 + 0.001)
	var collision := CollisionShape3D.new()
	collision.shape = shape
	bone.add_child(collision)

	bone.mass = float(segment["mass"]) * TOTAL_MASS
	bone.linear_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
	bone.angular_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
	bone.linear_damp = LINEAR_DAMP
	bone.angular_damp = ANGULAR_DAMP
	bone.friction = 0.9
	bone.bounce = 0.0
	bone.collision_layer = LAYER
	bone.collision_mask = MASK
	_apply_joint(bone, segment)
	return bone


## 骨頭到子骨的位移，用該骨頭的區域座標表示。葉端骨頭沿自己的 Y 軸補一段。
static func _tip_offset(skeleton: Skeleton3D, index: int, tip_name: StringName,
		unit: float) -> Vector3:
	var rest := skeleton.get_bone_global_rest(index)
	if tip_name != &"":
		var tip := skeleton.find_bone(String(tip_name))
		if tip >= 0:
			return rest.affine_inverse() * skeleton.get_bone_global_rest(tip).origin
	return Vector3.UP * (LEAF_LENGTH * unit)


## 造一組以 up 為 Y 軸的正交基底。膠囊在 Godot 裡預設沿 Y 長。
static func _basis_from_up(up: Vector3) -> Basis:
	var reference := Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var x := reference.cross(up).normalized()
	var z := up.cross(x).normalized()
	return Basis(x, up, z)


## 關節限制。手肘與膝蓋用 HINGE（只能單向彎），其餘用 CONE 並限制擺幅。
##
## 不設限制就是 TD-06 說的「必定抽搐」：關節可以轉到任意角度，
## 求解器每幀都在跟自己打架，畫面上就是不停顫抖。
static func _apply_joint(bone: PhysicalBone3D, segment: Dictionary) -> void:
	match segment.get("joint", &"cone"):
		&"none":
			bone.joint_type = PhysicalBone3D.JOINT_TYPE_NONE
		&"hinge":
			bone.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE
			bone.set("joint_constraints/angular_limit_enabled", true)
			bone.set("joint_constraints/angular_limit_lower", deg_to_rad(-100.0))
			bone.set("joint_constraints/angular_limit_upper", deg_to_rad(2.0))
		_:
			bone.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
			var swing := float(segment.get("swing", 45.0))
			bone.set("joint_constraints/swing_span", deg_to_rad(swing))
			bone.set("joint_constraints/twist_span", deg_to_rad(swing * 0.5))
