class_name CharacterVisual
extends Node3D

## 載入角色模型並驅動它的動畫。
##
## 用 AnimationPlayer 直接切換加交叉淡入，不是 AnimationTree。
## AnimationTree 要在編輯器裡拉狀態機，現階段的需求（待機／移動／單次動作）
## 用 play(名稱, 混合時間) 就夠了，而且看得懂、改得動。
## 等到需要 BlendSpace 混合方向與速度時再升級（M1）。

## 動畫名稱由美術管線正規化（見 tools/blender_normalize.py 的 ANIMATION_NAMES），
## 所以這裡可以直接寫死名稱，不必處理 Meshy 那串原始字串。
const LOCOMOTION := [&"idle", &"walk", &"run"]

## 切換動畫的交叉淡入時間。太短會有跳動，太長會拖。
const BLEND_TIME := 0.15

## 走路動畫「原本」對應的移動速度。用來讓播放速度跟著實際移動速度走，
## 否則腳會在地上滑。調到腳不滑為止。
const WALK_REFERENCE_SPEED := 1.6

const SPEED_SCALE_RANGE := Vector2(0.6, 1.8)

## 低於這個速度算站著不動。
const IDLE_SPEED := 0.15

var character_id: StringName = &""

var _player: AnimationPlayer = null
var _model: Node3D = null
var _action: StringName = &""


## 回傳是否成功載入模型。失敗時呼叫端應該保留膠囊當備援。
func load_character(id: StringName) -> bool:
	character_id = id
	var entry := CharacterRoster.entry(id)
	if entry.is_empty():
		push_warning("[Visual] 名冊裡沒有 %s" % id)
		return false

	var scene: PackedScene = load(entry["model"])
	if scene == null:
		push_warning("[Visual] 載入失敗：%s" % entry["model"])
		return false

	_model = scene.instantiate()
	_model.rotation.y = deg_to_rad(entry.get("yaw_offset", 0.0))
	add_child(_model)

	_player = _model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _player == null:
		push_warning("[Visual] %s 裡沒有 AnimationPlayer——模型沒有動畫" % id)
		return true

	# 匯入的動畫預設不循環，移動類的要自己打開，否則走一步就停住。
	for name in LOCOMOTION:
		if _player.has_animation(name):
			_player.get_animation(name).loop_mode = Animation.LOOP_LINEAR
	_player.animation_finished.connect(_on_animation_finished)
	return true


func available() -> PackedStringArray:
	return _player.get_animation_list() if _player else PackedStringArray()


## 依水平速度選待機或移動。單次動作播放中時不打斷它。
func drive(speed: float) -> void:
	if _player == null or _action != &"":
		return
	var wanted := _locomotion_for(speed)
	if wanted == &"":
		return
	if _player.current_animation != String(wanted):
		_player.play(wanted, BLEND_TIME)
	if wanted != &"idle":
		_player.speed_scale = clampf(
			speed / WALK_REFERENCE_SPEED, SPEED_SCALE_RANGE.x, SPEED_SCALE_RANGE.y
		)
	else:
		_player.speed_scale = 1.0


## 播一次就回到移動狀態的動作（攻擊、受擊等）。
func play_action(name: StringName) -> bool:
	if _player == null or not _player.has_animation(name):
		return false
	_action = name
	_player.speed_scale = 1.0
	_player.play(name, BLEND_TIME)
	return true


func _locomotion_for(speed: float) -> StringName:
	if speed < IDLE_SPEED:
		# 沒有 idle 就退回停在移動動畫的第一幀，總比整個不動好。
		return &"idle" if _player.has_animation(&"idle") else &""
	if speed > WALK_REFERENCE_SPEED * 1.6 and _player.has_animation(&"run"):
		return &"run"
	if _player.has_animation(&"walk"):
		return &"walk"
	return &""


func _on_animation_finished(name: StringName) -> void:
	if name == _action:
		_action = &""
