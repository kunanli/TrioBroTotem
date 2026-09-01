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

## 淨空區的上下界。左右範圍改由 SceneryPlan.KEEP_CLEAR 逐關指定——
## 寫死 |x| < 6 只涵蓋南北向的走廊，前廳是東西向的，種在裡面的裝飾會**靜默通過**。
const CLEARANCE_FLOOR := 0.35

## 淨空要查到多高。
##
## **不是 `ARCH_CLEARANCE`（10 公尺）**——那是拱門的高度，不是玩家的高度。
## 三層疊高的乘客站在 3.00、跳起來摸到 4.51、身高再 1.7，六公尺半是上限。
## 用 10 公尺去查，谷壁**刻意做的懸崖突出**（頂端往內傾）就會被算成擋路的石頭：
## 十公尺高的地方伸出來兩公尺是氣氛，不是障礙。
const CLEARANCE_CEILING := 6.5

## 谷壁預設排幾排、每排往後退多少。後排只是為了堵掉前排之間的縫，所以退得很淺——
## 退太多就會變成「遠處另有一道牆」而不是同一面崖壁的深度。
##
## 逐段可以用 `rows` 覆寫。**兩個房間之間只隔一公尺半岩石的那幾道牆只能排一排**：
## 後排錯開半格又往後退 1.4 公尺，加起來就長到隔壁房間的地板上了。
const ROW_COUNT := 2
const ROW_SETBACK := 1.4

## 沿著走向抖動每一根柱子的位置。
##
## **這個數字跟 `CLIFFS.width` 綁在一起。** 相鄰兩根最遠是 `step + 2 * ROW_JITTER`
## ＝ 2.6 公尺，而最窄的柱子沿走向是 2.9 × cos(7°) ＝ 2.88 公尺——所以前排一定
## 是連續的、不會開縫。本來是 ±0.5 配 2.0 的寬度，最壞情況會開到 1.2 公尺的縫，
## 而縫後面那根柱子的**側面是被太陽照到的**：正面的明度 0.17、側面 0.55，
## 於是整面谷壁讀起來是「深藍色的牆上畫了一排等距的淺灰色直線」。
## 動這兩個數字之前先算一次這個不等式。
const ROW_JITTER := 0.2

## 柱體後面那一整片：退多遠、多厚、頂端在世界座標的哪個高度。
##
## **退得很淺、也很薄。** 前排現在保證連續（見 `ROW_JITTER`），這一片只是保險，
## 而退太多它就會穿到牆的另一邊——前廳北牆退 2.6 公尺就正好站在凹室的地板上。
const BACKING_SETBACK := 0.6
const BACKING_THICKNESS := 0.6
const BACKING_TOP_Y := 5.0

const CLUMP_SIZE := Vector2(1.6, 3.4)
const CLUMP_CLEARANCE := 1.2

## 哪一關。**匯出成 String 不是 StringName**：godot-parser 解析不了
## `.tscn` 裡的 `&"arena"` 這種字面值，而 check_project.py 會整檔解析場景。
@export var level_id: String = "arena"

## 走廊淨空的違規清單，由 _attach_multimesh 邊建邊記。
##
## **不能用 MultiMesh.get_instance_transform 事後驗**：Godot 4.7 從那個 API
## 讀回來的一律是單位矩陣（寫進去是對的、畫出來也是對的，只有讀回來不對），
## 拿它寫測試會得到「每一批都違規」這種假警報。要驗就在資料還在手上的時候驗。
var clearance_violations: Array[String] = []

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
	# **每一區各自的種子**，不是一條共用的序列。
	#
	# 共用一條序列的話，在既有生成之前插入新生成會把下游全部重洗——山、邊石、
	# 草塊全變。那仍然是決定性的（三台機器還是長得一樣，正確性沒問題），
	# 但你會失去「這次的 diff 是不是真的回歸」的判斷力，因為每次都全變。
	_region(0)
	_build_paths()
	_region(1)
	_build_kerbs()
	_region(2)
	_build_clumps()
	_region(3)
	_build_valley()
	_region(4)
	_build_camp()
	# **把違規講出來。** 這份清單本來是建完就沒人看——README 寫著「結果在
	# clearance_violations 裡」，但沒有任何一支程式讀過它，所以它從第一天起
	# 就是一個沒人看的變數。現在每一次載入關卡都會印，截圖工具也會轉出來。
	for line: String in clearance_violations:
		push_warning("[Scenery] 裝飾長在走道裡：%s" % line)


