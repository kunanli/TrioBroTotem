extends Node

## 用程式生成粒子特效，不用美術資產。與 sfx.gd 是同一個形狀、同一個理由。
##
## docs/05 的打擊感規格要求「衝擊特效」與「碎裂特效」，但整個專案零粒子——
## 打中東西只有攻擊者自己會頓一下，畫面上什麼都沒發生。
##
## 全部在啟動時用程式建（QuadMesh ＋ billboard 材質），不進版控、不需要圖檔，
## 改一個數字就能看到差別。正式美術進來時整層換掉，呼叫端不用改。
##
## **用 CPUParticles3D 不是 GPUParticles3D**，三個理由：
##   1. GPU 版要編譯 compute shader，headless 的 dummy renderer 下根本不模擬，
##      我在容器裡驗不到任何東西；CPU 版真的會跑。
##   2. GPU 版有「一次性粒子播完後 emitting = true 不會重播」的經典陷阱，
##      正好是池化爆發系統最容易撞上的。
##   3. 每次爆散只有 10–18 顆，效能差別可以忽略。

## 同時最多幾團粒子。與 Sfx 一樣用固定池——戰鬥最激烈的時候不該在配置節點。
const EMITTERS := 16

var _presets: Dictionary = {}
var _emitters: Array[CPUParticles3D] = []

## 每個發射器預計播完的時間（毫秒）。挑最早到期的重用。
var _free_at: PackedFloat64Array = PackedFloat64Array()


func _ready() -> void:
	_build_presets()
	for index in EMITTERS:
		var emitter := CPUParticles3D.new()
		emitter.name = "Emitter%d" % index
		emitter.emitting = false
		emitter.one_shot = true
		emitter.explosiveness = 1.0
		# 粒子留在世界座標。發射器之後會被移到別的位置重用，
		# local_coords = true 的話舊的那團會跟著一起飛走。
		emitter.local_coords = false
		add_child(emitter)
		_emitters.append(emitter)
		_free_at.append(0.0)


## 在世界的某個位置爆一團。純表演，各機各自播，不同步——
## 特效跟著已經同步的事件走就夠了（與 Sfx.play 同一個判斷）。
func burst(
	id: StringName, position: Vector3, direction: Vector3 = Vector3.UP, scale: float = 1.0
) -> void:
	var preset: Dictionary = _presets.get(id, {})
	if preset.is_empty():
		return
	var emitter := _take_emitter(float(preset["lifetime"]))
	emitter.mesh = preset["mesh"]
	emitter.material_override = preset["material"]
	emitter.amount = maxi(int(round(float(preset["amount"]) * scale)), 1)
	emitter.lifetime = preset["lifetime"]
	emitter.spread = preset["spread"]
	emitter.gravity = preset["gravity"]
	emitter.initial_velocity_min = float(preset["speed_min"]) * scale
	emitter.initial_velocity_max = float(preset["speed_max"]) * scale
	emitter.damping_min = preset["damping"]
	emitter.damping_max = preset["damping"]
	emitter.scale_amount_min = preset["size"]
	emitter.scale_amount_max = preset["size"]
	emitter.scale_amount_curve = preset["size_curve"]
	emitter.color_ramp = preset["ramp"]
	emitter.global_position = position
	# 粒子沿發射器的 -Z 噴出（Godot 的慣例），所以把 -Z 對準要噴的方向。
	var unit := direction.normalized() if direction.length_squared() > 0.0001 else Vector3.UP
	if absf(unit.dot(Vector3.UP)) < 0.99:
		emitter.look_at(position + unit, Vector3.UP)
	else:
		emitter.look_at(position + unit, Vector3.FORWARD)
	# restart() 而不是 emitting = true：一次性粒子播完之後，
	# 重設 emitting 不保證會重播，restart() 才是爆發的正確用法。
	emitter.restart()


