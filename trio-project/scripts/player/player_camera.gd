class_name PlayerCamera
extends Camera3D

## 第三人稱跟隨鏡頭，包含命中與落地的鏡頭震。
##
## 從 player_character.gd 拆出來的：那個檔案同時管移動、連線、抓取、疊高、
## 戰鬥、表演，加上鏡頭之後超過一千行。鏡頭這一塊本來就自成一體——
## 它只需要「要看誰」跟「震多大」兩個輸入，其餘全部是本機表演，不同步。
##
## **鏡頭一律不同步**：每個人的視角本來就該各自獨立。

## 覺得角色太小：把 DISTANCE_RATIO 調小（拉近），
## 或把 FIELD_OF_VIEW 調小（縮視角，等於拉近但比較不犧牲看隊友的範圍）。
const DISTANCE_RATIO := 3.1
const TARGET_RATIO := 0.7

## 追隨的時間常數。垂直刻意比水平慢得多——跳躍時鏡頭跟著上下彈會很暈，
## 但水平跟不上又會看不到自己要去的地方。
const FOLLOW_TIME := 0.09
const VERTICAL_TIME := 0.28

const PITCH_MIN := -0.10
const PITCH_MAX := 1.15
const PITCH_DEFAULT := 0.42

const FIELD_OF_VIEW := 62.0

const MOUSE_SENSITIVITY := 0.0032
const STICK_LOOK_SPEED := 2.6

var yaw: float = 0.0
var pitch: float = PITCH_DEFAULT

var _owner_body: Node3D = null
var _anchor: Vector3 = Vector3.ZERO

## 震動狀態。強度與經過時間分開存，時長才能與強度解耦（見 CombatSpec）。
## _shake_seed 讓每一下的相位不同，連擊時才不會每次都震出一模一樣的軌跡。
var _shake_peak: float = 0.0
var _shake_elapsed: float = CombatSpec.SHAKE_TIME
var _shake_seed: Vector2 = Vector2.ZERO

## 沿命中方向的一次性偏轉，已經換算成鏡頭空間的（右, 上）。
var _kick_screen: Vector2 = Vector2.ZERO
var _kick_elapsed: float = CombatSpec.KICK_TIME


## 由 PlayerCharacter 在 _ready 呼叫。
func bind(body: Node3D) -> void:
	_owner_body = body
	# 鏡頭脫離角色的 transform：角色每個 physics tick 的位移會直接變成
	# 鏡頭抖動，脫開之後鏡頭只跟平滑過的錨點走。
	top_level = true
	fov = FIELD_OF_VIEW
	_anchor = _focus_target()
	place()


func _process(delta: float) -> void:
	if not current or _owner_body == null:
		return
	var stick := GameInput.get_look_delta(_owner_body.device_id)
	turn(-stick.x * STICK_LOOK_SPEED * delta, stick.y * STICK_LOOK_SPEED * delta)

	# 指數平滑：不受影格率影響，60 與 144 fps 的追隨速度一致。
	var target := _focus_target()
	var horizontal := 1.0 - exp(-delta / FOLLOW_TIME)
	var vertical := 1.0 - exp(-delta / VERTICAL_TIME)
	_anchor.x = lerpf(_anchor.x, target.x, horizontal)
	_anchor.z = lerpf(_anchor.z, target.z, horizontal)
	_anchor.y = lerpf(_anchor.y, target.y, vertical)
	_shake_elapsed += delta
	_kick_elapsed += delta
	place()


