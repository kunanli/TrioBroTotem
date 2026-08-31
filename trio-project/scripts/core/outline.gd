class_name Outline
extends RefCounted

## 描邊材質的唯一來源（TD-09 的 inverted hull）。
##
## 為什麼要有這一層而不是各處自己 new 一份：描邊的粗細與顏色是**全遊戲一致**的
## 視覺語言，散在角色與敵人兩處遲早會調到不一樣。而且共用同一份 ShaderMaterial
## 也讓所有描邊只佔一份材質，不是每隻角色一份。
##
## 誰有描邊：**會動的東西**（角色、敵人）。場景方塊沒有。
## 全部都描會變成線稿，而 docs/09 要的是「色塊乾淨」——描邊在這裡的任務是
## 把玩家與威脅從背景裡拉出來，不是描出每一個角。

const SHADER_PATH := "res://scripts/shaders/outline.gdshader"

## 描邊在畫面上的粗細（外推量會乘上到鏡頭的距離，所以遠近一樣粗）。
## 調這一個數字就好，其餘兩個是保險。
const WIDTH := 0.006

## 太薄的部位（耳朵、手指）外推不足會破洞，墊一個最小厚度。
const MIN_WIDTH := 0.012

## 不用純黑：純黑在暗處會跟陰影糊在一起，帶一點藍紫比較乾淨。
const COLOR := Color(0.05, 0.04, 0.06)

static var _shared: ShaderMaterial = null


## 共用的描邊材質。第一次呼叫時建，之後每次回傳同一份。
static func material() -> ShaderMaterial:
	if _shared != null:
		return _shared
	var shader: Shader = load(SHADER_PATH)
	if shader == null:
		push_warning("[Outline] 載入不到 %s，這一輪沒有描邊" % SHADER_PATH)
		return null
	_shared = ShaderMaterial.new()
	_shared.shader = shader
	_shared.set_shader_parameter("width", WIDTH)
	_shared.set_shader_parameter("min_width", MIN_WIDTH)
	_shared.set_shader_parameter("line_color", COLOR)
	return _shared
