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
	{"shape": &"box", "size": Vector3(0.017, 1.030, 0.017), "at": Vector3(0, 0, -0.164),
		"color": &"path_edge"},
]

## 法杖：長桿 + 頂端的球。球用 `goal`——配色表裡唯一有自發光的暖色，
## 而且 `default_env.tres` 的 glow 門檻是 1.1，這顆會真的在畫面上暈開。
const STAFF := [
	{"shape": &"box", "size": Vector3(0.056, 1.050, 0.056), "at": Vector3(0, 0.280, 0),
		"color": &"wood"},
	{"shape": &"box", "size": Vector3(0.090, 0.062, 0.090), "at": Vector3(0, 0.835, 0),
		"color": &"stone"},
	{"shape": &"sphere", "size": 0.105, "at": Vector3(0, 0.940, 0), "color": &"goal"},
]

const SHAPES := {&"sword": SWORD, &"bow": BOW, &"staff": STAFF}


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

	var root := Node3D.new()
	root.name = String(kind).capitalize()
	var spin: Vector3 = GRIP_SPIN + grip.get("spin", Vector3.ZERO)
	root.transform = Transform3D(
		Basis.from_euler(
			Vector3(deg_to_rad(spin.x), deg_to_rad(spin.y), deg_to_rad(spin.z))
		),
		(grip.get("at", Vector3.ZERO) as Vector3) * ratio
	)
	root.scale = Vector3.ONE * ratio
	socket.add_child(root)

	for item in SHAPES[kind]:
		root.add_child(_part(item))
	return socket


static func _part(spec: Dictionary) -> MeshInstance3D:
	var node := MeshInstance3D.new()
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
