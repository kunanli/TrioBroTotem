class_name FootIk
extends SkeletonModifier3D

## 站立期把腳鎖在地上，身體從它上面走過去。
##
## 這一層要解的是**腳滑**，不是貼地。關卡目前每一個碰得到的面都是軸對齊的
## 方塊（沒有任何斜面），所以沒有射線、沒有法線貼合——那一半等關卡真的有
## 坡度再說。這裡只做一件事：踏地的那隻腳，世界座標不要動。
##
## ## 為什麼不用 `TwoBoneIK3D`
##
## Godot 4.7 內建了它，但**在這個版本它解不出來**：拿一副自己搭的三根骨頭做
## 最小測試，設好 root／middle／end／target 之後踝關節完全不動，換 `influence`
## 也沒有反應。它在 4.7 的文件是整份空的（全新 API），所以沒有別的線索。
## 與其繼續反推一個沒有文件的東西，不如自己寫——反正只有兩根骨頭。
##
## ## 為什麼用 CCD 而不是餘弦定理
##
## 餘弦定理要決定膝蓋往哪邊彎（pole vector），而那組正負號很容易搞錯，錯了
## 就是膝蓋反折。CCD 是**從目前的動畫姿勢開始迭代**，所以膝蓋自然留在動畫
## 擺好的方向，不必額外指定，也不會突然翻面。而且這裡的修正量很小
## （幾公分到二十幾公分），兩三輪就收斂。
##
## ## 讀寫的都是「修改器堆疊裡面」的姿勢
##
## 引擎在整個堆疊跑完之後會把骨頭姿勢還原（`ragdoll_recovery.gd` 的檔頭在講
## 同一件事）。所以這一層的輸入輸出都只在 `_process_modification()` 裡有意義，
## 從外面呼叫 `get_bone_global_pose()` 是看不到這一層的結果的——`gait_probe`
## 量腳滑時也因此得自己掛一個取樣用的修改器在最後面。

## 三對腿骨。名稱是 `SkeletonProfileHumanoid` 的（TD-07）。
const LEGS := [
	{"upper": &"LeftUpperLeg", "lower": &"LeftLowerLeg", "foot": &"LeftFoot"},
	{"upper": &"RightUpperLeg", "lower": &"RightLowerLeg", "foot": &"RightFoot"},
]

## 判定踏地：**看哪一隻腳在世界空間裡走得比較慢。**
##
## 這是第三個版本，前兩個都壞掉了，兩次都值得記著：
##
## 1. **絕對高度門檻**——三隻的踝關節離地高度是 −0.06 / +0.08 / +0.13 公尺
##    （腳踝不是腳底，三副骨架沉浮也不一），同一個門檻算出來的站立佔比
##    從 0.32 到 0.65 都有。
## 2. **「比較低的那一隻」**——聽起來很對，實際上**那隻腳整個擺盪期間也還是
##    比較低的那一隻**，所以鎖定從來不放開。實測平均拖著 24 公分不放，
##    腳滑反而從 15% 惡化到 35%。
##
## 真正的判準是物理上的定義：**踏在地上的腳在世界空間裡不會動。** 所以逐幀
## 比兩隻腳的世界速度，慢的那一隻在承重。這個判準沒有門檻、沒有正負號、
## 不依賴骨架的絕對高度，換片段換角色都成立。
##
## 速度是從**動畫的姿勢**算的，不是從這一層改完的結果——不然會變成自己
## 回授自己。高度那一條留著當保險：擺盪到最高點時速度會短暫變慢，
## 只靠速度會誤判。單位是腿長的比例。
const DOUBLE_BAND := 0.12

## 鎖定淡入淡出的時間。踏地與離地那一瞬間不能硬切，會「啪」一下。
const FADE_TIME := 0.07

## 一次落腳最多修正多少（腿長的比例）。
##
## 超過就讓鎖定點跟著滑——與其把腿拉直、腳陷進地面，不如承認這一步收不住。
## 這同時是一個訊號：如果它一直在觸發，表示播放倍率那邊的算術沒對，
## 該回去看 `gait_probe` 而不是把這個數字調大。
const MAX_DRAG := 0.5

## CCD 迭代幾輪。修正量小，兩輪就夠；第三輪的改善量已經看不出來。
const PASSES := 2

## 腿長的最大伸展比例。留一點餘裕，不然完全打直的腿看起來像義肢。
const REACH_LIMIT := 0.98

var _legs: Array[Dictionary] = []
var _built := false
var _locking := false
var _weight := 0.0


## 現在該不該鎖腳。由 `CharacterVisual` 每幀餵——離地、倒地、布娃娃、被扛、
## 播一次性動作的時候都不該鎖。
func set_locking(locking: bool) -> void:
	_locking = locking