## 換到某一區自己的亂數序列。1013 是質數，只是讓相鄰區的種子別太接近。
func _region(index: int) -> void:
	_rng.seed = int(SceneryPlan.SEEDS[_key]) + index * 1013


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
			for side: float in ([-1.0, 1.0] as Array[float]):
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
	_emit_clumps(SceneryPlan.CLUMPS.get(_key, {}), "TurfClumps")
	# 前廳自己一區。分開是因為它離原點很遠，用同一個中心點與半徑蓋不到。
	_emit_clumps(SceneryPlan.CLUMPS.get(StringName("%s_hall" % _key), {}), "TurfClumpsHall")


func _emit_clumps(spec: Dictionary, node_name: String) -> void:
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
	_attach_mesh(node_name, tool.commit(), &"turf_dark", CLUMP_LIFT, false)


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
	node_name: String, mesh: Mesh, material_id: StringName,
	transforms: Array[Transform3D], colors: Array[Color] = []
) -> void:
	if transforms.is_empty():
		return
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	# use_colors 一定要在 instance_count 之前設，之後設會清掉已經寫進去的資料。
	multi.use_colors = not colors.is_empty()
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for index in transforms.size():
		multi.set_instance_transform(index, transforms[index])
		if not colors.is_empty():
			multi.set_instance_color(index, colors[index])
	var material := Palette.surface(material_id)
	if not colors.is_empty():
		# 逐實例的顏色要靠 vertex_color_use_as_albedo 才會生效。
		# duplicate 一份：Palette 那一份是共用的，直接改會影響別人。
		material = material.duplicate()
		material.vertex_color_use_as_albedo = true
	_check_clearance(node_name, transforms)
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multi
	instance.material_override = material
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


# --- 谷地 -------------------------------------------------------------------


## 谷壁、頂上的草、遠山、垂藤、斷崖與岩拱。
##
## 每一種都是一個 MultiMesh，一個 draw call。**同一種東西超過 8 份就一定要用
## MultiMesh**——docs/PLAYTEST.md 要測試者在一台機器上開三個 client。
func _build_valley() -> void:
	var spec: Dictionary = SceneryPlan.CLIFFS.get(_key, {})
	if spec.is_empty():
		return
	# 谷地裡面**再分一次區**。理由跟外面那五區一樣：加一段崖壁不應該讓遠山、
	# 垂藤、斷崖、岩拱全部重洗，否則截圖 diff 每次都是「整個谷地都變了」。
	_build_cliffs(spec)
	_region(5)
	_build_range(spec)
	_region(6)
	_build_vines(spec)
	_region(7)
	_build_ravine()
	_region(8)
	_build_arches()


## 前排柱體 ＋ 頂上壓的那層草。兩者一起長，草才會剛好蓋在每一根的頂端。
##
## 走向由 `CLIFFS.runs` 決定：每一段是 `{"axis": "z"|"x", "from", "to", "inner", "sides"}`。
## 第一版寫死了「沿 z 走、往 ±x 長」，也就是**只做得出南北向的走廊**；
## 前廳是東西向的，需要沿 x 走、往 ±z 長。沒有 `runs` 就用舊的
## `z_from/z_to/inner_x` 組一段，所以既有的關卡與營地一個字都不用改。
func _build_cliffs(spec: Dictionary) -> void:
	var faces: Array[Transform3D] = []
	var caps: Array[Transform3D] = []
	var colors: Array[Color] = []
	var runs: Array = spec.get("runs", [])
	if runs.is_empty():
		runs = [{
			"axis": "z", "from": spec["z_from"], "to": spec["z_to"],
			"inner": spec["inner_x"], "sides": [-1.0, 1.0],
		}]
	for entry in runs:
		_emit_cliff_run(spec, entry, faces, caps, colors)
	_attach_multimesh("CliffFace", BoxMesh.new(), &"cliff_face", faces, colors)
	_attach_multimesh("CliffCap", BoxMesh.new(), &"cliff_cap", caps)


