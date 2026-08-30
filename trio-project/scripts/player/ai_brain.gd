class_name AiBrain
extends Node

## AI 夥伴的行為（docs/08 AI 夥伴規範）。
##
## **成本原則：只做被動配合，不做主動解謎。** 這條規則決定了下面沒有什麼：
## 沒有尋路、沒有謎題判斷、不會自己決定何時疊高、不會主動抓東西。
## 它只做三件事，優先序由上而下：
##
##   1. 扶起倒地的隊友——救援系統就是治療系統（docs/04），這是最高優先
##   2. 打附近的敵人
##   3. 跟著最近的真人
##
## 「疊高時自動就位」在這裡的實作是**站著不動讓人踩**：AI 不會自己決定
## 要疊高（docs/08 明列為不需要會），但玩家跳上來時它不會走開。

## 跟隨距離。太近會擋路互相卡住，太遠會在需要時來不及。
const FOLLOW_DISTANCE := 3.0
const FOLLOW_HYSTERESIS := 1.2

## 看到敵人就過去打的距離，以及打得到的距離。
const ENGAGE_RANGE := 9.0
const ATTACK_RANGE := 1.6

## 願意跑多遠去扶人。超過就先顧自己——AI 不該把自己送進危險。
const REVIVE_RANGE := 14.0

## 卡住多久就跳一下。沒有尋路，跳躍是唯一的脫困手段。
const STUCK_TIME := 0.8
const STUCK_SPEED := 0.6

var _stuck := 0.0
var _was_moving := false
var _target_position := Vector3.ZERO
var _has_target := false


func think(me: PlayerCharacter, intent: PlayerIntent) -> void:
	intent.clear()
	intent.world_move = true
	_has_target = false

	if not _try_revive(me, intent):
		if not _try_fight(me, intent):
			_follow(me)

	if _has_target:
		var offset := _target_position - me.global_position
		offset.y = 0.0
		intent.move = Vector2(offset.x, offset.z).normalized()
	_was_moving = _has_target

	_unstick(me, intent)


## 扶人最優先。倒地的隊友不扶起來，全隊倒地就是本章失敗（docs/04）。
func _try_revive(me: PlayerCharacter, intent: PlayerIntent) -> bool:
	var target: PlayerCharacter = null
	var best := REVIVE_RANGE
	for node in me.get_tree().get_nodes_in_group("player_characters"):
		var other: PlayerCharacter = node
		if other == me or not other.is_downed or other.carried_by_slot >= 0:
			continue
		var distance := me.global_position.distance_to(other.global_position)
		if distance < best:
			best = distance
			target = other
	if target == null:
		return false

	_aim_at(target.global_position, best > PlayerCharacter.REVIVE_RANGE * 0.7)
	intent.interact = best <= PlayerCharacter.REVIVE_RANGE * 0.7
	return true


func _try_fight(me: PlayerCharacter, intent: PlayerIntent) -> bool:
	var target: Node3D = null
	var best := ENGAGE_RANGE
	for node in me.get_tree().get_nodes_in_group("enemies"):
		var enemy: Node3D = node
		if enemy.get("is_broken") == true:
			continue
		var distance := me.global_position.distance_to(enemy.global_position)
		if distance < best:
			best = distance
			target = enemy
	if target == null:
		return false

	_aim_at(target.global_position, best > ATTACK_RANGE)
	intent.attack = best <= ATTACK_RANGE
	return true


## 跟著最近的真人。沒有真人時原地待命——AI 之間互相跟隨會轉圈。
func _follow(me: PlayerCharacter) -> void:
	var target: PlayerCharacter = null
	var best := INF
	for node in me.get_tree().get_nodes_in_group("player_characters"):
		var other: PlayerCharacter = node
		if other == me or other.is_ai:
			continue
		var distance := me.global_position.distance_to(other.global_position)
		if distance < best:
			best = distance
			target = other
	if target == null:
		return

	# 遲滯：已經在走就走到 FOLLOW_DISTANCE 才停，停著則要超過 +HYSTERESIS
	# 才重新起步。沒有這個的話會在門檻上前後抖動。
	#
	# 判斷依據是「上一幀有沒有在走」——這一幀的 intent.move 要等這個函式
	# 回去之後才會填，在這裡讀永遠是 0。
	var threshold: float = FOLLOW_DISTANCE if _was_moving else FOLLOW_DISTANCE + FOLLOW_HYSTERESIS
	_aim_at(target.global_position, best > threshold)


func _aim_at(position: Vector3, should_move: bool) -> void:
	if should_move:
		_target_position = position
		_has_target = true


## 沒有尋路，撞到東西時靠跳躍脫困。這是「只做被動配合」的代價，
## 也是為什麼謎題不得綁定 AI 主動執行（docs/08 設計要求）。
func _unstick(me: PlayerCharacter, intent: PlayerIntent) -> void:
	var wants_to_move := intent.move.length_squared() > 0.0
	var speed := Vector3(me.velocity.x, 0.0, me.velocity.z).length()
	if wants_to_move and speed < STUCK_SPEED:
		_stuck += me.get_physics_process_delta_time()
	else:
		_stuck = 0.0
	if _stuck > STUCK_TIME:
		_stuck = 0.0
		intent.jump = true
