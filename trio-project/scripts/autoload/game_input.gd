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
}


func _ready() -> void:
	for action_name in KEY_BINDINGS:
		if InputMap.has_action(action_name):
			continue
		InputMap.add_action(action_name)
		for keycode in KEY_BINDINGS[action_name]:
			var event := InputEventKey.new()
			event.physical_keycode = keycode
			InputMap.action_add_event(action_name, event)


## device_id < 0 為鍵鼠，>= 0 為該編號的手把。
## 回傳值為 (x = 左右, y = 前後)，前為 -y，與 Godot 的 -Z 前方一致。
func get_move_vector(device_id: int) -> Vector2:
	if device_id < 0:
		return Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var raw := Vector2(
		Input.get_joy_axis(device_id, JOY_AXIS_LEFT_X),
		Input.get_joy_axis(device_id, JOY_AXIS_LEFT_Y)
	)
	return raw if raw.length() > 0.2 else Vector2.ZERO


## 手把沒有現成的 just_pressed，自己做邊緣偵測，否則按住會連跳。
var _joy_jump_held := {}


func is_jump_pressed(device_id: int) -> bool:
	if device_id < 0:
		return Input.is_action_just_pressed("jump")
	var held := Input.is_joy_button_pressed(device_id, JOY_BUTTON_A)
	var was_held: bool = _joy_jump_held.get(device_id, false)
	_joy_jump_held[device_id] = held
	return held and not was_held