## 遠山。往霧色混過去，讀出來就是空氣透視。
##
## 本來是**沿著 ±x 的兩條帶子**，理由是第一章那時候是一條南北向的走廊，只有
## 東西兩側看得到天。前廳把關卡折成 L 之後這個假設就破了：站在轉角往北看是
## 一條空的地平線，而東西兩條帶子離新的東牆只剩十一公尺——不是遠山，是
## **貼在圍牆外面的兩排白色大板子**。
##
## 現在改成繞著關卡中心的一圈。距離用半徑控制，所以不管關卡往哪個方向長，
## 「遠山永遠在遠處而且每個方向都有」這件事都還成立。
func _build_range(spec: Dictionary) -> void:
	var transforms: Array[Transform3D] = []
	var height_range: Vector2 = spec["range_height"]
	var width_range: Vector2 = spec["range_width"]
	var radius: Vector2 = spec["range_radius"]
	var center: Vector3 = spec["range_center"]
	var count := int(spec["range_count"])
	for index in count:
		# 均分再抖動：純亂數會擠成幾團、留下幾個空的方位角。
		var angle := TAU * float(index) / float(count) + _rng.randf_range(-0.4, 0.4)
		var away := _rng.randf_range(radius.x, radius.y)
		var height := _rng.randf_range(height_range.x, height_range.y)
		var origin := center + Vector3(sin(angle), 0.0, cos(angle)) * away
		origin.y = float(spec["base_y"]) + height * 0.5
		var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU))
		transforms.append(Transform3D(
			basis.scaled(Vector3(
				_rng.randf_range(width_range.x, width_range.y),
				height,
				_rng.randf_range(width_range.x, width_range.y)
			)),
			origin
		))
	_attach_multimesh("DistantRange", BoxMesh.new(), &"cliff_lit", transforms)


## 從崖頂垂下來的藤蔓。三段疊起來、每段折一點，才不會是一根直棍。
## 用暗的 VINE，**不是**可破壞那面牆的飽和綠——亮綠色是「可以打」的教學，
## 拿去當裝飾會把那個訊號稀釋掉。
func _build_vines(spec: Dictionary) -> void:
	var transforms: Array[Transform3D] = []
	var length_range: Vector2 = spec["vine_length"]
	for _index in int(spec["vine_count"]):
		var side := -1.0 if _rng.randf() < 0.5 else 1.0
		var top := Vector3(
			side * (float(spec["inner_x"]) + 0.2),
			_rng.randf_range(5.0, 11.0),
			_rng.randf_range(float(spec["z_from"]), float(spec["z_to"]))
		)
		var swing := 0.0
		for segment in 3:
			var length := _rng.randf_range(length_range.x, length_range.y) / 3.0
			swing += deg_to_rad(_rng.randf_range(-8.0, 8.0))
			var basis := Basis(Vector3.BACK, swing)
			var origin := top - Vector3(0.0, length * 0.5, 0.0)
			transforms.append(Transform3D(basis.scaled(Vector3(0.16, length, 0.16)), origin))
			top.y -= length
	_attach_multimesh("HangingVines", BoxMesh.new(), &"vine", transforms)


