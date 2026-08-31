class_name Scenery
extends Node3D

## 用程式把關卡的裝飾長出來。資料在 scenery_plan.gd，這裡只負責建網格。
##
## ## 為什麼不寫在 .tscn 裡
##
## 這是 700 個以上的 primitive。手寫那麼多 `[node]` 區塊、同時維持
## `load_steps` 精確（tools/check_project.py 會逐檔驗算式 `ext + sub + 1`），
## 錯一次就是 CI 紅。而且 `.tscn` **沒辦法表達「這 52 個方塊是一個 draw call」**，
## MultiMeshInstance3D 可以——而 docs/PLAYTEST.md 要測試者在一台機器上開三個
## client，那個差別是會不會卡的差別。
##
## 這也是專案既有的做法：MotionForge 生動畫、Vfx 生粒子，都是「資料表一個檔、
## 產生器一個檔」。
##
## ## 連線安全（每一條都對應一個會出事的東西）
##
##  - 生出來的東西**全部掛在這個節點底下**。Godot 的 NodePath 認名字，
##    加名字不同的子節點不會擾動任何既有路徑，而 CombatSystem 與 CarrySystem
##    是**把絕對節點路徑當字串送過網路的**。
##  - 生出來的東西**不是** PhysicsBody3D／Area3D、不加入任何群組、不被
##    queue_free()。它對玩法完全不存在。
##  - 亂數一律用帶固定種子的 RandomNumberGenerator 實例，三台機器長出同一個世界。
##  - 這個檔案裡**一個錢字號開頭的節點路徑字面值都不能有**：check_wiring.py
##    會拿每一個去掛著這個腳本的場景裡找，找不到就報錯。而這個節點底下的
##    東西全是執行期生的，場景檔裡一個都沒有。只用 add_child 就天然滿足。

## 路面浮在地面上方多少。
##
## 為什麼是 2 公分：可走幾何一格都不能動（docs/07），所以路是一片不參與碰撞的
## 薄片，玩家還是站在 Y=0，腳底在路面下 2 公分。用實際的鏡頭參數算，那在 720p
## 下大約是 0.34 個像素，看不出來。
##
## 為什麼不是 5 公釐：Forward+ 用反轉 Z 的浮點深度緩衝，5 公釐在 60 公尺外綽綽
## 有餘；但**截圖用的 Compatibility 渲染器是 24-bit 定點**，60 公尺處的解析度
## 約 4.3 公釐——低於 10 公釐的話，會在我用來判斷好壞的那個工具裡閃爍。
const PATH_LIFT := 0.02
const CLUMP_LIFT := 0.01

## 路面橫斷面的取樣位置（半寬的倍數）與各自的頂點色乘數。
##
## 車轍與邊緣淡出**不是第二層薄片**，是同一份網格裡的頂點色。多一層共面的薄片
## 就是多一個 z-fighting 的來源，而這樣做是免費的。
## 0.79 是 PATH_RUT 除以 PATH 的比值，0.86 讓路邊融進草地、不像貼上去的貼紙。
const CROSS_OFFSETS: Array[float] = [-1.0, -0.45, 0.0, 0.45, 1.0]
const CROSS_SHADES: Array[float] = [0.86, 0.79, 1.0, 0.79, 0.86]

## 中心線先細分再平滑，折線才會變成曲線。
const RESAMPLE_STEP := 0.9
const SMOOTH_PASSES := 6

## 邊石。
##
## **只有一條變色的帶狀物讀起來像地毯；讓人一眼認出「路」的是兩排石頭。**
## 石頭半埋在地裡（頂端只露 6–16 公分），所以玩家走過去不會看到穿模——
## 它們沒有碰撞，露太多的話腳會穿過去。
const KERB_SPACING := 1.4
const KERB_JITTER := 0.35
const KERB_GAP := 0.25
const KERB_TOP := Vector2(0.10, 0.26)
const KERB_SIZE := Vector2(0.22, 0.45)
const KERB_HEIGHT := Vector2(0.34, 0.58)
const KERB_TILT_DEG := 10.0

