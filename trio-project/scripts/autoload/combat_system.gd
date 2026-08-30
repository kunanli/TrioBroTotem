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
	if attacker.global_position.distance_to(victim.global_position) > HIT_RANGE:
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