## 斷崖：兩側崖壁、底、以及底下那層腐化的霧氣。
func _build_ravine() -> void:
	var spec: Dictionary = SceneryPlan.RAVINE.get(_key, {})
	if spec.is_empty():
		return
	var z_min := float(spec["z_min"])
	var z_max := float(spec["z_max"])
	var half_x := float(spec["half_x"])
	var depth := float(spec["depth"])
	var slabs := int(spec["slabs"])

	var walls: Array[Transform3D] = []
	var shades: Array[Color] = []
	# 每一片崖壁切成三段，越深越暗。
	#
	# 不切的話整片會是同一個中間調——而環境光是均勻的、不會因為「在洞裡」就變弱，
	# 所以裂縫讀起來像一道站在地上的矮牆，不像一個洞。深度的暗是這裡唯一的線索。
	var bands := 3
	for z: float in ([z_min, z_max] as Array[float]):
		for index in slabs:
			var width := half_x * 2.0 / float(slabs)
			var x := -half_x + width * (float(index) + 0.5)
			var thickness := _rng.randf_range(0.5, 1.1)
			# 崖壁往內縮一點，從上面看得到岩層錯落而不是一刀切。
			var inset := (1.0 if is_equal_approx(z, z_min) else -1.0) * thickness * 0.5
			for band in bands:
				var height := depth / float(bands)
				var top := -height * float(band)
				walls.append(Transform3D(
					Basis().scaled(Vector3(width * 0.98, height, thickness)),
					Vector3(x, top - height * 0.5, z + inset)
				))
				var sink := -0.55 - 0.15 * float(band)
				shades.append(Palette.jitter(
					Palette.color(&"cliff_face"), sink + _rng.randf_range(-0.05, 0.05)
				))
	_attach_multimesh("RavineWalls", BoxMesh.new(), &"cliff_face", walls, shades)

	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(half_x * 2.0 + 2.0, 1.0, z_max - z_min + 1.0)
	var floor_instance := MeshInstance3D.new()
	floor_instance.name = "RavineFloor"
	floor_instance.mesh = floor_mesh
	floor_instance.material_override = Palette.surface(&"cliff_deep")
	floor_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(floor_instance)
	floor_instance.position = Vector3(0.0, -depth - 0.5, (z_min + z_max) * 0.5)

	# 底下那層腐化的霧氣。docs/02 說土地正在腐化，而這道裂縫是全關唯一
	# 看得到「地底下有什麼」的地方——順手把故事放進去，也讓深度讀得出來。
	var mist_mesh := BoxMesh.new()
	mist_mesh.size = Vector3(half_x * 2.0, 0.05, z_max - z_min)
	var mist_material := Palette.surface(&"corrupt_glow").duplicate()
	mist_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mist_material.albedo_color.a = 0.16
	mist_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var mist := MeshInstance3D.new()
	mist.name = "RavineMist"
	mist.mesh = mist_mesh
	mist.material_override = mist_material
	mist.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mist)
	mist.position = Vector3(0.0, -depth * 0.72, (z_min + z_max) * 0.5)


## 橫跨走廊的岩拱。下緣 10 公尺以上，碰不到（三層疊高最多摸到 9.2 公尺）。
func _build_arches() -> void:
	var arches: Array = SceneryPlan.ARCHES.get(_key, [])
	if arches.is_empty():
		return
	var transforms: Array[Transform3D] = []
	var span := 13.0
	var rise := 2.8
	for entry in arches:
		var z := float(entry)
		for index in 5:
			var ratio := (float(index) + 0.5) / 5.0
			var x := lerpf(-span * 0.5, span * 0.5, ratio)
			var lift := sin(PI * ratio) * rise
			# 沿著拱的切線轉，石塊才是順著拱走的而不是一排平擺的方塊。
			var slope := rise * PI * cos(PI * ratio) / span
			var basis := Basis(Vector3.BACK, atan(slope))
			transforms.append(Transform3D(
				basis.scaled(Vector3(span / 4.2, 1.3, _rng.randf_range(2.2, 3.0))),
				Vector3(x, SceneryPlan.ARCH_CLEARANCE + 0.7 + lift, z + _rng.randf_range(-0.4, 0.4))
			))
	_attach_multimesh("Arches", BoxMesh.new(), &"cliff_face", transforms)


# --- 營地 -------------------------------------------------------------------


func _build_camp() -> void:
	_build_palisade()
	_build_fire_ring()
	_build_clutter()


