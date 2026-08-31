class_name Campfire
extends OmniLight3D

## 營火的火焰與閃爍。
##
## 這是整個營地裡最大的「這裡活著」的訊號，而它只有幾行——一團會呼吸的暖光，
## 比多放十個靜止的物件有用得多。
##
## 火塘的石圈與柴由 scenery.gd 長出來（那些是靜態幾何）；這裡只管會動的部分。
##
## 純本機表演，不進同步：每一端各自跑同一條正弦，看起來一樣就夠了，
## 不值得為了「火焰完全同步」占頻寬。

## 兩個不成整數比的頻率疊起來，讀起來才像火而不像節拍器。
## 單一正弦會有明顯的週期，人眼很容易抓到。
const BASE_ENERGY := 2.4
const FLICKER_A := Vector2(0.5, 7.1)
const FLICKER_B := Vector2(0.3, 11.7)

const FLAME_COUNT := 14
const SMOKE_COUNT := 8

var _clock := 0.0


func _ready() -> void:
	_spawn_flame()
	_spawn_smoke()


func _process(delta: float) -> void:
	_clock += delta
	light_energy = (
		BASE_ENERGY
		+ FLICKER_A.x * sin(_clock * FLICKER_A.y)
		+ FLICKER_B.x * sin(_clock * FLICKER_B.y)
	)


## 火焰。用 CPUParticles3D 跟 Vfx 那一層同一個理由：GPU 粒子在無頭環境下驗不了，
## 而且這裡的量小到 CPU 完全不是問題。
func _spawn_flame() -> void:
	var particles := CPUParticles3D.new()
	particles.name = "Flame"
	particles.amount = FLAME_COUNT
	particles.lifetime = 0.85
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = 0.28
	particles.direction = Vector3.UP
	particles.spread = 12.0
	particles.gravity = Vector3.UP * 1.4
	particles.initial_velocity_min = 0.7
	particles.initial_velocity_max = 1.5
	particles.scale_amount_min = 0.16
	particles.scale_amount_max = 0.34
	var ramp := Gradient.new()
	ramp.set_color(0, Palette.color(&"goal"))
	ramp.set_color(1, Color(Palette.color(&"ember"), 0.0))
	particles.color_ramp = ramp
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	particles.material_override = material
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.5, 0.5)
	particles.mesh = mesh
	add_child(particles)
	particles.position = Vector3(0.0, -1.2, 0.0)


func _spawn_smoke() -> void:
	var particles := CPUParticles3D.new()
	particles.name = "Smoke"
	particles.amount = SMOKE_COUNT
	particles.lifetime = 3.2
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = 0.2
	particles.direction = Vector3.UP
	particles.spread = 18.0
	# 煙往上飄，所以重力是**正的**。這一行看起來像打錯了，但沒有。
	particles.gravity = Vector3.UP * 0.4
	particles.initial_velocity_min = 0.5
	particles.initial_velocity_max = 0.9
	particles.scale_amount_min = 0.4
	particles.scale_amount_max = 0.9
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.42, 0.40, 0.38, 0.30))
	ramp.set_color(1, Color(0.55, 0.55, 0.55, 0.0))
	particles.color_ramp = ramp
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	particles.material_override = material
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.9, 0.9)
	particles.mesh = mesh
	add_child(particles)
	particles.position = Vector3(0.0, -0.6, 0.0)