const CLUMP_SIZE := Vector2(1.6, 3.4)
const CLUMP_CLEARANCE := 1.2

## 哪一關。**匯出成 String 不是 StringName**：godot-parser 解析不了
## `.tscn` 裡的 `&"arena"` 這種字面值，而 check_project.py 會整檔解析場景。
@export var level_id: String = "arena"

var _key: StringName = &""
var _rng := RandomNumberGenerator.new()

## 每一條折線各自的取樣點與半寬：`[{"points": [...], "widths": [...]}, …]`。
##
## **要逐條分開存，不能接成一條陣列**——接起來的話，主線的終點與下一條岔路的
## 起點會被當成相鄰的兩點，切線算出來是亂的，邊石就掉在中間的草地上。
var _lines: Array = []


func _ready() -> void:
	_key = StringName(level_id)
	if not SceneryPlan.SEEDS.has(_key):
		push_warning("[Scenery] 沒有 %s 這一關的裝飾資料" % level_id)
		return
	_rng.seed = int(SceneryPlan.SEEDS[_key])
	_build_paths()
	_build_kerbs()
	_build_clumps()


# --- 路面 -------------------------------------------------------------------


## 所有折線做成**一份** ArrayMesh，整條路一個 draw call。
func _build_paths() -> void:
	var lines: Array = SceneryPlan.PATHS.get(_key, [])
	if lines.is_empty():
		return
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for entry in lines:
		var line: Array = entry
		var points: Array[Vector3] = []
		var widths: Array[float] = []
		_resample(line, points, widths)
		_emit_ribbon(tool, points, widths)
		_lines.append({"points": points, "widths": widths})
	_attach_mesh("PathSurface", tool.commit(), &"path", PATH_LIFT, true)


## 折線 → 平滑的曲線。位置與半寬一起處理，兩者才不會脫節。
func _resample(line: Array, points: Array[Vector3], widths: Array[float]) -> void:
	for index in line.size() - 1:
		var here: Dictionary = line[index]
		var next: Dictionary = line[index + 1]
		var from: Vector3 = here["p"]
		var to: Vector3 = next["p"]
		var steps := maxi(1, int(ceil(from.distance_to(to) / RESAMPLE_STEP)))
		for step in steps:
			var ratio := float(step) / float(steps)
			points.append(from.lerp(to, ratio))
			widths.append(lerpf(float(here["w"]), float(next["w"]), ratio))
	var last: Dictionary = line[line.size() - 1]
	points.append(last["p"])
	widths.append(float(last["w"]))

	# 平滑：每一點往兩個鄰居的中點靠。端點不動，否則路會從崖唇縮回去。
	for _pass in SMOOTH_PASSES:
		var moved := points.duplicate()
		for index in range(1, points.size() - 1):
			moved[index] = points[index].lerp(
				(points[index - 1] + points[index + 1]) * 0.5, 0.5
			)
		points.assign(moved)


## 沿著中心線鋪出帶狀網格。橫斷面五個點：兩側邊緣、兩道車轍、中線。
func _emit_ribbon(tool: SurfaceTool, points: Array[Vector3], widths: Array[float]) -> void:
	if points.size() < 2:
		return
	var rows: Array = []
	for index in points.size():
		var forward := _tangent(points, index)
		# 右手邊的水平法線。地面是平的，所以不必管 y。
		var right := Vector3(-forward.z, 0.0, forward.x).normalized()
		var row: Array[Vector3] = []
		for offset in CROSS_OFFSETS:
			row.append(points[index] + right * (offset * widths[index]))
		rows.append(row)

	for index in rows.size() - 1:
		var near: Array = rows[index]
		var far: Array = rows[index + 1]
		for lane in CROSS_OFFSETS.size() - 1:
			_quad(
				tool,
				near[lane], near[lane + 1], far[lane + 1], far[lane],
				CROSS_SHADES[lane], CROSS_SHADES[lane + 1]
			)