## 柵欄柱、橫桿與大門。
func _build_palisade() -> void:
	var spec: Dictionary = SceneryPlan.PALISADE.get(_key, {})
	if spec.is_empty():
		return
	var half := float(spec["half"])
	var spacing := float(spec["spacing"])
	var post: Vector2 = spec["post"]
	var height_range: Vector2 = spec["height"]
	var lean := float(spec["lean_deg"])
	var yaw := float(spec["yaw_deg"])
	var gate_z := float(spec["gate_z"])
	var gate_half := float(spec["gate_half"])

	var posts: Array[Transform3D] = []
	var count := int(half * 2.0 / spacing)
	for axis in 2:
		for side: float in ([-1.0, 1.0] as Array[float]):
			for index in count:
				var along := -half + spacing * (float(index) + 0.5)
				var spot := Vector3(along, 0.0, side * half)
				if axis == 1:
					spot = Vector3(side * half, 0.0, along)
				# 大門的缺口：只有北面（z 是負的那一側）挖。
				if absf(spot.z - gate_z) < 0.6 and absf(spot.x) < gate_half:
					continue
				var tall := _rng.randf_range(height_range.x, height_range.y)
				var basis := Basis(Vector3.UP, deg_to_rad(_rng.randf_range(-yaw, yaw)))
				basis = basis.rotated(Vector3.BACK, deg_to_rad(_rng.randf_range(-lean, lean)))
				basis = basis.rotated(Vector3.RIGHT, deg_to_rad(_rng.randf_range(-lean, lean)))
				var thick := _rng.randf_range(post.x, post.y)
				posts.append(Transform3D(
					basis.scaled(Vector3(thick, tall, thick)),
					Vector3(spot.x, tall * 0.5 - 0.1, spot.z)
				))
	_attach_multimesh("PalisadePosts", BoxMesh.new(), &"wood", posts)

	# 橫桿：每一面兩條，把一排柱子綁成一道柵欄而不是一排棍子。
	var rails: Array[Transform3D] = []
	for entry in spec["rail_y"]:
		var y := float(entry)
		for axis in 2:
			for side: float in ([-1.0, 1.0] as Array[float]):
				var size := Vector3(half * 2.0, 0.14, 0.14)
				var origin := Vector3(0.0, y, side * half)
				if axis == 1:
					size = Vector3(0.14, 0.14, half * 2.0)
					origin = Vector3(side * half, y, 0.0)
				rails.append(Transform3D(Basis().scaled(size), origin))
	_attach_multimesh("PalisadeRails", BoxMesh.new(), &"wood", rails)

	# 大門：兩根高柱 ＋ 一根門楣 ＋ 三色垂幡（三個角色的顏色，也就是三族）。
	var gate: Array[Transform3D] = []
	var gate_height := float(spec["gate_height"])
	for side: float in ([-1.0, 1.0] as Array[float]):
		gate.append(Transform3D(
			Basis().scaled(Vector3(0.42, gate_height, 0.42)),
			Vector3(side * gate_half, gate_height * 0.5 - 0.1, gate_z)
		))
	gate.append(Transform3D(
		Basis().scaled(Vector3(gate_half * 2.0 + 0.9, 0.5, 0.5)),
		Vector3(0.0, gate_height, gate_z)
	))
	_attach_multimesh("Gate", BoxMesh.new(), &"wood", gate)

	var banners: Array[Transform3D] = []
	var banner_colors: Array[Color] = []
	var slot_colors: Array[Color] = [
		Color(0.90, 0.42, 0.32), Color(0.36, 0.76, 0.48), Color(0.38, 0.58, 0.95)
	]
	for index in 3:
		var x := lerpf(-gate_half + 0.7, gate_half - 0.7, float(index) / 2.0)
		var drop := _rng.randf_range(1.1, 1.7)
		banners.append(Transform3D(
			Basis().scaled(Vector3(0.5, drop, 0.06)),
			Vector3(x, gate_height - 0.25 - drop * 0.5, gate_z)
		))
		banner_colors.append(slot_colors[index])
	_attach_multimesh("GateBanners", BoxMesh.new(), &"wood_light", banners, banner_colors)