func _process_modification() -> void:
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	if not _built:
		_build(skeleton)
		if not _built:
			active = false  # 這副骨架沒有腿，這一層沒有意義
			return

	var delta := get_process_delta_time()
	_weight = lerpf(_weight, 1.0 if _locking else 0.0, 1.0 - exp(-delta / FADE_TIME))
	if _weight < 0.01:
		for leg in _legs:
			leg["planted"] = false
			leg["seen"] = false  # 下次啟用時速度要重新起算，不要用停用前的舊值
		return

	var to_world := skeleton.global_transform
	var to_local := to_world.affine_inverse()

	# 兩件事一起看：誰比較低，以及誰在世界空間裡走得比較慢。
	# 兩個都用**動畫的姿勢**算，不含這一層自己改出來的結果。
	var lowest := INF
	var slowest := INF
	for leg in _legs:
		var here: Vector3 = skeleton.get_bone_global_pose(int(leg["foot"])).origin
		leg["ankle"] = here
		var world: Vector3 = to_world * here
		var last: Vector3 = leg["world"]
		leg["speed"] = (
			INF if not bool(leg["seen"]) else Vector2(world.x - last.x, world.z - last.z).length()
		)
		leg["world"] = world
		leg["seen"] = true
		lowest = minf(lowest, here.y)
		slowest = minf(slowest, float(leg["speed"]))

	for entry in _legs:
		var leg: Dictionary = entry
		var ankle: Vector3 = leg["ankle"]
		var planted := (
			float(leg["speed"]) <= slowest
			and ankle.y <= lowest + float(leg["length"]) * DOUBLE_BAND
		)
		var world: Vector3 = leg["world"]
		if planted and not bool(leg["planted"]):
			leg["locked"] = world
		leg["planted"] = planted
		if not planted:
			continue

		# 只鎖水平。垂直交給動畫——這一輪不做貼地，腳該抬多高是它的事。
		var locked: Vector3 = leg["locked"]
		var drag := Vector3(locked.x - world.x, 0.0, locked.z - world.z)
		var limit := float(leg["length"]) * MAX_DRAG
		if drag.length() > limit:
			# 收不住了：讓鎖定點跟著往前滑，下一幀從新的位置繼續鎖。
			drag = drag.normalized() * limit
			leg["locked"] = world + drag
		_solve(skeleton, leg, to_local * (world + drag * _weight))


## CCD：從動畫擺好的姿勢開始，逐骨把「骨頭到腳踝」轉向「骨頭到目標」。
##
## 由末端往根部掃，因為越靠近末端的骨頭改動越小——這樣收斂快，而且大腿
## 不會為了幾公分的修正整條掃過去。
func _solve(skeleton: Skeleton3D, leg: Dictionary, target: Vector3) -> void:
	var foot := int(leg["foot"])
	var hip: Vector3 = skeleton.get_bone_global_pose(int(leg["upper"])).origin
	# 目標超出腿長就往回收，不然 CCD 會把腿拉成一直線。
	var reach := float(leg["length"]) * REACH_LIMIT
	var offset := target - hip
	if offset.length() > reach:
		target = hip + offset.normalized() * reach

	for _pass in PASSES:
		# 鍵是 String 不是 StringName——`_build()` 存進去的就是 String，
		# 用 `&"lower"` 查會查不到，然後 `int(null)` 靜靜地變成 0（也就是 Hips）。
		for key in ["lower", "upper"]:
			var index := int(leg[key])
			var here := skeleton.get_bone_global_pose(index)
			var to_end := skeleton.get_bone_global_pose(foot).origin - here.origin
			var to_goal := target - here.origin
			if to_end.length_squared() < 1e-8 or to_goal.length_squared() < 1e-8:
				continue
			var spin := Quaternion(to_end.normalized(), to_goal.normalized())
			skeleton.set_bone_global_pose(
				index, Transform3D(Basis(spin) * here.basis, here.origin)
			)


## 找出腿骨並量出腿長。腿長是**靜置**姿勢量的，那是這條腿伸直時的長度。
func _build(skeleton: Skeleton3D) -> void:
	_legs.clear()
	for entry in LEGS:
		var names: Dictionary = entry
		var upper := skeleton.find_bone(String(names["upper"]))
		var lower := skeleton.find_bone(String(names["lower"]))
		var foot := skeleton.find_bone(String(names["foot"]))
		if upper < 0 or lower < 0 or foot < 0:
			continue
		var hip := skeleton.get_bone_global_rest(upper).origin
		var knee := skeleton.get_bone_global_rest(lower).origin
		var ankle := skeleton.get_bone_global_rest(foot).origin
		_legs.append({
			"upper": upper,
			"lower": lower,
			"foot": foot,
			"length": hip.distance_to(knee) + knee.distance_to(ankle),
			"planted": false,
			"locked": Vector3.ZERO,
			"ankle": Vector3.ZERO,
			"world": Vector3.ZERO,
			"speed": INF,
			"seen": false,
		})
	_built = _legs.size() == LEGS.size()
