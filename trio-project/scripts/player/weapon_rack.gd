class_name WeaponRack
extends RefCounted

## 把武器掛到角色的手骨上。
##
## 為什麼武器是用程式組而不是三個 `.tscn`：顏色一律要從 `Palette` 拿
## （配色表封閉在 25 色，`.tscn` 沒辦法呼叫程式，只能指到 `.tres`），而且
## 尺寸必須跟著**這隻角色的骨架實際高度**縮放，那是載入時才量得到的數字。
## 場景檔兩件事都做不到。組法與 `scenery.gd` 一樣：一張零件表 + 一個迴圈。
##
## ## 座標約定：所有數字都寫在「1.6 公尺的角色」上
##
## 掛上去的時候乘以 `骨架實際高度 / 1.6`。這一步同時解掉
## `CharacterVisual._fit_size()` 的坑：那裡是寫 `_model.scale`，骨架是它的
## 子孫，武器會跟著被縮——所以武器的尺寸要定在**縮放前**的骨架空間，
## 也就是這裡量到的高度，不是名冊上的目標身高。兩者今天剛好一樣
## （三份 GLB 都正規化過了），但寫成名冊身高的話，哪天資產壞掉就會
## 「角色縮小了、武器沒有」。
##
## ## 手骨的局部座標（三隻一致，實測過）
##
##   RightHand：  +X = 角色正面   +Y = 往身體外側（右）  +Z = 下
##   LeftHand ：  +X = 角色背面   +Y = 往身體外側（左）  +Z = 下
##
## 武器一律建成「握點在原點、指向自己的 +Y」，掛上去時繞 X 轉 180 度，
## 武器的 +Y 就對上手骨的 −Y。這就是 `GRIP_SPIN`。
##
## **上面那三軸是「靜置姿勢」下的方向，而武器是焊在手上的，實際朝向要看
## 當下的姿勢。** 第一版照著靜置姿勢推，算出「繞 X 轉 −90」，結果三把武器
## 全部橫躺——因為站著的時候手臂是垂下來的，手骨繞著前方軸轉了大約 75 度，
## 骨頭的 +Y 從「往身體外側」變成「朝下」。所以基準角度是照**垂手站姿**訂的，
## 不是照靜置姿勢。

## 零件表的基準身高。所有 `size`／`at` 都是在這個身高下的公尺數。
const REFERENCE_HEIGHT := 1.6

## 把「武器的 +Y」轉到「手骨的 −Y」——垂手站著的時候那就是正上方。
## 逐隻的微調寫在名冊裡，疊在這個基準上。
const GRIP_SPIN := Vector3(180.0, 0.0, 0.0)

## 三把武器的零件。每一個是
## {"shape": box|sphere|prism, "size": Vector3 或半徑, "at": Vector3,
##  "spin": Vector3（度，可省略）, "color": Palette 的顏色名}
##
## 劍：刀身灰（`rock`＝可扛的石頭那個灰，冷色）、護手與劍首用暖灰 `stone`、
## 握把 `wood`。三段明度 0.616 / 0.528 / 0.349 分得開，縮圖也看得出結構。
const SWORD := [
	{"shape": &"box", "size": Vector3(0.058, 0.190, 0.058), "at": Vector3(0, 0, 0),
		"color": &"wood"},
	{"shape": &"sphere", "size": 0.044, "at": Vector3(0, -0.110, 0), "color": &"stone"},
	{"shape": &"box", "size": Vector3(0.300, 0.058, 0.078), "at": Vector3(0, 0.115, 0),
		"color": &"stone"},
	{"shape": &"box", "size": Vector3(0.135, 0.500, 0.046), "at": Vector3(0, 0.395, 0),
		"color": &"rock"},
	{"shape": &"prism", "size": Vector3(0.135, 0.140, 0.046), "at": Vector3(0, 0.715, 0),
		"color": &"rock"},
]