## 火塘的石圈與柴。火焰本身（粒子與閃爍）在 campfire.gd。
func _build_fire_ring() -> void:
	var spec: Dictionary = SceneryPlan.FIRE_RING.get(_key, {})
	if spec.is_empty():
		return
	var stones: Array[Transform3D] = []
	var count := int(spec["stones"])
	var radius := float(spec["radius"])
	for index in count:
		var angle := TAU * float(index) / float(count) + _rng.randf_range(-0.1, 0.1)
		var size := Vector3(
			_rng.randf_range(0.30, 0.46), _rng.randf_range(0.24, 0.38), _rng.randf_range(0.26, 0.40)
		)
		var basis := Basis(Vector3.UP, angle + _rng.randf_range(-0.3, 0.3))
		stones.append(Transform3D(
			basis.scaled(size),
			Vector3(cos(angle) * radius, size.y * 0.42, sin(angle) * radius)
		))
	_attach_multimesh("FireRing", BoxMesh.new(), &"stone", stones)

	var logs: Array[Transform3D] = []
	var log_count := int(spec["logs"])
	var length := float(spec["log_length"])
	for index in log_count:
		var angle := TAU * float(index) / float(log_count) + 0.4
		# 交叉斜靠成一個圓錐，這是「有人堆過」的形狀，不是四根平躺的棍子。
		var basis := Basis(Vector3.UP, angle).rotated(Vector3.BACK, deg_to_rad(48.0))
		logs.append(Transform3D(
			basis.scaled(Vector3(0.19, length, 0.19)),
			Vector3(cos(angle) * 0.30, 0.26, sin(angle) * 0.30)
		))
	_attach_multimesh("FireLogs", BoxMesh.new(), &"wood", logs)


## 柴堆、木桶、矮樹樁、草叢。
func _build_clutter() -> void:
	var spec: Dictionary = SceneryPlan.CLUTTER.get(_key, {})
	if spec.is_empty():
		return
	var wood: Array[Transform3D] = []
	for entry in spec["woodpile"]:
		var base: Vector3 = entry
		var spin := _rng.randf_range(0.0, TAU)
		for row in 3:
			for index in 3 - row:
				var offset := 0.34 * (float(index) - float(2 - row) * 0.5)
				var basis := Basis(Vector3.UP, spin).rotated(Vector3.BACK, PI * 0.5)
				wood.append(Transform3D(
					basis.scaled(Vector3(0.15, 1.7, 0.15)),
					base + Basis(Vector3.UP, spin) * Vector3(offset, 0.16 + 0.3 * float(row), 0.0)
				))
	for entry in spec["barrels"]:
		var spot: Vector3 = entry
		var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU))
		wood.append(Transform3D(basis.scaled(Vector3(0.62, 0.9, 0.62)), spot + Vector3.UP * 0.45))
	_attach_multimesh("CampWood", BoxMesh.new(), &"wood", wood)

	var stumps: Array[Transform3D] = []
	for entry in spec["stumps"]:
		var spot: Vector3 = entry
		var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU))
		stumps.append(Transform3D(basis.scaled(Vector3(0.66, 0.46, 0.66)), spot + Vector3.UP * 0.22))
	_attach_multimesh("CampStumps", BoxMesh.new(), &"wood_light", stumps)

	var tufts: Array[Transform3D] = []
	var half: Vector2 = spec["tuft_half"]
	for _index in int(spec["tufts"]):
		var spot := Vector3(
			_rng.randf_range(-half.x, half.x), 0.0, _rng.randf_range(-half.y, half.y)
		)
		if _near_path(spot):
			continue
		for blade in 3:
			var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU))
			basis = basis.rotated(Vector3.BACK, deg_to_rad(_rng.randf_range(-18.0, 18.0)))
			var tall := _rng.randf_range(0.28, 0.5)
			tufts.append(Transform3D(
				basis.scaled(Vector3(0.07, tall, 0.07)),
				spot + Vector3(
					_rng.randf_range(-0.18, 0.18), tall * 0.4, _rng.randf_range(-0.18, 0.18)
				)
			))
	_attach_multimesh("GrassTufts", BoxMesh.new(), &"cliff_cap", tufts)


