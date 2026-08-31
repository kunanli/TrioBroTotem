class_name AttackController
extends Node3D

## 三段連擊與情境攻擊的狀態機（docs/06）。
##
## 單一攻擊鍵，不設輕重擊分鍵——手把配置已經排滿，而長按蓄力與
## Overcooked 基準直接打架（那個基準的核心是回饋要快，蓄力的本質卻是「先等一下」）。
## 變化來自「你正在做什麼」：站著三段連擊、跑動中衝刺撞擊、跳躍中空中下劈。
##
## 判定只在 active 窗口內生效，而且每一次揮擊對同一個目標只算一次——
## 沒有這個限制的話，判定球停留幾幀就會連續觸發好幾次傷害。

enum Phase { IDLE, WINDUP, ACTIVE, RECOVERY }

var phase: int = Phase.IDLE
var combo_index: int = -1

var _spec: Dictionary = {}
var _timer: float = 0.0
var _hitstop: float = 0.0
var _buffered: bool = false
var _already_hit: Array = []
var _owner: PlayerCharacter = null

@onready var _hitbox: Area3D = $HitBox


func setup(player: PlayerCharacter) -> void:
	_owner = player
	# 判定球一直開著，只用 phase 決定要不要掃。反覆開關 monitoring 時，
	# Area3D 需要一個物理幀才會重新建立重疊清單，切換的那幾幀會漏判——
	# 而 active 窗口只有 0.08 秒，漏兩幀就等於漏掉整次攻擊。
	_hitbox.monitoring = true


func busy() -> bool:
	return phase != Phase.IDLE


## 攻擊鍵按下。連擊窗口內會接下一段，其餘情況重新起手。
func press(context: StringName) -> void:
	if phase == Phase.RECOVERY and _spec.get("combo_window", 0.0) > 0.0:
		_buffered = true
		return
	if phase != Phase.IDLE:
		return
	_begin(context, 0)


func _begin(context: StringName, index: int) -> void:
	if context == &"dash":
		_spec = CombatSpec.DASH_ATTACK
	elif context == &"air":
		_spec = CombatSpec.AIR_ATTACK
	else:
		_spec = CombatSpec.step(index)
		combo_index = index
	phase = Phase.WINDUP
	_timer = float(_spec["windup"])
	_already_hit.clear()
	if _owner != null:
		_owner.on_attack_started(_spec)


func _physics_process(delta: float) -> void:
	if _owner == null or not _owner.is_multiplayer_authority():
		return
	# 頓幀：整個攻擊時間軸暫停。只凍結本機的表現，不動引擎的 time_scale——
	# 那會連物理與網路一起停掉，三台機器立刻對不上。
	if _hitstop > 0.0:
		_hitstop -= delta
		return
	if phase == Phase.IDLE:
		return

	_timer -= delta
	if phase == Phase.ACTIVE:
		_scan_hits()
	if _timer > 0.0:
		return

	if phase == Phase.WINDUP:
		phase = Phase.ACTIVE
		_timer = float(_spec["active"])
	elif phase == Phase.ACTIVE:
		phase = Phase.RECOVERY
		_timer = float(_spec["recovery"])
	else:
		_finish()


func _finish() -> void:
	var next := combo_index + 1
	if _buffered and next < CombatSpec.COMBO.size() and _spec.get("combo_window", 0.0) > 0.0:
		_buffered = false
		_begin(&"stand", next)
		return
	phase = Phase.IDLE
	combo_index = -1
	_buffered = false


func _scan_hits() -> void:
	for body in _hitbox.get_overlapping_bodies():
		if body == _owner or body in _already_hit:
			continue
		if not body.has_method("take_hit"):
			continue
		_already_hit.append(body)
		# 命中方向在本機就算得出來，不必等 host 回報——鏡頭要往這個方向頂一下。
		var direction := body.global_position - _owner.global_position
		direction.y = 0.0
		direction = (
			direction.normalized() if direction.length_squared() > 0.001
			else -_owner.facing_basis().z
		)
		CombatSystem.report_hit.rpc_id(
			1, _owner.slot_id, str(body.get_path()),
			float(_spec["damage"]), float(_spec["knockback"])
		)
		# 被打的一方在自己那端的反應要等 host 廣播，但攻擊者這端先閃先冒火花——
		# 這正是 combat_system.gd 註解說的「客戶端可以樂觀播特效，但扣血一律等 host」。
		if body.has_method("on_hit_predicted"):
			body.on_hit_predicted(direction)
		# 命中的頓幀與鏡頭震在本機立刻生效，不等 host——回饋速度優先（docs/05）。
		_hitstop = float(_spec["hitstop"])
		_owner.on_hit_landed(_spec, direction)
