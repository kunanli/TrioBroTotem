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

## 危險區（hazards 群組）的安全邊界，以及泡在裡面時要往外走多遠。
##
## **穿過去沒關係，站在裡面不行。** 人類也會直接淌過毒池，一個永遠不肯過河
## 的隊友比一個會受傷的隊友糟得多——它會卡在池邊來回抖，而門的另一頭沒人。
## 所以這裡擋的只有兩件事：以危險區為目的地，以及沒事泡在裡面。
const HAZARD_MARGIN := 1.0
const HAZARD_ESCAPE := 4.0

var _stuck := 0.0
var _was_moving := false
var _target_position := Vector3.ZERO
var _has_target := false


func think(me: PlayerCharacter, intent: PlayerIntent) -> void:
	intent.clear()
	intent.world_move = true
	_has_target = false

	# 頭上有人就站住。docs/08 寫了「疊高時自動就位＝站著不動讓人踩」，
	# 但先前沒有實作——AI 會扛著你跑去追泥偶，塔還沒疊完就散了。
	# 兩個真人加一個 AI 想上高台時，這是唯一可行的組合。
	if StackSystem.rider_of(me.slot_id) >= 0:
		_was_moving = false
		return

	if not _try_revive(me, intent):
		if not _try_fight(me, intent):
			_follow(me)

	# 目的地在危險區裡就放棄它。站在毒池裡等你的 AI 會自己倒下去，
	# 然後離「全隊倒地＝本章失敗」只剩一步。
	if _has_target and _hazard_at(me, _target_position) != null:
		_has_target = false
	# 沒有目的地卻泡在危險區裡：往外走。_follow 有遲滯，站在人旁邊時不會
	# 產生目的地——少了這一條，它就會安安靜靜地泡到倒。
	if not _has_target:
		var here := _hazard_at(me, me.global_position)
		if here != null:
			_aim_at(_escape_from(me, here), true)

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
		# 倒在危險區裡的人不去扶——先拖出來是人類的工作（Carryable 那條路
		# 已經有了）。跑進去扶只會變成兩個人躺在毒池裡。
		if _hazard_at(me, other.global_position) != null:
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


## 這個點壓在哪一個危險區上（含 HAZARD_MARGIN 的邊界），沒有就回 null。
##
## 距離直接用 CombatSystem.reach()：它算的是「離這個節點的碰撞外框最近有多遠」，
## 正是這裡要的東西，而且它已經被攻擊判定驗過了（藤蔓牆打不破那個血案就是
## 為了它才修的）。用原點對原點的話，一池 8×14 的毒液會被當成一個點。
func _hazard_at(me: PlayerCharacter, where: Vector3) -> Node3D:
	for node in me.get_tree().get_nodes_in_group("hazards"):
		var hazard: Node3D = node
		if CombatSystem.reach(where, hazard) <= HAZARD_MARGIN:
			return hazard
	return null


## 離開這一池要往哪走。就是它的反方向——沒有尋路，這是唯一誠實的答案。
func _escape_from(me: PlayerCharacter, hazard: Node3D) -> Vector3:
	var away := me.global_position - hazard.global_position
	away.y = 0.0
	if away.length_squared() < 0.01:
		away = Vector3.RIGHT
	return me.global_position + away.normalized() * HAZARD_ESCAPE


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