## 裝飾禁區：**玩家走得到的地方，從 0.35 公尺到岩拱下緣之間，不准有任何裝飾。**
##
## 這條線是「裝飾不能傷到可讀性與玩法」寫成的檢查，不是寫成好意。走得到的地方
## 多一根沒有碰撞的柱子，玩家就會直接穿過去——那比沒有裝飾更糟。
##
## 下限 0.35 讓半埋的邊石過關（露出的部分不到 0.17）；上限是岩拱的下緣，
## 三層疊高最多摸到 9.2 公尺，碰不到。
func _check_clearance(node_name: String, transforms: Array[Transform3D]) -> void:
	var zones: Array = SceneryPlan.KEEP_CLEAR.get(_key, [])
	if zones.is_empty():
		return
	for item in transforms:
		var basis := item.basis
		var half: float = absf(basis.get_scale().y) * 0.5
		var top: float = item.origin.y + half
		var bottom: float = item.origin.y - half
		if top <= CLEARANCE_FLOOR or bottom >= CLEARANCE_CEILING:
			continue

		# **只量玩家走得進去的那一段。**
		#
		# 量整個盒子的話，一根 16 公尺高、頂端往內傾的柱子會被算成往走道伸進
		# 兩公尺——可是那兩公尺全在玩家搆得到的高度以上，是**刻意做的懸崖突出**，
		# 不是擋路的石頭。所以先把盒子沿自己的 y 軸切出 0.35…6.5 公尺這一段，
		# 再量那一段的腳印。`v` 是切出來的那一段在盒子局部 y 上的比例位置。
		var low_v := clampf((maxf(bottom, CLEARANCE_FLOOR) - item.origin.y) / (half * 2.0), -0.5, 0.5)
		var high_v := clampf(
			(minf(top, CLEARANCE_CEILING) - item.origin.y) / (half * 2.0), -0.5, 0.5
		)
		var mid_v := (low_v + high_v) * 0.5
		var span_v := (high_v - low_v) * 0.5
		# 旋轉之後在世界軸上的半長：x/z 兩根基底整根算，y 那根只算切出來的比例。
		var centre := Vector2(
			item.origin.x + basis.y.x * mid_v, item.origin.z + basis.y.z * mid_v
		)
		var reach := Vector2(
			(absf(basis.x.x) + absf(basis.z.x)) * 0.5 + absf(basis.y.x) * span_v,
			(absf(basis.x.z) + absf(basis.z.z)) * 0.5 + absf(basis.y.z) * span_v
		)
		for entry in zones:
			var box: Dictionary = entry
			var low: Vector2 = box["min"]
			var high: Vector2 = box["max"]
			if centre.x + reach.x <= low.x or centre.x - reach.x >= high.x:
				continue
			if centre.y + reach.y <= low.y or centre.y - reach.y >= high.y:
				continue
			clearance_violations.append(
				"%s @ x %.1f±%.1f z %.1f±%.1f y=%.2f…%.2f 撞到 %s…%s" % [
					node_name, centre.x, reach.x, centre.y, reach.y, bottom, top, low, high
				]
			)
			break


## 一段谷壁。`along` 是走向、`out` 是往外長的方向，兩者都是單位向量，
## 所以同一段程式碼南北向與東西向都做得出來。
func _emit_cliff_run(
	spec: Dictionary, run: Dictionary,
	faces: Array[Transform3D], caps: Array[Transform3D], colors: Array[Color]
) -> void:
	var from := float(run["from"])
	var to := float(run["to"])
	var inner := float(run["inner"])
	var step := float(spec["step"])
	var count := int(ceil((to - from) / step))

	for item in run["sides"]:
		var side := float(item)
		# **兩排，後排錯開半格。**
		#
		# 一排柱體之間一定有縫：間距 2.2、寬度隨機 2.0–3.4、位置再抖 ±0.5、
		# 還帶 ±7° 的偏擺，所以最窄的那幾根之間會開到一公尺多。縫後面是天空，
		# 而地平線那條帶子的明度是 0.821——谷壁 0.466 的兩倍。結果不是「石頭
		# 之間有縫」，是**一面畫著等距白線的深藍色牆**，間距還剛好是 2.2 公尺，
		# 一看就是程式生成的。後排錯開半格把每一道縫堵掉，而輪廓仍然是碎的。
		for row in int(run.get("rows", ROW_COUNT)):
			var row_inner := inner + float(row) * ROW_SETBACK
			var row_shift := float(row) * step * 0.5
			_emit_cliff_row(
				spec, run, side, row_inner, row_shift, count, faces, caps, colors
			)
		_emit_cliff_backing(spec, run, side, inner, from, to, faces, colors)


