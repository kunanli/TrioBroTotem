class_name PlayerIntent
extends RefCounted

## 一幀的操作意圖。真人從輸入裝置填，AI 從 AiBrain 填。
##
## 抽這一層出來，是為了讓「玩家中途接手 AI」變成只換填表的人（TD-04）——
## 角色本身不必知道背後是誰。也順便讓角色的移動邏輯只有一份，
## 不會出現「AI 用另一套移動」這種之後一定會分岔的狀況。

var move := Vector2.ZERO
var jump := false
var attack := false
var grab := false
var interact := false
var throw_held := false

## 卡住時把自己送回出生點。測試場一定會有人卡進地形或掉進縫裡，
## 沒有這個鍵的話唯一的解法是重開遊戲——測試就中斷了。
var respawn := false

## move 是否已經是世界座標。真人的輸入相對鏡頭，AI 沒有鏡頭，直接給世界方向。
var world_move := false


func clear() -> void:
	move = Vector2.ZERO
	jump = false
	attack = false
	grab = false
	interact = false
	throw_held = false
	respawn = false
	world_move = false


## 每幀只能呼叫一次。手把的 just_pressed 是自己做的邊緣偵測，
## 多問一次就會把狀態吃掉，導致按鍵時靈時不靈。
func fill_from_input(device_id: int) -> void:
	move = GameInput.get_move_vector(device_id)
	jump = GameInput.is_jump_pressed(device_id)
	attack = GameInput.is_attack_pressed(device_id)
	grab = GameInput.is_grab_pressed(device_id)
	interact = GameInput.is_pressed(device_id, &"interact")
	throw_held = GameInput.is_throw_held(device_id)
	respawn = GameInput.is_just_pressed(device_id, &"respawn")
	world_move = false
