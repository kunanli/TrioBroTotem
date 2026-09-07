extends Node3D

## 動畫展示場：三隻角色並排，輪播全部的動畫，鏡頭繞著轉。
##
## 兩種用法：
##   在編輯器裡按 ▶ ──── 一直輪播，畫面左上角寫著現在播的是哪一支。
##   `tools/shoot_anim.py` ── 逐幀存 PNG，Pillow 疊成 GIF 給看不到專案的人看。
##
## 這個檔案不進遊戲：`export_presets.cfg` 的 `exclude_filter` 把 `scenes/tools/`
## 整個排掉了。
##
## **為什麼可以在這台沒有顯示卡的機器上拍**：Xvfb 給 X11、Mesa 的 lavapipe 給
## 軟體 Vulkan，而蒙皮角色**畫得出來**——README 裡「llvmpipe 不畫蒙皮網格」
## 那句話是換成 lavapipe 之前寫的，早就不成立了，是這一輪才回頭驗掉的。
##
## 逐幀存檔要配 `--fixed-fps`：軟體渲染的每幀耗時忽長忽短，不鎖的話存出來
## 的每一張之間隔的模擬時間都不一樣，疊成 GIF 會一頓一頓——**動作本身沒問題，
## 是取樣壞的**，而那種問題看起來就像動畫做壞了。

const SPACING := 1.85

## 三隻各自轉開的角度（弧度）。
##
## 這是「怎麼同時看到武器與正臉」的解法。武器握在髖部旁邊，正面拍過去整支
## 疊在軀幹的剪影裡；但**轉鏡頭會把一列角色拉成一前一後**，所以改成轉角色：
## 每一隻都側身同樣的角度，彼此的距離不變，武器卻從身體旁邊分離出來了。
## 0.5 弧度（約 29 度）是往右手邊轉——劍與法杖都在右手。
const FACE_TURN := 0.5

## 走路那幾段的朝向：面向 +X，也就是橫著走過畫面。
##
## 側面是**判斷腳滑最好的角度**——正面看不出腳往後拖了幾公分，側面一眼就
## 看得到腳有沒有黏在地上。
const WALK_FACING := -PI * 0.5

## 走起來之後怎麼繞回來。
##
## 三隻排成一列、間距 SPACING，把每一隻的 x 折回寬度 `3 × SPACING` 的區間裡，
## **三個位置永遠還是那三個**——只是誰站哪一格會輪替。所以畫面上完全看不出
## 有繞回這件事，不會有「跳一下」。這是能無縫循環又不用移動鏡頭的作法。
const WRAP_WIDTH := SPACING * 3.0

## 轉向的時間常數。走路段要轉去面向 +X，其餘段轉回 3/4 側面。
const FACING_TIME := 0.25

## 開拍前先空轉幾幀。第一幀通常是黑的（shader 還在編、陰影 atlas 還沒建），
## 而且 GIF 的第一格會被當成縮圖。
const WARMUP_FRAMES := 16

## 鏡頭：繞著中心來回擺，不是繞整圈——繞到背面就只剩後腦杓，
## 而武器與姿勢的辨識度全在正面那 120 度裡。
const ORBIT_RADIUS := 4.4
const ORBIT_HEIGHT := 1.75
## 擺幅原本是 0.62 弧度（35 度），拍出來三隻在畫面裡左右甩得太厲害，
## 動作本身反而看不清楚。0.34 大約 20 度：夠看出立體感，又不會搶戲。
const ORBIT_SWEEP := 0.34
const ORBIT_PERIOD := 13.0

## 逐幀存檔時鏡頭要**停住**，擺在這個角度。
##
## 不是為了好看，是為了檔案大小：鏡頭一動，每一幀的每一個像素都變了，
## GIF 的逐幀差分完全失效。實測 800×450／20 fps／21 秒，繞鏡頭的版本
## **44.8 MB**——那不是拿來給人看的東西，是拿來塞爆聊天視窗的。
## 停住之後只有角色在動，同一份內容掉到幾 MB。
##
## 0.22 弧度（約 13 度）。**不要為了看側面而把鏡頭轉大角度**：三隻是排成一列
## 的，鏡頭一斜，最遠的那隻就被透視縮成一半、還被中間那隻擋住。實測 0.52
## 拍出來豬只剩一小點。要看側面就轉角色，不要轉鏡頭——見 FACE_TURN。
const STILL_ANGLE := 0.22
const LOOK_AT_Y := 0.95