## 柱體後面那一整片。
##
## 錯開半格的第二排堵得掉正面看過去的縫，**堵不掉斜著看過去的**：後排離前排
## 1.4 公尺，視線越斜、它在畫面上被推開得越多，於是縫又開了。斜看正是玩家
## 沿著走廊走的時候最常有的角度。
##
## 所以背後補一整片。頂端只到離地 5 公尺——比最矮的柱子還矮，所以輪廓仍然
## 是柱子的鋸齒，而視線高度那一段是實心的。**補得比柱子高就會變回一面平牆**，
## 那是這一整段程式碼在避免的東西。
func _emit_cliff_backing(
	spec: Dictionary, run: Dictionary, side: float, inner: float,
	from: float, to: float, faces: Array[Transform3D], colors: Array[Color]
) -> void:
	var vertical := String(run["axis"]) == "z"
	var along := Vector3.BACK if vertical else Vector3.RIGHT
	var out := Vector3.RIGHT if vertical else Vector3.BACK
	var center := float(run.get("center", 0.0))
	var base_y := float(spec["base_y"])
	var height := BACKING_TOP_Y - base_y
	var length := to - from + 2.0
	var offset := inner + BACKING_SETBACK
	var thick := BACKING_THICKNESS
	var flat := along * ((from + to) * 0.5) + out * (center + side * (offset + thick * 0.5))
	var size := (
		Vector3(thick, height, length) if vertical else Vector3(length, height, thick)
	)
	faces.append(Transform3D(
		Basis.IDENTITY.scaled(size), Vector3(flat.x, base_y + height * 0.5, flat.z)
	))
	# 比柱子暗一點：它是縫後面的東西，不該跟前排搶。
	colors.append(Palette.jitter(Palette.color(&"cliff_face"), -0.14))


## 一整排柱體。`_emit_cliff_run` 對每一邊各叫兩次（前排、錯開半格的後排）。
func _emit_cliff_row(
	spec: Dictionary, run: Dictionary, side: float,
	inner: float, shift: float, count: int,
	faces: Array[Transform3D], caps: Array[Transform3D], colors: Array[Color]
) -> void:
	var vertical := String(run["axis"]) == "z"
	var along := Vector3.BACK if vertical else Vector3.RIGHT
	var out := Vector3.RIGHT if vertical else Vector3.BACK
	var from := float(run["from"])
	var center := float(run.get("center", 0.0))
	var step := float(spec["step"])
	# 進深可以逐段覆寫。前廳的北牆與凹室之間只有一公尺半的岩石，
	# 用預設的 1.6–3.2 會直接長進凹室的地板裡。
	var depth_range: Vector2 = run.get("depth", spec["depth"])
	var width_range: Vector2 = spec["width"]
	var height_range: Vector2 = spec["height"]
	var base_y := float(spec["base_y"])
	var cap := float(spec["cap_thickness"])
	var yaw := float(spec["yaw_deg"])
	for index in count:
		var travel := from + shift + step * float(index) + _rng.randf_range(-ROW_JITTER, ROW_JITTER)
		var depth := _rng.randf_range(depth_range.x, depth_range.y)
		var width := _rng.randf_range(width_range.x, width_range.y)
		var height := _rng.randf_range(height_range.x, height_range.y)
		var basis := Basis(Vector3.UP, deg_to_rad(_rng.randf_range(-yaw, yaw)))
		# 頂端往內傾。垂直的牆是走廊，傾斜的牆是谷——整個效果的一半在這一行。
		var lean := deg_to_rad(float(spec["lean_deg"]) + _rng.randf_range(-2.0, 2.0))
		basis = basis.rotated(out.cross(Vector3.UP).normalized(), lean * side)
		var size := (
			Vector3(depth, height, width) if vertical else Vector3(width, height, depth)
		)
		var flat := along * travel + out * (center + side * (inner + depth * 0.5))
		var origin := Vector3(flat.x, base_y + height * 0.5, flat.z)
		faces.append(Transform3D(basis.scaled(size), origin))
		# 逐實例**只動明度不動色相**，動色相就會從一片崖壁變成一堆彩色方塊。
		colors.append(Palette.jitter(Palette.color(&"cliff_face"), _rng.randf_range(-0.08, 0.08)))
		var cap_size := (
			Vector3(depth * 1.04, cap, width * 1.04) if vertical
			else Vector3(width * 1.04, cap, depth * 1.04)
		)
		caps.append(Transform3D(
			basis.scaled(cap_size), Vector3(flat.x, base_y + height, flat.z)
		))