## 用 _unhandled_input 而不是 _input：UI 已經處理掉的點擊不會流到這裡，
## 所以點大廳按鈕不會順便鎖住滑鼠。
func _unhandled_input(event: InputEvent) -> void:
	if not current:
		return

	if event.is_action_pressed(&"ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return

	var click := event as InputEventMouseButton
	if click != null and click.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		# 點進畫面就鎖滑鼠，Esc 放開。M0 要在同一台機器上開三個視窗，
		# 所以一定要留一個放開的方式。
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	var motion := event as InputEventMouseMotion
	if motion == null:
		return
	var looking := (
		Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	)
	if looking:
		turn(-motion.relative.x * MOUSE_SENSITIVITY, motion.relative.y * MOUSE_SENSITIVITY)


func turn(yaw_delta: float, pitch_delta: float) -> void:
	yaw += yaw_delta
	pitch = clampf(pitch + pitch_delta, PITCH_MIN, PITCH_MAX)


## 水平基底。移動輸入要換算到這個座標系——世界座標移動配上不會轉的鏡頭，
## 在 3D 第三人稱裡一定會覺得怪。
func basis_yaw() -> Basis:
	return Basis(Vector3.UP, yaw)


## 位置與注視點一起由錨點推導，兩者永遠剛性綁在一起。
##
## 之前的做法是位置做平滑、注視點直接用角色當下位置——角色橫移時，
## 落後的鏡頭為了盯住角色會額外轉一個角度，整個畫面跟著晃。
## 改成只有注視點在平滑，鏡頭就只有位移延遲，沒有轉動晃動。
func place() -> void:
	global_position = _anchor + _orbit_offset()
	look_at(_anchor, Vector3.UP)
	var swing := shake_swing()
	if swing == Vector2.ZERO:
		return
	# 一定要在 look_at **之後**才轉。舊版是在 look_at 之前位移鏡頭，
	# 而 look_at 每幀重新瞄準沒被震的錨點，等於自己把震動抵銷掉——
	# 角色因此永遠釘在畫面正中央，只有背景在輕微視差。
	rotate_object_local(Vector3.RIGHT, swing.y)
	rotate_object_local(Vector3.UP, swing.x)
	rotate_object_local(Vector3.BACK, swing.x * CombatSpec.SHAKE_ROLL)


## 這一幀的鏡頭偏轉（弧度），x 是左右、y 是上下。
##
## 用時間驅動的正弦而不是逐幀 randf：逐幀亂數在 144 fps 是雜訊、在 60 fps 是抖動，
## 兩台機器看到的根本不是同一件事。兩軸頻率比 1.37 是為了不讓它變成一條斜線。
func shake_swing() -> Vector2:
	var out := Vector2.ZERO
	var envelope := CombatSpec.shake_envelope(_shake_elapsed)
	if envelope > 0.0:
		var phase := _shake_elapsed * CombatSpec.SHAKE_FREQUENCY * TAU
		var amplitude := _shake_peak * CombatSpec.SHAKE_ANGLE * envelope
		out += Vector2(
			sin(phase + _shake_seed.x), sin(phase * 1.37 + _shake_seed.y)
		) * amplitude
	if _kick_elapsed < CombatSpec.KICK_TIME:
		# 二次衰減：出去快、回中更快，讀起來像被推了一下而不是飄回來。
		var remain := 1.0 - _kick_elapsed / CombatSpec.KICK_TIME
		out += _kick_screen * CombatSpec.KICK_ANGLE * remain * remain
	return out


## 震一下。direction 是世界空間的衝擊方向，Vector3.ZERO 表示不加方向偏轉。
##
## 呼叫端要負責過濾「這是不是本機自己的事」——take_hit() 在每一端都會跑，
## 不過濾的話 30 公尺外隊友被打會震到你的畫面。
func add_shake(magnitude: float, direction: Vector3 = Vector3.ZERO) -> void:
	if magnitude <= 0.0:
		return
	# 取大的不累加：連擊時累加會越震越誇張，與 Overcooked 基準打架。
	if _shake_elapsed >= CombatSpec.SHAKE_TIME or magnitude > _shake_peak:
		_shake_peak = magnitude
		_shake_elapsed = 0.0
		_shake_seed = Vector2(randf() * TAU, randf() * TAU)
	if direction == Vector3.ZERO:
		return
	# 換算到鏡頭空間，這樣「往右被打」在畫面上就是往右偏，
	# 不會像舊版那樣依鏡頭朝向變成推拉。
	var unit := direction.normalized()
	_kick_screen = Vector2(global_basis.x.dot(unit), global_basis.y.dot(unit))
	_kick_elapsed = 0.0


## 鏡頭要對準的點：角色身上稍高的位置，不是腳底。
func _focus_target() -> Vector3:
	if _owner_body == null:
		return Vector3.ZERO
	var height: float = _owner_body.character_height
	return _owner_body.global_position + Vector3.UP * (height * TARGET_RATIO)


## 鏡頭相對於注視點的位移。
func _orbit_offset() -> Vector3:
	# 明確標型別：_owner_body 宣告成 Node3D，character_height 不是它的成員，
	# 回傳型別未知，:= 推不出來。不把 _owner_body 標成 PlayerCharacter 是為了
	# 避免兩個 class_name 互相引用。
	var height: float = _owner_body.character_height if _owner_body != null else 1.8
	var arm: Vector3 = Vector3(0.0, sin(pitch), cos(pitch)) * (height * DISTANCE_RATIO)
	return Basis(Vector3.UP, yaw) * arm
