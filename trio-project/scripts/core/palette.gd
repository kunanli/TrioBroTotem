class_name Palette
extends RefCounted

## 全遊戲配色的唯一來源。
##
## 為什麼要有這一層（跟 outline.gd 是同一個理由，只是低一層）：以前每個
## `.tscn` 各自寫 `[sub_resource type="StandardMaterial3D"]`，結果**同一種棕色
## 被寫了四份**，用在圍籬、原木、樹樁台、以及泥偶身上——四個語意完全不同的
## 東西長得一模一樣，而且沒有任何一個地方可以一次調完。
##
## ## 兩條規則，效果幾乎全部來自它們
##
## **一、明度負責路。** 路是地面高度上最亮的大面積，永遠比旁邊的草地亮至少
## 0.15 相對明度。低多邊形卡通風好看的前提就是明度分得開；分不開就是一片泥。
## 重做前全世界 14 份材質的明度擠在 0.29–0.43 這個 0.14 寬的區間裡，
## 泥偶與圍籬的明度**完全一樣**（都是 0.291）。
##
## **二、飽和度保留給「可以互動的東西」。** 地形一律去飽和（最大減最小通道
## < 0.12）；打得到、扛得動、爬得上、要走過去的東西才飽和。這一條同時修掉
## 三件事：泥偶跟地形同一種棕、石頭跟木箱同一種黃褐、藤蔓牆跟別的綠分不出來。
##
## ## 加一個顏色就要刪一個
##
## 這張表**封閉在 25 色**。低多邊形的失敗長相是素材大雜燴，而防線就是不准長。
## 逐實例的變化只准動明度（±8%），絕不動色相。
##
## ## 為什麼崖壁的反照率看起來高得不合理
##
## 平塗渲染裡「垂直面比水平面暗」是自動發生的：主光壓到 32° 仰角之後，
## 牆面法線與光的夾角只讓它拿到約 0.32 倍照度，地面卻拿到 0.53 倍。
## 第一版把崖壁訂在 0.309，實際截圖是**整條走廊變成一個黑盒子**。
## 所以崖壁的數字要照「畫面上」而不是「表上」來訂——0.489 的反照率在牆上
## 算出來大約是 0.16，仍然比地面的 0.20 暗，該有的層次還在。
##
## 這也是為什麼環境光改成 `ambient_light_source = COLOR` 而不是跟著天空：
## 天空要亮（它是天空），但天空一亮，整個世界就被均勻的灰洗一遍，
## 又回到當初要修的那個問題。兩者要能分開調。
##
## ## 為什麼 .tres 與這張表兩份
##
## `.tscn` 沒辦法呼叫程式，所以場景裡指的是 `scenes/world/materials/*.tres`；
## 但程式生成的裝飾（scenery.gd）需要在程式裡拿到同一份材質。兩份會漂移，
## 所以 `tools/check_project.py` 會逐項比對 `.tres` 的 albedo 與這張表——
## 跟 `check_wiring.py` 早就在做的 characters.json ↔ character_roster.gd
## 身高比對是同一招。

const MATERIAL_DIR := "res://scenes/world/materials"

