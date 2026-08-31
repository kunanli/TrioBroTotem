class_name MissionBoard
extends Area3D

## 營地的任務看板（docs/08：走到任務看板 → 出發冒險）。
##
## 用「走過去按互動」而不是選單按鈕，理由與疊高不設按鍵一樣（docs/06）：
## 輕度遊戲的核心動作應該用既有的動詞完成，多一個介面就多一層學習成本。
## 而且走過去這件事本身就是集合的訊號——三個人站在看板前才出發，
## 比誰在選單上點了「開始」清楚得多。
##
## 判定在本機（誰站在這裡、誰按了鍵），出發的決定送給 host（TD-02）。

## 提示牌浮在看板上方多高。
const PROMPT_HEIGHT := 1.6

var _prompt: Label3D = null
var _armed := false


func _ready() -> void:
	add_to_group("mission_boards")
	_prompt = Label3D.new()
	_prompt.name = "Prompt"
	_prompt.position.y = PROMPT_HEIGHT
	_prompt.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_prompt.no_depth_test = true
	_prompt.font_size = 48
	_prompt.outline_size = 12
	add_child(_prompt)
	_refresh_prompt(0)


func _physics_process(_delta: float) -> void:
	var here := 0
	var pressed := false
	for body in get_overlapping_bodies():
		if not body.is_in_group("player_characters"):
			continue
		here += 1
		# 只認本機有權威的那一個角色的按鍵。遠端角色的 _intent 在這一端
		# 是空的（見 player_character 的 _physics_process），問了也沒用。
		if body.has_method("wants_interact") and body.wants_interact():
			pressed = true
	_refresh_prompt(here)

	# 邊緣觸發：按住不放不該一直送請求。
	if pressed and not _armed:
		_armed = true
		GameFlow.request_mission.rpc_id(1)
	elif not pressed:
		_armed = false


func _refresh_prompt(here: int) -> void:
	if here <= 0:
		_prompt.text = "Mission Board"
		return
	_prompt.text = "Chapter 1 - Vine Hollow\nPress E / LT to set out"
