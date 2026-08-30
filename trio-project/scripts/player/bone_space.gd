class_name BoneSpace
extends RefCounted

## 「角色空間的尤拉角」→「骨骼父空間的四元數」的換算，全案只有這一份。
##
## 為什麼需要換算：每根骨頭的靜置朝向都不一樣（上臂朝側邊、小腿朝下、頭朝前），
## 直接對骨頭下旋轉的話，同一組數字在不同骨頭上的意義完全不同，而且換一個模型
## 就要全部重調。所以所有角度都定義在**角色空間**，再共軛換算到骨頭的父空間。
##
## 座標約定（調任何姿勢的數字前先看這裡）：
##   Vector3(X, Y, Z)，單位是度
##   X 正 = 抬頭／後仰      X 負 = 低頭／前傾
##   Y 正 = 向左轉
##   Z 正 = 往角色的右手邊倒
## 所以手臂往外張是「左臂 Z 負、右臂 Z 正」。
##
## 用的人：procedural_pose.gd（每幀疊加）、motion_forge.gd（生成動畫關鍵影格）。
## 兩邊共用同一份換算，姿勢資料才能在兩處通用。


## 算出每根骨頭的換算矩陣。回傳 {骨名: {"index": int, "frame": Basis, "inverse": Basis}}。
##
## 這組矩陣是常數：骨架是角色節點的子孫，兩者的相對關係不隨角色轉向改變，
## 所以算一次就好。用父骨的**靜置**朝向當基準而不是當下姿勢——靜置是靜態值，
## 讀當下姿勢會跟 modifier 的執行順序糾纏在一起。
static func frames(skeleton: Skeleton3D, space: Node3D, names: Array) -> Dictionary:
	var out: Dictionary = {}
	if skeleton == null or space == null:
		return out
	var relative := _relative_basis(skeleton, space)
	for key in names:
		var bone: StringName = key
		var index := skeleton.find_bone(String(bone))
		if index < 0:
			continue
		var parent := skeleton.get_bone_parent(index)
		var rest := Basis.IDENTITY
		if parent >= 0:
			rest = skeleton.get_bone_global_rest(parent).basis
		var frame := (relative * rest).orthonormalized()
		out[bone] = {"index": index, "frame": frame, "inverse": frame.inverse()}
	return out


## 骨架相對於角色節點的朝向，沿著父節點逐層相乘。
##
## 不用 global_transform：它要求節點已經在場景樹裡，時機一有變動就會噴
## "Condition !is_inside_tree()" 然後回傳單位矩陣——換算會靜靜地全部算錯，
## 姿勢看起來只是「有點怪」，很難查。骨架一定是角色節點的子孫，
## 相對變換沿著 transform 一路乘上去就得到了，什麼時候呼叫都對。
static func _relative_basis(skeleton: Skeleton3D, space: Node3D) -> Basis:
	var result := Basis.IDENTITY
	var walker: Node3D = skeleton
	while walker != null and walker != space:
		result = walker.transform.basis * result
		walker = walker.get_parent() as Node3D
	if walker == null:
		push_warning("[BoneSpace] 骨架不在角色節點底下，換算可能不對")
	return result.orthonormalized()


## 把角色空間的尤拉角（度）換成該骨頭父空間的旋轉。
##
## Basis.from_euler 預設是 YXZ 序，也就是先繞 Z、再繞 X、最後繞 Y。
## 對「先轉頭再抬頭」這種需求剛好是對的順序（yaw 在最外層）。
static func local(entry: Dictionary, euler_degrees: Vector3) -> Quaternion:
	if euler_degrees.is_zero_approx():
		return Quaternion.IDENTITY
	var spin := Basis.from_euler(
		Vector3(
			deg_to_rad(euler_degrees.x),
			deg_to_rad(euler_degrees.y),
			deg_to_rad(euler_degrees.z)
		)
	)
	var inverse: Basis = entry["inverse"]
	var frame: Basis = entry["frame"]
	return Quaternion(inverse * spin * frame)