## 這一點的前進方向。用前後鄰居算，轉角才不會出現尖角。
func _tangent(points: Array[Vector3], index: int) -> Vector3:
	var before: Vector3 = points[maxi(index - 1, 0)]
	var after: Vector3 = points[mini(index + 1, points.size() - 1)]
	var direction := after - before
	direction.y = 0.0
	if direction.length_squared() < 0.000001:
		return Vector3.FORWARD
	return direction.normalized()


## 一格路面。繞向是**順時針（從上方看）**——Godot 的正面是順時針，
## 反了的話整條路會被背面剔除掉：材質、位置、AABB 全部正確，就是畫不出來。
## 法線直接寫死朝上，不用 generate_normals()——平貼地面的東西沒有理由去算它，
## 而算錯的下場是路比草地暗，「明度負責路」整條規則反過來。
func _quad(
	tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
	shade_a: float, shade_b: float
) -> void:
	var left := Color(shade_a, shade_a, shade_a)
	var right := Color(shade_b, shade_b, shade_b)
	for item in [[a, left], [c, right], [b, right], [a, left], [d, left], [c, right]]:
		var pair: Array = item
		tool.set_color(pair[1])
		tool.set_normal(Vector3.UP)
		tool.add_vertex(pair[0])


# --- 邊石 -------------------------------------------------------------------


## 兩排半埋的石頭，一個 MultiMesh 一個 draw call。
func _build_kerbs() -> void:
	var transforms: Array[Transform3D] = []
	for entry in _lines:
		var line: Dictionary = entry
		var points: Array[Vector3] = line["points"]
		var widths: Array[float] = line["widths"]
		var travelled := 0.0
		var next_stone := KERB_SPACING
		for index in range(1, points.size()):
			travelled += points[index].distance_to(points[index - 1])
			if travelled < next_stone:
				continue
			next_stone += KERB_SPACING
			var forward := _tangent(points, index)
			var right := Vector3(-forward.z, 0.0, forward.x).normalized()
			for side in [-1.0, 1.0]:
				var along := forward * _rng.randf_range(-KERB_JITTER, KERB_JITTER)
				var spot: Vector3 = points[index] + along
				spot += right * side * (widths[index] + KERB_GAP)
				if _blocked(spot):
					continue
				transforms.append(_stone_transform(spot))
	if transforms.is_empty():
		return
	_attach_multimesh("Kerb", BoxMesh.new(), &"path_edge", transforms)


func _stone_transform(spot: Vector3) -> Transform3D:
	var size := Vector3(
		_rng.randf_range(KERB_SIZE.x, KERB_SIZE.y),
		_rng.randf_range(KERB_HEIGHT.x, KERB_HEIGHT.y),
		_rng.randf_range(KERB_SIZE.x, KERB_SIZE.y)
	)
	var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU))
	basis = basis.rotated(Vector3.RIGHT, deg_to_rad(_rng.randf_range(-KERB_TILT_DEG, KERB_TILT_DEG)))
	basis = basis.rotated(Vector3.BACK, deg_to_rad(_rng.randf_range(-KERB_TILT_DEG, KERB_TILT_DEG)))
	# 半埋：頂端只露出 KERB_TOP 那麼多，其餘埋進地裡。
	var top := _rng.randf_range(KERB_TOP.x, KERB_TOP.y)
	var origin := Vector3(spot.x, top - size.y * 0.5, spot.z)
	return Transform3D(basis.scaled(size), origin)


## 這個位置在不放邊石的區域裡嗎（藤蔓框下、樹樁上、斷崖裡、終點台底下）。
func _blocked(spot: Vector3) -> bool:
	for entry in SceneryPlan.NO_KERB.get(_key, []):
		var box: Dictionary = entry
		var low: Vector2 = box["min"]
		var high: Vector2 = box["max"]
		if spot.x >= low.x and spot.x <= high.x and spot.z >= low.y and spot.z <= high.y:
			return true
	return false


# --- 地面暗塊 ---------------------------------------------------------------