## 換關或斷線時把還在飛的粒子收掉，免得新場景一開場就掛著上一場的碎屑。
func clear() -> void:
	for index in _emitters.size():
		_emitters[index].emitting = false
		_free_at[index] = 0.0


## 挑一個發射器。**不能像 Sfx 那樣單純輪替**——搶走一個還在播的音效只是
## 「喀」一聲，搶走一個還在飛的粒子發射器會讓那團碎屑當場瞬移到地圖另一頭
## （粒子在世界座標，但重新發射看的是節點當下的位置）。
func _take_emitter(lifetime: float) -> CPUParticles3D:
	var now := Time.get_ticks_msec() as float
	var best := 0
	for index in _emitters.size():
		if _free_at[index] <= now:
			best = index
			break
		if _free_at[index] < _free_at[best]:
			best = index
	_free_at[best] = now + lifetime * 1000.0
	return _emitters[best]


func _build_presets() -> void:
	# 命中火花：加色、不受光、無重力，噴出去馬上被阻尼拉住。快、亮、短。
	_presets[&"hit_spark"] = _preset({
		"amount": 10, "lifetime": 0.18, "spread": 35.0, "gravity": Vector3.ZERO,
		"speed_min": 3.5, "speed_max": 7.0, "damping": 14.0, "size": 0.12,
		"colors": [Color(1.0, 0.98, 0.85), Color(1.0, 0.72, 0.25, 0.0)], "additive": true,
	})
	# 碎裂：有重力、往外散、邊飛邊縮。泥巴色，跟泥偶本身同一個色系。
	_presets[&"shatter"] = _preset({
		"amount": 18, "lifetime": 0.70, "spread": 70.0, "gravity": Vector3(0.0, -9.8, 0.0),
		"speed_min": 2.5, "speed_max": 6.5, "damping": 1.2, "size": 0.14,
		"colors": [Color(0.42, 0.33, 0.25), Color(0.3, 0.24, 0.18, 0.0)], "additive": false,
	})
	# 落地塵土：貼著地面往外散的一圈，不是一球。速度要慢，不然像爆炸。
	_presets[&"land_dust"] = _preset({
		"amount": 12, "lifetime": 0.35, "spread": 90.0, "gravity": Vector3(0.0, 0.6, 0.0),
		"speed_min": 1.0, "speed_max": 2.4, "damping": 3.0, "size": 0.22,
		"colors": [Color(0.72, 0.68, 0.6, 0.55), Color(0.72, 0.68, 0.6, 0.0)], "additive": false,
	})
	# 腳步的小揚塵。跟落地同一個色系但小得多——這個一秒會冒好幾次，
	# 大一點就會變成角色拖著一團霧在走。
	_presets[&"step_puff"] = _preset({
		"amount": 3, "lifetime": 0.22, "spread": 60.0, "gravity": Vector3(0.0, 0.4, 0.0),
		"speed_min": 0.5, "speed_max": 1.2, "damping": 4.0, "size": 0.09,
		"colors": [Color(0.72, 0.68, 0.6, 0.4), Color(0.72, 0.68, 0.6, 0.0)], "additive": false,
	})


func _preset(config: Dictionary) -> Dictionary:
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.billboard_keep_scale = true
	# 少了這一行，color_ramp 完全不會生效——粒子會是一片死白，
	# 而且不會有任何錯誤訊息。
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.disable_receive_shadows = true
	material.albedo_color = Color.WHITE
	if config["additive"]:
		material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD

	var ramp := Gradient.new()
	var colors: Array = config["colors"]
	ramp.set_color(0, colors[0])
	ramp.set_color(1, colors[1])

	# 邊飛邊縮，收尾才不會是一堆方塊同時消失。
	var size_curve := Curve.new()
	size_curve.add_point(Vector2(0.0, 1.0))
	size_curve.add_point(Vector2(1.0, 0.0))

	var out := config.duplicate()
	out["mesh"] = mesh
	out["material"] = material
	out["ramp"] = ramp
	out["size_curve"] = size_curve
	return out
