class_name LimbIk
extends RefCounted

## CCD（cyclic coordinate descent）：把一條骨鏈的末端拉到目標點。腳與手共用這一份。
##
## ## 為什麼是 CCD 而不是餘弦定理
##
## 餘弦定理要決定關節往哪一邊彎（pole vector），而那組正負號很容易搞錯，錯了
## 就是膝蓋反折、手肘外翻。CCD 是**從目前的動畫姿勢開始迭代**，所以彎曲方向
## 自然留在動畫擺好的那一邊，不必額外指定，也不會突然翻面。這裡的修正量都很
## 小（幾公分到二十幾公分），兩三輪就收斂。
##
## ## 為什麼不用引擎內建的
##
## Godot 4.7 有 `TwoBoneIK3D`，但**在這個版本它解不出來**：拿一副自己搭的三根
## 骨頭做最小測試，設好 root／middle／end／target 之後末端完全不動，換
## `influence` 也沒有反應。它在 4.7 的文件是整份空的（全新 API），沒有別的線索
## 可以反推。與其繼續猜，不如自己寫——就是下面這二十行。
##
## ## 由末端往根部掃
##
## 越靠近末端的骨頭改動越小，所以這個順序收斂快，而且**根部做最少的功**：
## 腳的大腿不會為了幾公分的修正整條掃過去，手的鎖骨也不會為了搆一下就聳起來。
##
## ## 讀寫的都是「修改器堆疊裡面」的姿勢
##
## 引擎跑完整個堆疊之後會把骨頭姿勢還原，所以這些函式只在
## `_process_modification()` 裡有意義。從外面呼叫 `get_bone_global_pose()` 讀到的
## 永遠只有動畫寫的那一份（實測差了 4.8 公分，那是 `ProceduralPose` 疊的量）。

## 目標超出骨鏈長度時保留的餘裕。完全打直的肢體看起來像義肢，而且 CCD 在
## 極限位置會來回抖。
const REACH_LIMIT := 0.98


## 把 `end_bone` 拉到 `target`（骨架的 global pose 空間）。
##
## `chain` 由根排到末端（腳是大腿、小腿；手是鎖骨、上臂、前臂）。**`end_bone`
## 自己不轉**——它是被帶過去的那一個，朝向由呼叫端決定：腳不管（這一輪不做
## 貼地），手要直接寫（武器焊在上面，朝向才是主導畫面的東西）。
##
## `span` 是這條鏈伸直時能搆多遠（`chain_length()` 量的）。目標超過就先往回收，
## 不然 CCD 會把肢體拉成一直線。傳 0 表示不限制。
##
## `reach_first` 在正式迭代前先由**根往末端**掃一遍。只有大幅度的修正需要它：
## 逐輪量過，修正 50 公分以內的話正常 CCD 三輪就進到 0.02 公分，但**修正 85
## 公分時每一輪只削掉 7%**（0.41 → 0.26 → 0.20 → … → 0.13，八輪還差 13 公分）。
## 那是 CCD 的老問題——起始姿勢離目標太遠。先讓整條鏈朝向目標就跳過那一段。
##
## 腳不需要（一次落腳的修正只有幾公分），而且**開了會改變膝蓋的彎法**：
## 由根往末端掃是大腿先動，那正是 `foot_ik` 選擇由末端掃回來要避開的事。
static func solve(
	skeleton: Skeleton3D,
	chain: Array[int],
	end_bone: int,
	target: Vector3,
	passes: int,
	span: float,
	reach_first := false
) -> void:
	if skeleton == null or chain.is_empty() or end_bone < 0:
		return
	var goal := target
	if span > 0.0:
		var root := skeleton.get_bone_global_pose(chain[0]).origin
		var offset := goal - root
		var reach := span * REACH_LIMIT
		if offset.length() > reach:
			goal = root + offset.normalized() * reach

	if reach_first:
		# 由根往末端掃一遍，讓整條鏈先「朝向」目標。
		for index in chain:
			_aim(skeleton, index, end_bone, goal)
	for _pass in passes:
		for step in chain.size():
			_aim(skeleton, chain[chain.size() - 1 - step], end_bone, goal)


## 把這根骨頭繞著自己的原點轉，讓「骨頭→末端」對上「骨頭→目標」。
static func _aim(skeleton: Skeleton3D, index: int, end_bone: int, goal: Vector3) -> void:
	var here := skeleton.get_bone_global_pose(index)
	var to_end := skeleton.get_bone_global_pose(end_bone).origin - here.origin
	var to_goal := goal - here.origin
	if to_end.length_squared() < 1e-8 or to_goal.length_squared() < 1e-8:
		return
	var spin := Quaternion(to_end.normalized(), to_goal.normalized())
	skeleton.set_bone_global_pose(index, Transform3D(Basis(spin) * here.basis, here.origin))


## 這條鏈從根到末端的**靜置**長度，也就是它伸直時搆得到多遠。
##
## 用靜置而不是當下姿勢：靜置是靜態值，讀當下姿勢會跟修改器的執行順序糾纏
## 在一起，而且它每一幀都不一樣——那不是「這條腿有多長」該有的性質。
static func chain_length(skeleton: Skeleton3D, chain: Array[int], end_bone: int) -> float:
	if skeleton == null or chain.is_empty() or end_bone < 0:
		return 0.0
	var total := 0.0
	var previous := skeleton.get_bone_global_rest(chain[0]).origin
	for step in range(1, chain.size()):
		var here := skeleton.get_bone_global_rest(chain[step]).origin
		total += previous.distance_to(here)
		previous = here
	return total + previous.distance_to(skeleton.get_bone_global_rest(end_bone).origin)


## 依骨骼名稱找出一條鏈。**少一根就整條放棄**——半條鏈解出來的姿勢比不解更難看，
## 而且「靜靜地少轉一根骨頭」正是這個專案一路在抓的那類問題。
static func find_chain(skeleton: Skeleton3D, names: Array) -> Array[int]:
	var out: Array[int] = []
	if skeleton == null:
		return out
	for entry in names:
		var index := skeleton.find_bone(String(entry))
		if index < 0:
			return [] as Array[int]
		out.append(index)
	return out
