extends Node3D

## 每一個要打的東西，真的打得到嗎？
##
## 這支探針的存在理由是一次很難看的失誤：上一輪把藤蔓牆從 4 公尺加高到 8 公尺，
## 牆的原點跟著從 y=2 升到 y=4，而 `CombatSystem.report_hit` 那時候是**原點對
## 原點**量距離的——光是垂直落差 4 − 0.85 = 3.15 就超過 `HIT_RANGE` 2.6，
## 於是那道牆變得打不破、第一章通不了關。
##
## 更難發現的是它**看起來有打中**：攻擊者本機的命中球確實跟牆重疊，所以
## 頓幀、鏡頭震、音效全都照放，只有扣血沒發生。而當時的驗證直接呼叫
## `vine.take_hit()`，**繞過了整條攻擊路徑**，所以什麼都沒測到。
##
## 這裡量的是 host 真正拿來做判定的那一支函式 `CombatSystem.reach()`：
## 對每一個 `breakables`／`log_sockets` 的成員，在它周圍的地面上找站得住腳的點，
## 看有沒有任何一個點站得到 `HIT_RANGE` 以內。**沒有的話，那一拍就是死的。**
##
##     godot --headless --path trio-project res://scenes/tools/reach_probe.tscn

## 在目標周圍多大範圍內找立足點、格點多密。
const SEARCH_RADIUS := 5.0
const SEARCH_STEP := 0.5

## 從多高往下打射線找地面，以及地面上多高之內算「站得上去」。
const RAY_TOP := 12.0
const RAY_BOTTOM := -4.0

## 角色原點在身高一半。最矮的那隻最難打到高處，所以用它當標準。
const SHORTEST_HEIGHT := 1.4

## 立足點最高只算到這裡。
##
## **沒有這一條的話這支探針會自己騙自己**：射線往下打會打到目標自己的頂面，
## 於是「站在藤蔓牆頂上」被當成合法的立足點，八公尺高的牆照樣算「打得到」。
## 所以除了把目標本身排除在射線之外，還要卡一個高度——全關最高爬得上去的
## 面是 3.6 公尺的終點台與凹室柱子（docs/07），留 0.4 公尺餘裕。
const HIGHEST_FOOTING := 4.0

var _failures: Array[String] = []


func _ready() -> void:
	var world: Node3D = load("res://scenes/world/test_arena.tscn").instantiate()
	add_child(world)
	# 等一幀，等 _ready 把群組都加完、碰撞形狀都進了物理空間。
	await get_tree().physics_frame
	await get_tree().physics_frame

	var checked := 0
	for group in ["breakables", "log_sockets"]:
		for node in get_tree().get_nodes_in_group(group):
			var target := node as Node3D
			if target == null:
				continue
			checked += 1
			_check(group, target)

	if checked == 0:
		printerr("[Reach] 一個目標都沒找到——探針壞了，不是關卡對了")
		get_tree().quit(1)
		return
	checked += _check_plates()

	for line in _failures:
		printerr("[Reach] %s" % line)
	print("[Reach] 檢查了 %d 個目標，%d 個打不到" % [checked, _failures.size()])
	get_tree().quit(1 if _failures.size() > 0 else 0)


## 每一塊壓力板：門接得到嗎、門檻有沒有人抬得動。
##
## 這兩件事都會**靜默**壞掉。`gate_path` 打錯的話板子照樣亮、門完全不動，
## 沒有任何錯誤訊息，玩家就卡在關卡中間；門檻訂得比最重的一位玩家還高的話，
## 板子看起來完全正常，只是永遠踩不開。
func _check_plates() -> int:
	var heaviest := 0.0
	for value in WeightLadder.SLOT_WEIGHTS:
		heaviest = maxf(heaviest, float(value))
	var checked := 0
	for node in get_tree().get_nodes_in_group("weight_plates"):
		var plate: Node3D = node
		checked += 1
		var gate := plate.get_node_or_null(NodePath(plate.get("gate_path"))) as Node3D
		if gate == null or gate == plate:
			_failures.append("weight_plates/%s：gate_path 指不到門（%s）" % [
				plate.name, plate.get("gate_path")
			])
		var needed := float(plate.get("needed_weight"))
		if needed > heaviest:
			_failures.append("weight_plates/%s：門檻 %.1f 比最重的一位玩家 %.1f 還重，沒有人開得了頭" % [
				plate.name, needed, heaviest
			])
	return checked


func _check(group: String, target: Node3D) -> void:
	var best := INF
	var spot := Vector3.ZERO
	var origin := target.global_position
	var space := get_world_3d().direct_space_state
	var steps := int(SEARCH_RADIUS / SEARCH_STEP)
	for ix in range(-steps, steps + 1):
		for iz in range(-steps, steps + 1):
			var here := Vector3(
				origin.x + float(ix) * SEARCH_STEP, 0.0, origin.z + float(iz) * SEARCH_STEP
			)
			var floor_y := _floor_at(space, here, origin.y, target)
			if is_inf(floor_y) or floor_y > HIGHEST_FOOTING:
				continue
			var eye := Vector3(here.x, floor_y + SHORTEST_HEIGHT * 0.5, here.z)
			var distance := CombatSystem.reach(eye, target)
			if distance < best:
				best = distance
				spot = eye
	if best > CombatSystem.HIT_RANGE:
		_failures.append(
			"%s/%s：最近站得到的地方離 %.2f 公尺，HIT_RANGE 只有 %.2f（最好的立足點 %s）"
			% [group, target.name, best, CombatSystem.HIT_RANGE, spot]
		)


## 這一格的地面高度。找不到地板回傳 INF。
##
## 從目標高度再往上打，才不會從目標本身的內部起算而直接漏掉腳下的地板。
func _floor_at(
	space: PhysicsDirectSpaceState3D, here: Vector3, near_y: float, target: Node3D
) -> float:
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(here.x, near_y + RAY_TOP, here.z), Vector3(here.x, RAY_BOTTOM, here.z)
	)
	# layer 1 是地板與牆（見 test_arena.tscn）。
	query.collision_mask = 1
	# **目標自己不算地板。**
	var body := target as CollisionObject3D
	if body != null:
		query.exclude = [body.get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return INF
	return float(hit["position"].y)
