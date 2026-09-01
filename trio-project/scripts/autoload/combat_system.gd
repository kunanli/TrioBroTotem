extends Node

## 傷害與擊退的權威判定（TD-02）。攻擊者的客戶端只回報「我打到了誰」，
## host 重新確認距離再決定結果——客戶端可以樂觀播特效，但扣血一律等 host。
##
## 誤傷分兩層（docs/04）：**擊退永不可關，扣血可關**。
## 理由是法師的水球永遠要能把隊友推上高台，否則關掉開關就會卡關——
## 也因此任何謎題都不得設計成「必須靠扣血誤傷才能解」。

## host 重驗命中時容許的距離。要比攻擊判定球略大，容納網路落差。
const HIT_RANGE := 2.6

## 大廳可開關，預設關閉。這只影響扣血，不影響擊退。
var friendly_fire_damage: bool = false


func _ready() -> void:
	NetworkService.disconnected.connect(_on_disconnected)


func _on_disconnected() -> void:
	friendly_fire_damage = false


## 攻擊者回報命中。spec 只傳索引與種類，數值一律由 host 從 CombatSpec 查，
## 免得客戶端送個超大傷害過來。
@rpc("any_peer", "call_local", "reliable")
func report_hit(attacker_slot: int, victim_path: String, damage: float, knockback: float) -> void:
	if not NetworkService.is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	var claimed := sender if sender != 0 else 1
	var slot := PlayerRegistry.get_slot(attacker_slot)
	if slot == null or slot.peer_id != claimed:
		return

	var attacker := CarrySystem.find_player(attacker_slot)
	# 標成 Node3D，否則 victim.global_position 會是 Variant，
	# 下面的 direction 就推導不出型別。
	var victim := get_node_or_null(NodePath(victim_path)) as Node3D
	if attacker == null or victim == null or victim == attacker:
		return
	if not victim.has_method("take_hit"):
		return
	if reach(attacker.global_position, victim) > HIT_RANGE:
		return

	var direction := victim.global_position - attacker.global_position
	direction.y = 0.0
	if direction.length_squared() < 0.001:
		direction = -attacker.facing_basis().z
	direction = direction.normalized()

	var kind: StringName = victim.combat_kind() if victim.has_method("combat_kind") else &"player"
	var multiplier := CombatSpec.knockback_multiplier(kind)
	# 擊退往上抬一點，打飛才好看——「打飛小怪不殘忍」是設計的一部分（docs/02）。
	var impulse := (direction + Vector3.UP * 0.45).normalized() * knockback * multiplier

	var dealt := damage
	if kind == &"player" and not friendly_fire_damage:
		dealt = 0.0  # 擊退照樣生效，只有扣血被關掉
	_apply_hit.rpc(victim_path, dealt, impulse)


## 攻擊距離量到**目標碰撞體最近的那一點**，不是原點。
##
## 為什麼要這樣量：原點對原點在「目標比玩家高很多」的時候會整個失效。
## 藤蔓牆從 4 公尺改成 8 公尺之後，它的原點跟著升到 y=4，而玩家的膠囊沒有
## 偏移、站著時原點在 身高/2 ≈ 0.8——**光是垂直落差就 3.2 > 2.6**，
## 水平再貼近都沒用，host 每一次命中都靜默丟掉。
##
## 而攻擊者那一端的 HitBox 是真的跟牆重疊的，所以頓幀、鏡頭震、揮擊音效
## 全部照播，只有扣血沒發生——**一個看起來完全正常的失敗**。整章因此卡死。
##
## 這個改動不會讓攻擊範圍變寬鬆到不合理：候選目標本來就是攻擊者的 HitBox
## 選出來的，host 這一關只是「重驗客戶端沒有從老遠謊報命中」，
## 而量到碰撞體正是 HitBox 當初判定的同一件事。
##
## HIT_RANGE 維持 2.6——docs/07 用它推導藤蔓牆 4 公尺寬的理由寫死在表上，
## 動它會讓那張表失效。
func reach(from: Vector3, victim: Node3D) -> float:
	var bounds := _victim_bounds(victim)
	if bounds.size == Vector3.ZERO:
		return from.distance_to(victim.global_position)
	# 把攻擊者的位置夾進目標的外框，就得到外框上離他最近的那一點。
	var nearest := Vector3(
		clampf(from.x, bounds.position.x, bounds.end.x),
		clampf(from.y, bounds.position.y, bounds.end.y),
		clampf(from.z, bounds.position.z, bounds.end.z)
	)
	return from.distance_to(nearest)


## 目標所有碰撞形狀合起來的世界外框。
##
## 形狀的旋轉**不算**，只取軸對齊的半徑——這個遊戲裡會被打的東西
## （藤蔓牆、膿包、泥偶、玩家）全部是軸對齊的，而多算一點點範圍的後果
## 遠比少算好：少算就是上面那個「打不到但看起來打到了」的無聲失敗。
##
## 認不得的形狀回傳空的 AABB，呼叫端退回原點對原點，也就是舊行為——
## 多一種形狀不會讓整個判定壞掉。
func _victim_bounds(victim: Node3D) -> AABB:
	var body := victim as CollisionObject3D
	if body == null:
		return AABB()
	var merged := AABB()
	var started := false
	for owner_id: int in body.get_shape_owners():
		var owner_transform: Transform3D = body.shape_owner_get_transform(owner_id)
		for index in body.shape_owner_get_shape_count(owner_id):
			var extents := _shape_extents(body.shape_owner_get_shape(owner_id, index))
			if extents == Vector3.ZERO:
				continue
			var centre: Vector3 = body.global_transform * owner_transform.origin
			var piece := AABB(centre - extents, extents * 2.0)
			merged = piece if not started else merged.merge(piece)
			started = true
	return merged if started else AABB()


func _shape_extents(shape: Shape3D) -> Vector3:
	if shape is BoxShape3D:
		return (shape as BoxShape3D).size * 0.5
	if shape is SphereShape3D:
		var radius := (shape as SphereShape3D).radius
		return Vector3(radius, radius, radius)
	if shape is CapsuleShape3D:
		var capsule := shape as CapsuleShape3D
		return Vector3(capsule.radius, capsule.height * 0.5, capsule.radius)
	if shape is CylinderShape3D:
		var cylinder := shape as CylinderShape3D
		return Vector3(cylinder.radius, cylinder.height * 0.5, cylinder.radius)
	return Vector3.ZERO


@rpc("authority", "call_local", "reliable")
func _apply_hit(victim_path: String, damage: float, impulse: Vector3) -> void:
	var victim := get_node_or_null(NodePath(victim_path)) as Node3D
	if victim != null and victim.has_method("take_hit"):
		victim.take_hit(damage, impulse)


@rpc("any_peer", "call_local", "reliable")
func request_friendly_fire(enabled: bool) -> void:
	if not NetworkService.is_host():
		return
	_apply_friendly_fire.rpc(enabled)


@rpc("authority", "call_local", "reliable")
func _apply_friendly_fire(enabled: bool) -> void:
	friendly_fire_damage = enabled
	print("[Combat] 誤傷扣血：%s（擊退永遠開著）" % ("開" if enabled else "關"))
