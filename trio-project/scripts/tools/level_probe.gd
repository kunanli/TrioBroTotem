extends Node3D

## 關卡截圖探針：把世界場景載進來，用**玩家真正的鏡頭**在幾個定點各拍一張。
##
## 為什麼需要這個：這台開發機沒有顯示卡，以前視覺類的工作只能驗「設定有沒有
## 生效」，看不到結果。但 Xvfb ＋ Mesa llvmpipe 可以跑起 OpenGL 4.5，關卡是
## 一堆方塊、不是蒙皮網格，畫得出來。所以視覺這件事終於有得看了。
##
## 鏡頭參數全部從 player_camera.gd 推出來，不是隨便挑一個好看的角度——
## 宣傳照會騙人。玩家實際看到的是這個角度，就只驗這個角度。
##
## 這個檔案不進遊戲：export_presets.cfg 的 exclude_filter 把 scenes/tools/ 排掉了。

## 從 player_camera.gd 抄過來。改那邊要記得改這邊——但這兩個數字動的機會
## 遠低於關卡幾何，而讓探針去 import PlayerCamera 會把整條玩家的相依鏈拖進來。
const DISTANCE_RATIO := 3.1
const TARGET_RATIO := 0.7
const PITCH := 0.42
const FIELD_OF_VIEW := 62.0

## 用來當比例尺的假人身高。三隻角色是 1.4／1.6／1.7，取中間那隻。
const STANDIN_HEIGHT := 1.6
const STANDIN_RADIUS := 0.32

## 換一個取景之後要等幾幀才擷取。
##
## 不能拍下一幀：粒子要暖機、陰影 atlas 要重建、鏡頭大跳之後第一幀還可能
## 帶著上一個位置的 prepass。實測 8 幀之後就穩定了。
const SETTLE_FRAMES := 8

## 每一關的取景點。x/z 是**玩家站的位置**，鏡頭自己往後退算出來。
## yaw 0 是面向 −z（往關卡深處走的方向），PI 是回頭。
const SHOTS := {
	"res://scenes/world/test_arena.tscn": [
		# 前廳（yaw = PI/2 → 鏡頭在 +x 往 −x 看，也就是前廳的前進方向）
		{"name": "01_landing", "x": 32.0, "z": 35.0, "yaw": PI * 0.5},
		{"name": "02_hallfight", "x": 25.0, "z": 35.0, "yaw": PI * 0.5},
		{"name": "03_seep", "x": 20.0, "z": 35.5, "yaw": PI * 0.5},
		# 壓力板與它連著的門要在**同一張**畫面裡，否則「我把東西放上去了，
		# 然後呢」就只能靠猜。板子在 x=15、門在 x=10.5。
		{"name": "04_plate", "x": 14.0, "z": 35.5, "yaw": PI * 0.5},
		{"name": "05_turn", "x": 2.0, "z": 31.0, "yaw": 0.5},
		{"name": "06_corner", "x": 0.0, "z": 26.0, "yaw": 0.0},
		{"name": "07_alcove", "x": 22.0, "z": 28.5, "yaw": 0.0},
		{"name": "08_spawn", "x": 0.0, "z": 20.0, "yaw": 0.0},
		{"name": "09_crates", "x": 1.5, "z": 15.0, "yaw": 0.0},
		{"name": "10_vine", "x": 0.0, "z": 13.0, "yaw": 0.0},
		{"name": "11_stump", "x": -1.5, "z": 6.0, "yaw": 0.0},
		{"name": "12_lip", "x": 0.0, "z": -1.0, "yaw": 0.0},
		{"name": "13_bridge", "x": 0.0, "z": -8.0, "yaw": 0.0},
		# 遠岸：台上的壓力板在左手邊，關著的門擋在終點台前面。
		{"name": "14_bankplate", "x": 0.0, "z": -13.5, "yaw": 0.0},
		{"name": "15_goal", "x": 0.0, "z": -14.0, "yaw": 0.0},
		# 回頭往 +z 看：全場最長的視線，也是路面共面 z-fighting 最容易現形的一張。
		{"name": "16_lookback", "x": 0.0, "z": -14.0, "yaw": PI},
		# 唯一一張不是玩家視角的：整個 L 的版型，用來看路的走向對不對。
		#
		# `no_fog`：關卡對角線約 84 公尺，`fog_depth_end` 是 70——照原樣拍整張
		# 都是霧、什麼也判斷不出來。這是**版型圖不是氛圍圖**，霧要關掉才有用；
		# 玩家視角的十四張一律不關，那些才是拿來判斷畫面的。
		{
			"name": "17_overview", "no_fog": true,
			"eye": Vector3(62.0, 76.0, 82.0), "at": Vector3(13.0, 0.0, 11.0),
		},
	],
	"res://scenes/world/camp.tscn": [
		{"name": "01_spawn", "x": 0.0, "z": 6.0, "yaw": 0.0},
		{"name": "02_fire", "x": 0.0, "z": 3.0, "yaw": 0.0},
		{"name": "03_board", "x": 0.0, "z": -6.0, "yaw": 0.0},
		{"name": "04_gate", "x": 0.0, "z": -13.0, "yaw": 0.0},
		{"name": "05_overview", "eye": Vector3(24.0, 26.0, 26.0), "at": Vector3(0.0, 0.0, -2.0)},
	],
}