## 弓：弓臂是「握把 + 兩段折線」的半邊，上下鏡像。折線角度 −14° 與 −34°
## 是接得起來的一組——第一段的外端 (y 0.346, z −0.057) 正好是第二段的內端。
## 改角度就要重算，接不上會看到一個缺口。
##
## 弦拉在兩個梢之間（z = −0.164），也就是**靠身體那一側**。弓面朝前、弦朝胸口
## 才是拿弓的樣子；反了的話遠看不出來，近看整個是錯的。
const BOW := [
	{"shape": &"box", "size": Vector3(0.062, 0.240, 0.074), "at": Vector3(0, 0, 0),
		"color": &"wood_light"},
	{"shape": &"box", "size": Vector3(0.052, 0.240, 0.058), "at": Vector3(0, 0.230, -0.028),
		"spin": Vector3(-14.0, 0, 0), "color": &"wood_light"},
	{"shape": &"box", "size": Vector3(0.052, 0.240, 0.058), "at": Vector3(0, -0.230, -0.028),
		"spin": Vector3(14.0, 0, 0), "color": &"wood_light"},
	{"shape": &"box", "size": Vector3(0.046, 0.200, 0.052), "at": Vector3(0, 0.432, -0.108),
		"spin": Vector3(-34.0, 0, 0), "color": &"wood_light"},
	{"shape": &"box", "size": Vector3(0.046, 0.200, 0.052), "at": Vector3(0, -0.432, -0.108),
		"spin": Vector3(34.0, 0, 0), "color": &"wood_light"},
	# 弦是**兩段**，不是一根：拉弓的時候中間那個搭箭點要跟著右手往後走。
	# 一根固定的長方體看起來就是「射箭時弦完全不動」——那是弓手最露餡的一格。
	# 兩段的端點與長度由 `bow_string.gd` 每幀算，這裡寫的只是初始尺寸。
	{"shape": &"box", "size": Vector3(0.017, 0.515, 0.017), "at": Vector3(0, 0.258, -0.164),
		"color": &"path_edge", "part": &"string_upper"},
	{"shape": &"box", "size": Vector3(0.017, 0.515, 0.017), "at": Vector3(0, -0.258, -0.164),
		"color": &"path_edge", "part": &"string_lower"},
	# 箭：搭在弦上、指向弓的前方（+Z）。**平時隱藏**，拉弓時才由 `bow_string.gd` 顯示、
	# 放手時隱藏並放一道箭痕。沒有箭的話拉弓再好看也像在拉空氣。
	{"shape": &"box", "size": Vector3(0.012, 0.62, 0.012), "at": Vector3(0, 0, 0.146),
		"spin": Vector3(90.0, 0, 0), "color": &"wood", "part": &"arrow", "hidden": true},
	{"shape": &"prism", "size": Vector3(0.03, 0.06, 0.012), "at": Vector3(0, 0, 0.486),
		"spin": Vector3(90.0, 0, 0), "color": &"stone", "part": &"arrow_head", "hidden": true},
]

## 弓弦兩端固定在哪、以及靜止時搭箭點在哪（武器自己的座標）。
##
## 上下梢的位置與 `BOW` 最後兩段弓臂的外端一致——改了那兩段的角度或長度，
## 這裡要跟著改，不然弦會接在半空中。
const BOW_NOCKS := {
	"upper": Vector3(0.0, 0.515, -0.164),
	"lower": Vector3(0.0, -0.515, -0.164),
	"rest": Vector3(0.0, 0.0, -0.164),
}

## 弓弦最多被拉開多遠（武器自己的座標，往 −Z 也就是靠身體那一側）。
##
## 0.34 大約是弓高的三分之一——再多，弓臂就該跟著彎了，而弓臂是硬的方塊。
const BOW_DRAW := 0.34

## 法杖：長桿 + 頂端的球。球用 `goal`——配色表裡唯一有自發光的暖色，
## 而且 `default_env.tres` 的 glow 門檻是 1.1，這顆會真的在畫面上暈開。
const STAFF := [
	{"shape": &"box", "size": Vector3(0.056, 1.050, 0.056), "at": Vector3(0, 0.280, 0),
		"color": &"wood"},
	{"shape": &"box", "size": Vector3(0.090, 0.062, 0.090), "at": Vector3(0, 0.835, 0),
		"color": &"stone"},
	# 球有名字：出手那一刻 `CharacterVisual` 會讓它閃一下。
	{"shape": &"sphere", "size": 0.105, "at": Vector3(0, 0.940, 0), "color": &"goal",
		"part": &"orb"},
]

const SHAPES := {&"sword": SWORD, &"bow": BOW, &"staff": STAFF}

