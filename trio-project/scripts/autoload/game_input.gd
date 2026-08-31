extends Node

## 輸入動作在程式碼裡註冊，而不是寫進 project.godot 的 [input] 區塊。
##
## 兩個理由：
## 1. 手寫 project.godot 的 InputEvent 序列化格式極易出錯。
## 2. TD-04 的本地分屏需要「同一台機器上分辨哪個裝置」，
##    而 InputMap 的動作預設吃所有裝置。因此讀取一律經過
##    get_move_vector(device_id) 這類函式，不直接呼叫 Input.get_vector()。
##
## 想改成在編輯器裡編輯時，把同名動作加進專案設定即可——
## 下面的註冊會跳過已存在的動作。

const KEY_BINDINGS := {
	"move_forward": [KEY_W, KEY_UP],
	"move_back": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
	"jump": [KEY_SPACE],
	"attack": [KEY_J],
	"grab": [KEY_F],
	"interact": [KEY_E],
	"respawn": [KEY_R],
	"debug_down": [KEY_K],
}

## 手把按鍵對應，依 docs/06-controls-ui.md 的配置表（Xbox 標示）。
const JOY_BINDINGS := {
	"jump": JOY_BUTTON_A,
	"attack": JOY_BUTTON_X,
	"grab": JOY_BUTTON_B,
}

## 扳機是類比軸不是按鍵。依 docs/06：RT 投擲、LT 互動／扶起。
const JOY_TRIGGERS := {
	"throw": JOY_AXIS_TRIGGER_RIGHT,
	"interact": JOY_AXIS_TRIGGER_LEFT,
}

## 扳機壓到多深算按下。
const TRIGGER_THRESHOLD := 0.5

## 滑鼠對應。docs/06 的鍵鼠配置是左鍵攻擊（抓著東西時＝投擲）。
## 鍵盤的 J 保留下來，因為 M0 要在同一台機器上開三個視窗測，
## 用滑鼠會一直搶焦點。
const MOUSE_BINDINGS := {
	"attack": MOUSE_BUTTON_LEFT,
}

## 搖桿的死區。低於這個值視為沒推。
const STICK_DEADZONE := 0.2

## 開著的時候把每一次震動記進 rumble_log，給 headless 驗證用。
## 平常關著——記錄本身沒有副作用，但沒必要在正式遊戲裡一直長。
var rumble_debug: bool = false
var rumble_log: Array[Dictionary] = []

## 手把沒有現成的 just_pressed，自己做邊緣偵測，否則按住會連續觸發。
var _joy_held: Dictionary = {}


func _ready() -> void:
	for action_name in KEY_BINDINGS:
		if InputMap.has_action(action_name):
			continue
		InputMap.add_action(action_name)
		for keycode in KEY_BINDINGS[action_name]:
			var event := InputEventKey.new()
			event.physical_keycode = keycode
			InputMap.action_add_event(action_name, event)
		if MOUSE_BINDINGS.has(action_name):
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BINDINGS[action_name]
			InputMap.action_add_event(action_name, click)


## device_id < 0 為鍵鼠，>= 0 為該編號的手把。
## 回傳值為 (x = 左右, y = 前後)，前為 -y，與 Godot 的 -Z 前方一致。
func get_move_vector(device_id: int) -> Vector2:
	if device_id < 0:
		return Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	return _apply_deadzone(Vector2(
		Input.get_joy_axis(device_id, JOY_AXIS_LEFT_X),
		Input.get_joy_axis(device_id, JOY_AXIS_LEFT_Y)
	))


## 手把的鏡頭輸入（右搖桿，見 docs/06）。滑鼠走 _unhandled_input，不在這裡。
func get_look_delta(device_id: int) -> Vector2:
	if device_id < 0:
		return Vector2.ZERO
	return _apply_deadzone(Vector2(
		Input.get_joy_axis(device_id, JOY_AXIS_RIGHT_X),
		Input.get_joy_axis(device_id, JOY_AXIS_RIGHT_Y)
	))