var _camera: Camera3D = null


func _ready() -> void:
	var world_path := _argument("--world=")
	var out_dir := _argument("--out=")
	if world_path.is_empty() or out_dir.is_empty():
		printerr("[Probe] 用法：--world=res://... --out=/abs/dir")
		get_tree().quit(2)
		return

	var scene: PackedScene = load(world_path)
	if scene == null:
		printerr("[Probe] 載入不到 %s" % world_path)
		get_tree().quit(2)
		return
	add_child(scene.instantiate())

	_camera = Camera3D.new()
	_camera.fov = FIELD_OF_VIEW
	_camera.current = true
	add_child(_camera)

	_add_standins()
	await _shoot_all(world_path, out_dir)
	get_tree().quit(0)


## 兩份參數清單都掃。理由見 main.gd：編輯器的 Launch Arguments 不一定會加
## `--` 分隔符，只認 user_args 的話設了參數卻沒反應，而且不會有錯誤訊息。
func _argument(prefix: String) -> String:
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	for arg in args:
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""


## 在出生點放三根人形膠囊。
##
## 這是整個探針最重要的一件事。蒙皮的角色模型在 llvmpipe 底下不一定畫得出來，
## 而**畫面裡沒有人的尺度，就沒辦法判斷一顆三公尺的石頭是大是小**——
## 沒有比例尺的話，我會把每一樣東西都做得太大，而且要等你在真機上看到才發現。
func _add_standins() -> void:
	var colors: Array[Color] = [
		Color(0.90, 0.42, 0.32), Color(0.36, 0.76, 0.48), Color(0.38, 0.58, 0.95)
	]
	var index := 0
	for node in get_tree().get_nodes_in_group("spawn_points"):
		var marker: Node3D = node
		var mesh := CapsuleMesh.new()
		mesh.radius = STANDIN_RADIUS
		mesh.height = STANDIN_HEIGHT
		var material := StandardMaterial3D.new()
		material.albedo_color = colors[index % colors.size()]
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.material_override = material
		add_child(instance)
		# 站在地面上，不是站在標記的高度——標記是給 CharacterBody3D 用的，
		# 帶著出生時的離地餘裕，拿來擺視覺參考會浮起來。
		instance.global_position = Vector3(
			marker.global_position.x, STANDIN_HEIGHT * 0.5, marker.global_position.z
		)
		index += 1


func _shoot_all(world_path: String, out_dir: String) -> void:
	var shots: Array = SHOTS.get(world_path, [])
	if shots.is_empty():
		printerr("[Probe] %s 沒有定義取景點" % world_path)
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	for entry in shots:
		var shot: Dictionary = entry
		_aim(shot)
		for _frame in SETTLE_FRAMES:
			await RenderingServer.frame_post_draw
		var path := "%s/%s.png" % [out_dir, String(shot["name"])]
		var image := get_viewport().get_texture().get_image()
		var err := image.save_png(path)
		if err != OK:
			printerr("[Probe] 存不了 %s（錯誤 %d）" % [path, err])
		else:
			print("[Probe] %s" % path)


## 把鏡頭擺到取景點。玩家視角的算法跟 player_camera.gd 的 place() 一模一樣：
## 注視點在角色身上 0.7 倍身高處，鏡頭沿著俯角往後退 3.1 倍身高。
func _aim(shot: Dictionary) -> void:
	var world := get_viewport().world_3d
	if world.environment != null:
		world.environment.fog_enabled = not bool(shot.get("no_fog", false))
	if shot.has("eye"):
		_camera.global_position = shot["eye"]
		_camera.look_at(shot["at"], Vector3.UP)
		return
	var focus := Vector3(
		float(shot["x"]), STANDIN_HEIGHT * TARGET_RATIO, float(shot["z"])
	)
	var arm := Vector3(0.0, sin(PITCH), cos(PITCH)) * (STANDIN_HEIGHT * DISTANCE_RATIO)
	_camera.global_position = focus + Basis(Vector3.UP, float(shot["yaw"])) * arm
	_camera.look_at(focus, Vector3.UP)