## 副手該握在武器的哪一點（武器自己的座標，+Y 指向尖端）。
##
## **放在這裡而不是名冊裡**：這是武器的幾何性質，不是角色的偏好。零件表改了
## 位置，握點就該跟著改——兩個數字放在同一個檔案才不會各走各的。而「哪一隻
## 角色要用副手」也不必另外開一個欄位：**這張表裡有沒有這把武器就是答案**。
##
##   staff  杖身往上 0.38。**第一版是 0.13**，為了搆得到把握點壓到離右手只有
##          11 公分，結果兩隻手擠成一團——使用者一眼就看出來。0.38 讓兩手分開
##          約 25 公分，代價是法杖必須橫抱在胸前（`weapon_aim.TARGETS`），
##          否則左肩搆不到。
##   bow    弦的正中央（z 與 BOW 那條弦一致）——搭箭的地方。
##
## 劍不在表上，所以豬維持單手。劍柄只有 0.19 長，副手只能貼在劍首上，太擠；
## 而且這樣「有副手」與「沒有副手」兩條路都會被真的走過。
const OFF_GRIPS := {
	&"staff": Vector3(0.0, 0.38, 0.0),
	&"bow": Vector3(0.0, 0.0, -0.164),
}


## 這隻角色拿的是哪一把（名冊第一把武器的 kind）。動作與重心是逐武器的
## （`MotionClips.WEAPON_STRIKES`），要靠這個查。
static func kind_of(entry: Dictionary) -> StringName:
	var weapons: Array = entry.get("weapons", [])
	if weapons.is_empty():
		return &""
	return (weapons[0] as Dictionary).get("kind", &"")


## 把名冊裡寫的武器全部掛上去，回傳掛成功幾把。
##
## `skeleton_height` 是**量出來的**骨架高度（`CharacterVisual._measure_height()`），
## 不是名冊上的目標身高。理由見檔頭。
static func attach(skeleton: Skeleton3D, entry: Dictionary, skeleton_height: float) -> int:
	if skeleton == null or skeleton_height <= 0.0:
		return 0
	var ratio := skeleton_height / REFERENCE_HEIGHT
	var built := 0
	for item in entry.get("weapons", []):
		var grip: Dictionary = item
		var kind: StringName = grip.get("kind", &"")
		if not SHAPES.has(kind):
			push_warning("[Weapon] 沒有這把武器：%s" % kind)
			continue
		var bone_name := String(grip.get("bone", &"RightHand"))
		if skeleton.find_bone(bone_name) < 0:
			push_warning("[Weapon] 骨架上沒有 %s，%s 掛不上去" % [bone_name, kind])
			continue
		skeleton.add_child(_grip_node(kind, bone_name, grip, ratio))
		built += 1
	return built


## 一把武器的節點：BoneAttachment3D（跟著骨頭走）→ 偏移用的 Node3D → 零件。
##
## 偏移不能寫在 BoneAttachment3D 自己身上——它每一幀都會把自己的 transform
## 覆寫成骨頭的姿勢，寫上去的東西下一幀就沒了。所以中間一定要多一層。
static func _grip_node(kind: StringName, bone_name: String, grip: Dictionary,
		ratio: float) -> BoneAttachment3D:
	var socket := BoneAttachment3D.new()
	socket.name = "%sSocket" % String(kind).capitalize()
	socket.bone_name = bone_name

	# 武器種類記在掛點上。手部 IK 與 hand_probe 都要知道這掛的是哪一把，
	# 而從節點名稱反推（"BowSocket" -> "bow"）會在有人改名字的那天靜靜地壞掉。
	socket.set_meta(&"weapon_kind", kind)

	var root := Node3D.new()
	root.name = String(kind).capitalize()
	root.transform = grip_transform(grip, ratio)
	socket.add_child(root)

	for item in SHAPES[kind]:
		root.add_child(_part(item))
	if kind == &"bow":
		var string := BowString.new()
		string.name = "BowString"
		root.add_child(string)
	return socket


