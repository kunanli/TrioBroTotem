class_name GoalZone
extends Area3D

## 高台上的目標區。站上去就通關。
##
## 這不只是給測試者一個「所以呢？」的答案，它同時是 M0 的自動驗收：
## 高台的高度刻意設在單人跳不到、兩層疊高也構不著的位置，所以只要有人站上去，
## 就代表三層疊高真的成立過（TD-05，docs/11 的最高風險項）。
##
## 權威：只有 host 判定，結果廣播。客戶端自己算的話，兩邊的「誰在裡面」
## 會因為位置同步的落差而不一致，通關訊息就會一台跳一台不跳。

signal cleared
signal occupancy_changed(inside: int, needed: int)

## host 重算人數的間隔（秒）。
const RECHECK_INTERVAL := 0.2

## 需要幾個人同時在區域內。1 = 有人站上去就算過。
@export var needed: int = 1


var inside_count: int = 0
var is_cleared: bool = false

var _inside: Dictionary = {}
var _broadcast: int = -1
var _recheck: float = 0.0


func _ready() -> void:
	add_to_group("goal_zones")
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _on_body_entered(body: Node3D) -> void:
	if not NetworkService.is_host():
		return
	var slot := _slot_of(body)
	if slot < 0:
		return
	_inside[slot] = true
	_evaluate()


func _on_body_exited(body: Node3D) -> void:
	if not NetworkService.is_host():
		return
	var slot := _slot_of(body)
	if slot < 0:
		return
	_inside.erase(slot)
	_evaluate()


## 進出事件不足以維持正確性：人可以「站在裡面才倒下」，那時沒有任何
## body_exited 會觸發，人數就會一直算著他。所以除了進出事件，host 也定期重算。
func _physics_process(delta: float) -> void:
	if not NetworkService.is_host():
		return
	_recheck -= delta
	if _recheck <= 0.0:
		_recheck = RECHECK_INTERVAL
		_evaluate()


## 倒地的人不算數——被丟上去的屍體不該算通關。
##
## 只在數字真的變了（或第一次通關）時才廣播，否則每秒五次的重算會變成
## 每秒五次的 RPC。
func _evaluate() -> void:
	var alive := 0
	for key in _inside:
		var slot: int = key
		if not DownSystem.is_downed(slot):
			alive += 1
	var now_cleared := alive >= needed and not is_cleared
	if alive == _broadcast and not now_cleared:
		return
	_broadcast = alive
	_apply_occupancy.rpc(alive, now_cleared)


@rpc("authority", "call_local", "reliable")
func _apply_occupancy(count: int, now_cleared: bool) -> void:
	inside_count = count
	occupancy_changed.emit(count, needed)
	if now_cleared and not is_cleared:
		is_cleared = true
		cleared.emit()
		print("[Goal] 通關——有人站上高台了")


func _slot_of(body: Node3D) -> int:
	if not body.is_in_group("player_characters"):
		return -1
	return int(body.get("slot_id"))