## 輪播清單。`drive` 是移動速度（公尺／秒），`action` 是播一次的邏輯動畫名稱。
##
## 順序是刻意的：先站著（看得出職業與武器），再走再跑（看得出重量），
## 然後才是動作。攻擊排在中間、受擊與倒下排最後——倒下之後要留時間站起來。
const PLAYLIST := [
	{"label": "IDLE", "drive": 0.0, "seconds": 2.6},
	# `travel` ＝ 真的往前走。**沒有它就看不出這一輪做了什麼**：鎖腳是把腳釘在
	# 世界座標上，身體不動的話等於原地立正，畫面上什麼都看不到。
	{"label": "WALK", "drive": 1.4, "travel": 1.4, "seconds": 3.0},
	{"label": "RUN", "drive": 3.0, "travel": 3.0, "seconds": 3.0},
	{"label": "SPRINT", "drive": 6.0, "travel": 6.0, "seconds": 3.0},
	# 轉身傾斜是疊加層不是片段（見 MotionClips.PIVOT_POSE），所以驗它的方法是
	# **把角色轉起來**。2.2 秒剛好整整一圈，結束時朝向回到原位，不必硬扳回去。
	{"label": "TURN", "drive": 1.6, "spin": TAU / 2.2, "seconds": 2.2},
	{"label": "ATTACK 1", "action": &"attack1", "seconds": 1.1},
	{"label": "ATTACK 2", "action": &"attack2", "seconds": 1.1},
	{"label": "ATTACK 3", "action": &"attack3", "seconds": 1.4},
	{"label": "DASH ATTACK", "action": &"attack_dash", "seconds": 1.3},
	{"label": "AIR ATTACK", "action": &"attack_air", "seconds": 1.3},
	{"label": "JUMP", "action": &"jump", "seconds": 1.0},
	{"label": "LAND", "action": &"land", "seconds": 1.0},
	{"label": "HURT", "action": &"hurt", "seconds": 1.0},
	{"label": "CARRY", "carry": true, "drive": 1.6, "seconds": 2.2},
]

var _visuals: Array[CharacterVisual] = []
var _camera: Camera3D = null
var _title: Label = null
var _clock := 0.0
var _step := 0.0
var _index := 0
var _speed := 0.0
var _spin := 0.0
var _travel := 0.0
var _phase := 0.0
var _running := false
var _orbit := true


func _ready() -> void:
	_build_stage()
	_build_cast()
	_build_overlay()
	_enter(0)

	var out_dir := _argument("--out=")
	if out_dir.is_empty():
		_running = true
		return
	_orbit = _argument("--orbit=") == "1"
	await _dump(out_dir, maxi(int(_argument("--frames=")), 1))
	get_tree().quit(0)


func _argument(prefix: String) -> String:
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	for arg in args:
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""


## 地台與燈。用跟遊戲同一份 Environment，否則調出來好看的東西進遊戲會變樣。
func _build_stage() -> void:
	var world := WorldEnvironment.new()
	world.environment = load("res://scenes/world/default_env.tres")
	add_child(world)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38.0, 36.0, 0.0)
	sun.light_color = Color(1.0, 0.92, 0.80)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 1.5
	add_child(sun)

	# 冷色補光：平塗渲染的暗面沒有這一盞就是一片死黑（見 palette.gd 的說明）。
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18.0, -150.0, 0.0)
	fill.light_color = Color(0.58, 0.68, 0.86)
	fill.light_energy = 0.35
	add_child(fill)

	add_child(_slab(Vector3(30.0, 0.4, 30.0), Vector3(0.0, -0.2, 0.0), &"turf"))
	# 台座只是用來把三隻跟草地分開，不該搶戲：用暗色的地面塊，不是亮色的路面。
	add_child(_slab(Vector3(7.6, 0.22, 3.6), Vector3(0.0, -0.11, 0.0), &"turf_dark"))


func _slab(size: Vector3, at: Vector3, color: StringName) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.set_surface_override_material(0, Palette.surface(color))
	node.position = at
	return node


## 三隻並排，面向 +Z（鏡頭的起始位置在那一邊）。
func _build_cast() -> void:
	var order := CharacterRoster.SLOT_ORDER
	for index in order.size():
		var id: StringName = order[index]
		var visual := CharacterVisual.new()
		visual.name = String(id)
		add_child(visual)
		visual.position = Vector3((index - 1) * SPACING, 0.0, 0.0)
		# CharacterVisual 的前方是 −Z（模型自己已經轉過 yaw_offset），
		# 轉半圈才面向鏡頭，再側開 FACE_TURN 讓持械的那一側朝外。
		visual.rotation.y = PI + FACE_TURN
		if not visual.load_character(id):
			push_warning("[Lab] %s 載入失敗" % id)
			continue
		_visuals.append(visual)
		# 名牌掛在角色底下，走起來才跟著走。掛在原點的話人走了字留在原地。
		visual.add_child(_nameplate(id))