## 相對明度＝0.2126R + 0.7152G + 0.0722B（標在註解裡，改顏色時要一起看）。
const COLORS := {
	&"cliff_deep": Color(0.16, 0.17, 0.20),  # 0.170 崖底、帳篷內側
	&"corrupt": Color(0.21, 0.15, 0.26),  # 0.171 泥偶，全世界唯一的紫
	&"turf_dark": Color(0.22, 0.28, 0.20),  # 0.261 地面暗塊
	&"ground_horizon": Color(0.26, 0.27, 0.25),  # 0.266 天空下半
	&"cliff_face": Color(0.48, 0.49, 0.50),  # 0.489 谷壁前排（見下面「為什麼這麼亮」）
	&"path_edge": Color(0.33, 0.34, 0.34),  # 0.338 路邊石
	&"wood": Color(0.46, 0.33, 0.21),  # 0.349 圍籬、原木、看板骨架
	&"turf": Color(0.30, 0.38, 0.27),  # 0.355 地面
	&"cliff_cap": Color(0.34, 0.42, 0.30),  # 0.394 谷壁頂的草
	&"vine": Color(0.26, 0.46, 0.22),  # 0.400 裝飾垂藤（打不壞的那種）
	&"path_rut": Color(0.44, 0.40, 0.32),  # 0.403 車轍，只走頂點色
	&"stone": Color(0.40, 0.41, 0.40),  # 0.407 **石頭＝爬得上去**
	&"corrupt_glow": Color(0.80, 0.28, 0.90),  # 0.435 泥偶自發光、崖底霧氣
	&"cliff_lit": Color(0.62, 0.65, 0.65),  # 0.641 遠山（空氣透視）
	&"wood_light": Color(0.64, 0.49, 0.31),  # 0.509 帳篷布、看板面
	&"path": Color(0.55, 0.51, 0.41),  # 0.511 **路**
	&"sky_top": Color(0.40, 0.54, 0.72),  # 0.523 天頂
	&"ember": Color(0.98, 0.52, 0.18),  # 0.593 營火
	&"rock": Color(0.60, 0.62, 0.63),  # 0.616 可扛的石頭（灰的，不是黃褐）
	&"crate": Color(0.78, 0.62, 0.35),  # 0.635 木箱
	&"vine_break": Color(0.38, 0.78, 0.26),  # 0.657 **可破壞的藤蔓，唯一的飽和綠**
	&"totem": Color(0.72, 0.66, 0.55),  # 0.665 圖騰石
	&"fog": Color(0.70, 0.76, 0.74),  # 0.746 深度霧
	&"goal": Color(1.00, 0.82, 0.28),  # 0.819 終點
	&"sky_horizon": Color(0.80, 0.83, 0.79),  # 0.821 地平線帶
}

## 需要不只 albedo 的那幾份。其餘一律純色、`roughness` 維持 1.0。
##
## 為什麼不加光澤：沒有高光的解法是**低角度的主光 ＋ 冷色補光**，不是把材質
## 調亮面——加光澤會直接牴觸 docs/09 的「色塊乾淨」。
const EXTRAS := {
	&"corrupt": {"emission": &"corrupt_glow", "energy": 0.45, "roughness": 0.9},
	&"ember": {"emission": &"ember", "energy": 2.2},
	&"goal": {"emission": &"goal", "energy": 1.4, "alpha": 0.35},
}

static var _cache: Dictionary = {}


static func color(id: StringName) -> Color:
	if not COLORS.has(id):
		push_warning("[Palette] 沒有這個顏色：%s" % id)
		return Color.MAGENTA
	return COLORS[id]


## 這個顏色的共用材質。第一次呼叫時取得，之後每次回傳同一份。
##
## 有 `.tres` 檔就載它，沒有就當場建——這樣「場景指到的那一份」與「程式拿到的
## 那一份」是**同一個物件**，不是兩份剛好同色的東西。程式生成的裝飾（路面、
## 邊石、谷壁）沒有場景會指到，所以不必為它們各留一個檔案。
static func surface(id: StringName) -> StandardMaterial3D:
	if _cache.has(id):
		return _cache[id]
	var path := "%s/%s.tres" % [MATERIAL_DIR, id]
	var material: StandardMaterial3D = null
	if ResourceLoader.exists(path):
		material = load(path)
	if material == null:
		material = build(id)
	_cache[id] = material
	return material


## 從顏色表現場建一份材質。`.tres` 檔的內容必須跟這裡算出來的一致。
static func build(id: StringName) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	var albedo := color(id)
	var extra: Dictionary = EXTRAS.get(id, {})
	if extra.has("alpha"):
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		albedo.a = float(extra["alpha"])
	material.albedo_color = albedo
	if extra.has("roughness"):
		material.roughness = float(extra["roughness"])
	if extra.has("emission"):
		material.emission_enabled = true
		material.emission = color(extra["emission"])
		material.emission_energy_multiplier = float(extra.get("energy", 1.0))
	return material


## 同一種東西擺很多份時的明度抖動。**只動明度，不動色相**——動色相就會從
## 「一片崖壁」變成「一堆顏色不一樣的方塊」。
static func jitter(base: Color, amount: float) -> Color:
	var scale := clampf(1.0 + amount, 0.0, 2.0)
	return Color(base.r * scale, base.g * scale, base.b * scale, base.a)


## 相對明度。配色表的註解就是用這個算的，調顏色時拿它驗「有沒有分開」。
static func luminance(value: Color) -> float:
	return 0.2126 * value.r + 0.7152 * value.g + 0.0722 * value.b