## 不規則的暗色斑塊，只為了讓平滑的路讀起來是刻意的。
##
## 一定要避開路面：兩片共面的薄片重疊就會閃。
func _build_clumps() -> void:
	var spec: Dictionary = SceneryPlan.CLUMPS.get(_key, {})
	if spec.is_empty():
		return
	var half: Vector2 = spec["half"]
	var centre: Vector3 = spec["centre"]
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var made := 0
	for _try in int(spec["count"]) * 6:
		if made >= int(spec["count"]):
			break
		var spot := centre + Vector3(
			_rng.randf_range(-half.x, half.x), 0.0, _rng.randf_range(-half.y, half.y)
		)
		if _near_path(spot):
			continue
		_emit_clump(tool, spot)
		made += 1
	if made == 0:
		return
	_attach_mesh("TurfClumps", tool.commit(), &"turf_dark", CLUMP_LIFT, false)


func _emit_clump(tool: SurfaceTool, centre: Vector3) -> void:
	var corners: Array[Vector3] = []
	var radius := _rng.randf_range(CLUMP_SIZE.x, CLUMP_SIZE.y) * 0.5
	var spin := _rng.randf_range(0.0, TAU)
	for step in 5:
		var angle := spin + TAU * float(step) / 5.0
		var reach := radius * _rng.randf_range(0.65, 1.0)
		corners.append(centre + Vector3(cos(angle) * reach, 0.0, sin(angle) * reach))
	for step in range(1, corners.size() - 1):
		for point in [centre, corners[step], corners[step + 1]]:
			tool.set_color(Color.WHITE)
			tool.set_normal(Vector3.UP)
			tool.add_vertex(point)
	for point in [centre, corners[corners.size() - 1], corners[0]]:
		tool.set_color(Color.WHITE)
		tool.set_normal(Vector3.UP)
		tool.add_vertex(point)


func _near_path(spot: Vector3) -> bool:
	for entry in _lines:
		var line: Dictionary = entry
		var points: Array[Vector3] = line["points"]
		var widths: Array[float] = line["widths"]
		for index in points.size():
			var flat := Vector2(spot.x - points[index].x, spot.z - points[index].z)
			if flat.length() < widths[index] + CLUMP_CLEARANCE:
				return true
	return false


# --- 掛上去 -----------------------------------------------------------------


func _attach_mesh(
	node_name: String, mesh: ArrayMesh, material_id: StringName, lift: float, vertex_color: bool
) -> void:
	if mesh == null:
		return
	var material := Palette.surface(material_id)
	if vertex_color:
		# 車轍與邊緣淡出是頂點色乘上去的，材質本身要打開這個開關。
		# duplicate 一份：Palette 的那一份是共用的，直接改會影響別人。
		material = material.duplicate()
		material.vertex_color_use_as_albedo = true
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	# 薄片不投影：它貼在地上，影子只會變成沿著路的一條黑邊。
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	instance.position = Vector3(0.0, lift, 0.0)


func _attach_multimesh(
	node_name: String, mesh: Mesh, material_id: StringName, transforms: Array[Transform3D]
) -> void:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for index in transforms.size():
		multi.set_instance_transform(index, transforms[index])
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multi
	instance.material_override = Palette.surface(material_id)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# **一定要明寫 custom_aabb。** 實例散佈在 56 公尺、節點卻在原點，
	# 引擎算出來的邊界是錯的，整批東西會隨著轉鏡頭忽隱忽現——
	# 那看起來會像驅動程式的 bug，但其實是這一行沒寫。
	instance.custom_aabb = _bounds(transforms)
	add_child(instance)


func _bounds(transforms: Array[Transform3D]) -> AABB:
	var low := Vector3(INF, INF, INF)
	var high := -low
	for item in transforms:
		var origin: Vector3 = item.origin
		var reach: Vector3 = item.basis.get_scale() * 0.87  # 方塊的半對角線
		low = low.min(origin - reach)
		high = high.max(origin + reach)
	return AABB(low, high - low)