## 死區之後要**重新歸一化**。
##
## 舊寫法是「長度超過 0.2 就原樣回傳」——所以剛好推過死區的那一刻，
## 輸出直接從 0 跳到 0.2，角色從靜止變成 1.2 m/s。微推搖桿走不出慢速，
## 只有「不動」跟「一下就衝出去」兩種狀態。
##
## 歸一化之後，死區邊緣輸出 0、推到底輸出 1，中間是連續的。
func _apply_deadzone(raw: Vector2) -> Vector2:
	var length := raw.length()
	if length <= STICK_DEADZONE:
		return Vector2.ZERO
	# 方形閘的搖桿對角線可以到 1.41，夾住之後再換算。
	var scaled := inverse_lerp(STICK_DEADZONE, 1.0, minf(length, 1.0))
	return raw / length * scaled


func is_pressed(device_id: int, action: StringName) -> bool:
	if device_id < 0:
		return Input.is_action_pressed(action)
	return _joy_down(device_id, action)


func is_just_pressed(device_id: int, action: StringName) -> bool:
	if device_id < 0:
		return Input.is_action_just_pressed(action)
	var key := "%d:%s" % [device_id, action]
	var held := _joy_down(device_id, action)
	var was_held: bool = _joy_held.get(key, false)
	_joy_held[key] = held
	return held and not was_held


## 沒有對應的動作一律回傳 false，而不是拋出 KeyError——
## 新增動作時忘了補手把對應不該讓整個角色停止回應。
func _joy_down(device_id: int, action: StringName) -> bool:
	var action_name := String(action)
	if JOY_BINDINGS.has(action_name):
		return Input.is_joy_button_pressed(device_id, JOY_BINDINGS[action_name])
	if JOY_TRIGGERS.has(action_name):
		return Input.get_joy_axis(device_id, JOY_TRIGGERS[action_name]) > TRIGGER_THRESHOLD
	return false


func is_jump_pressed(device_id: int) -> bool:
	return is_just_pressed(device_id, &"jump")


func is_grab_pressed(device_id: int) -> bool:
	return is_just_pressed(device_id, &"grab")


func is_attack_pressed(device_id: int) -> bool:
	return is_just_pressed(device_id, &"attack")


## 投擲：手把是 RT，鍵鼠是攻擊鍵（抓著東西時的攻擊就是投擲）。
## 這個不對稱來自 docs/06——手把按鍵已經排滿，鍵鼠還有餘裕。
## 按住蓄力、放開擲出，所以這裡回傳的是「是否按住」而不是邊緣。
func is_throw_held(device_id: int) -> bool:
	if device_id < 0:
		return Input.is_action_pressed(&"attack")
	return is_pressed(device_id, &"throw")


## 手把震動（docs/05 的表：命中＝短促、被擊中＝中等、ragdoll＝持續低頻）。
##
## 收在這個檔案而不是各處直接呼 Input.start_joy_vibration，兩個理由：
##   1. 「device_id < 0 是鍵鼠」這個約定只在這裡定義過一次，散出去就會有人忘記檢查。
##   2. GDScript 攔截不了引擎單例，**可觀測性必須建在呼叫邊界上**——
##      不包一層的話，headless 驗不到誰在什麼時候震了多久。
##
## 呼叫端要自己確認「這是本機玩家的事」。take_hit() 之類的函式在每一端都會跑，
## 不過濾的話，30 公尺外隊友被打會抖到你的手把。
func rumble(device_id: int, id: StringName) -> void:
	if device_id < 0 or not CombatSpec.RUMBLE.has(id):
		return
	var preset: Dictionary = CombatSpec.RUMBLE[id]
	if rumble_debug:
		rumble_log.append({"device": device_id, "id": id, "at": Time.get_ticks_msec()})
	Input.start_joy_vibration(
		device_id, preset["weak"], preset["strong"], preset["seconds"]
	)


func stop_rumble(device_id: int) -> void:
	if device_id >= 0:
		Input.stop_joy_vibration(device_id)