func _nameplate(id: StringName) -> Label3D:
	var plate := Label3D.new()
	plate.text = String(id).replace("_", " ").to_upper()
	plate.font_size = 96
	# 不要開 fixed_size。開了之後字級不吃距離，三個名字會撐滿整個畫面互相疊在
	# 一起——實測過，那張聯絡表整片都是字。名字本來就該跟著角色遠近縮放。
	plate.pixel_size = 0.0016
	plate.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	plate.modulate = Color(0.96, 0.94, 0.88)
	plate.outline_size = 24
	plate.outline_modulate = Color(0.05, 0.04, 0.06)
	plate.position = Vector3(0.0, 2.35, 0.0)
	return plate


func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_title = Label.new()
	_title.position = Vector2(28.0, 20.0)
	_title.add_theme_font_size_override(&"font_size", 40)
	_title.add_theme_color_override(&"font_color", Color(0.98, 0.96, 0.90))
	_title.add_theme_color_override(&"font_outline_color", Color(0.05, 0.04, 0.06))
	_title.add_theme_constant_override(&"outline_size", 8)
	layer.add_child(_title)

	_camera = Camera3D.new()
	_camera.fov = 46.0
	_camera.current = true
	add_child(_camera)
	_aim(0.0)


func _process(delta: float) -> void:
	if not _running:
		return
	_clock += delta
	_step += delta
	_aim(_clock)
	_phase = fmod(_phase + _travel * delta, WRAP_WIDTH)
	var facing := WALK_FACING if _travel > 0.0 else PI + FACE_TURN
	for index in _visuals.size():
		var visual: CharacterVisual = _visuals[index]
		if _spin != 0.0:
			visual.rotation.y += _spin * delta
		else:
			visual.rotation.y = lerp_angle(
				visual.rotation.y, facing, 1.0 - exp(-delta / FACING_TIME)
			)
		visual.position.x = wrapf(
			(index - 1) * SPACING + _phase, -WRAP_WIDTH * 0.5, WRAP_WIDTH * 0.5
		)
		visual.drive(_speed)
	var entry: Dictionary = PLAYLIST[_index]
	if _step >= float(entry["seconds"]):
		_enter((_index + 1) % PLAYLIST.size())


## 切到清單的下一項。
##
## `drive` 每一幀都要餵（`CharacterVisual.drive()` 是逐幀呼叫的介面），
## `action` 只在進入的那一刻播一次——播不出來就直接說，不要靜靜地跳過去。
## 「靜靜地退回走路」正是這一輪要修掉的那個病：`run` 缺了整整一輪沒人發現。
func _enter(index: int) -> void:
	_index = index
	_step = 0.0
	var entry: Dictionary = PLAYLIST[index]
	_speed = float(entry.get("drive", 0.0))
	_spin = float(entry.get("spin", 0.0))
	_travel = float(entry.get("travel", 0.0))
	_title.text = String(entry["label"])
	var carrying := bool(entry.get("carry", false))
	for visual in _visuals:
		visual.set_carrying(carrying)
		if not entry.has("action"):
			continue
		if not visual.play_action(entry["action"]):
			push_warning("[Lab] %s 沒有 %s" % [visual.name, entry["action"]])
			_title.text = "%s  (missing)" % String(entry["label"])


func _aim(time: float) -> void:
	var angle := STILL_ANGLE
	if _orbit:
		angle = sin(time * TAU / ORBIT_PERIOD) * ORBIT_SWEEP
	var focus := Vector3(0.0, LOOK_AT_Y, 0.0)
	var arm := Basis(Vector3.UP, angle) * Vector3(0.0, 0.0, ORBIT_RADIUS)
	_camera.global_position = focus + arm + Vector3(0.0, ORBIT_HEIGHT - LOOK_AT_Y, 0.0)
	_camera.look_at(focus, Vector3.UP)


## 逐幀存 PNG。搭配 `--fixed-fps` 用，每一幀之間的模擬時間才等長。
func _dump(out_dir: String, frames: int) -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	# 暖機的時候**要讓 drive() 跑**，不能只是空轉等畫面。
	#
	# 剛載入的角色停在骨架的靜置姿勢（雙手平舉的 T 字），而武器是焊在手骨上的——
	# 靜置姿勢下手骨的 +Y 是往身體外側，垂手站著時卻是朝下，兩者差了 75 度。
	# 空轉暖機的話，拍到的前幾張是「T 字姿勢上掛著一把往身體裡插的劍」，
	# 而那看起來完全像是武器的角度算錯了。實際上是取樣取在動畫還沒開始的時候。
	_running = true
	for _warm in WARMUP_FRAMES:
		await RenderingServer.frame_post_draw
	_clock = 0.0
	_enter(0)
	for index in frames:
		await RenderingServer.frame_post_draw
		var path := "%s/%04d.png" % [out_dir, index]
		var error := get_viewport().get_texture().get_image().save_png(path)
		if error != OK:
			printerr("[Lab] 存不了 %s（錯誤 %d）" % [path, error])
			return
	print("[Lab] %d 幀 -> %s" % [frames, out_dir])