## 一把武器在**手骨局部座標**下的擺放。
##
## 掛節點、`hand_probe`、`hand_ik` 共用這一份——三邊各自把 `GRIP_SPIN + spin`
## 推一次的話，遲早有一邊會跟另外兩邊對不上，而那種錯只會表現成「武器有點歪」。
static func grip_transform(grip: Dictionary, ratio: float) -> Transform3D:
	var spin: Vector3 = GRIP_SPIN + (grip.get("spin", Vector3.ZERO) as Vector3)
	var basis := Basis.from_euler(
		Vector3(deg_to_rad(spin.x), deg_to_rad(spin.y), deg_to_rad(spin.z))
	)
	return Transform3D(
		basis.scaled(Vector3.ONE * ratio), (grip.get("at", Vector3.ZERO) as Vector3) * ratio
	)


## 武器最遠端在自己座標下的位置。**從零件表算出來**，不要另外寫死一個數字——
## 這是 `hand_probe` 的成績單量的那一點，寫死的話改了零件表成績就不再可比。
static func tip(kind: StringName) -> Vector3:
	var far := 0.0
	for item in SHAPES.get(kind, []):
		far = maxf(far, _top(item))
	return Vector3(0.0, far, 0.0)


## 掛在這副骨架上的武器：[{"socket": …, "root": …, "kind": …, "bone": …}]。
##
## 讀真正掛上去的節點，不重算一次擺放——`root.transform` 就是 `grip_transform()`
## 的結果，連骨架高度的比例都已經在裡面了。
static func mounted(skeleton: Skeleton3D) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if skeleton == null:
		return out
	for node in skeleton.find_children("*Socket", "BoneAttachment3D", true, false):
		var socket: BoneAttachment3D = node
		if socket.get_child_count() == 0 or not socket.has_meta(&"weapon_kind"):
			continue
		out.append({
			"socket": socket,
			"root": socket.get_child(0) as Node3D,
			"kind": socket.get_meta(&"weapon_kind") as StringName,
			"bone": skeleton.find_bone(socket.bone_name),
		})
	return out


## 一個零件在 +Y 方向上伸到多遠（含它自己的 spin）。
static func _top(spec: Dictionary) -> float:
	var at: Vector3 = spec.get("at", Vector3.ZERO)
	if StringName(spec["shape"]) == &"sphere":
		return at.y + float(spec["size"])
	var spin: Vector3 = spec.get("spin", Vector3.ZERO)
	var basis := Basis.from_euler(
		Vector3(deg_to_rad(spin.x), deg_to_rad(spin.y), deg_to_rad(spin.z))
	)
	var half := (spec["size"] as Vector3) * 0.5
	var far := -INF
	for corner in 8:
		far = maxf(
			far,
			(
				basis
				* Vector3(
					half.x if (corner & 1) != 0 else -half.x,
					half.y if (corner & 2) != 0 else -half.y,
					half.z if (corner & 4) != 0 else -half.z
				)
			).y
		)
	return at.y + far


static func _part(spec: Dictionary) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	# 有名字的零件要叫得出來（弓弦那兩段）。用節點名稱而不是索引：
	# 零件表中間插一個東西，索引就全錯了，而那種錯是靜默的。
	if spec.has("part"):
		node.name = String(spec["part"])
	node.visible = not bool(spec.get("hidden", false))
	node.mesh = _mesh(spec)
	# 用 surface override 而不是 material_override：CharacterVisual._cache_materials()
	# 是逐 surface 在複製材質、掛描邊（TD-09 的 inverted hull）、以及登記命中白閃的。
	# 走 material_override 的話武器不會被那個迴圈收進去，結果是**武器沒有描邊、
	# 打到人的時候只有身體閃、武器不閃**——像貼上去的紙片。
	node.set_surface_override_material(0, Palette.surface(spec["color"]))
	var spin: Vector3 = spec.get("spin", Vector3.ZERO)
	node.transform = Transform3D(
		Basis.from_euler(
			Vector3(deg_to_rad(spin.x), deg_to_rad(spin.y), deg_to_rad(spin.z))
		),
		spec["at"]
	)
	# 武器很小，自己不投影也看不出來，但每一把都要多跑一遍陰影 pass。
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


static func _mesh(spec: Dictionary) -> Mesh:
	match StringName(spec["shape"]):
		&"sphere":
			var ball := SphereMesh.new()
			ball.radius = float(spec["size"])
			ball.height = float(spec["size"]) * 2.0
			ball.radial_segments = 12
			ball.rings = 6
			return ball
		&"prism":
			var prism := PrismMesh.new()
			prism.size = spec["size"]
			return prism
		_:
			var box := BoxMesh.new()
			box.size = spec["size"]
			return box
