extends Node3D

## 步態量尺：走路片段的真實步幅是多少，以及現在腳滑多少。
##
##     godot --headless --fixed-fps 120 --path trio-project res://scenes/tools/gait_probe.tscn
##
## **`--fixed-fps 120` 不能省**：修改器吃的 delta 是真實幀的，headless 一幀只有一兩
## 毫秒，鎖腳與起伏的淡入淡出會慢幾十倍。理由寫在 hand_probe.gd 的檔頭。
##
## **這支探針存在的理由**：全專案有三個各自為政的數字在猜同一件事——這支走路
## 片段「原本」對應多快的移動速度。`CharacterVisual.WALK_REFERENCE_SPEED`
## 猜 1.6、`PlayerCharacter.STRIDE_RATIO` 用身高 × 0.62 反推出另一個值、
## `SPEED_SCALE_RANGE` 的 1.8 上限又是第三個。**沒有人量過。**
##
## 量法不繞路：站立期的腳不該滑，所以「腳相對身體往後退多快」直接就等於
## 「身體該以多快前進」。不是從步幅反推，是從「不滑」這個條件量出來的。
##
## 兩段輸出：
##   [Gait]  片段本身的數字——踝關節的高度範圍、站立佔比、步幅、自然速度
##   [Slip]  成績單——以某個速度前進時，每一次落腳在地上拖了幾公分
##
## 第二段是成績。**加 `--ik=0` 可以把 `FootIk` 關掉**，同一支探針就能印出
## 「有鎖腳」與「沒鎖腳」兩組數字——兩個數字要能比，就得出自同一條程式路徑。
## **`--bob=0` 同理關掉 `GaitBob`**（身體起伏層）。
##
## 第三段是身體：每一個速度帶印髖的起伏與左右擺（公分），另外站 6 秒印頭與髖
## 動了多少——那是「待機像不像雕像」的數字。
##
## **一切都以「一次落腳」為單位量，不累加路徑長度。** 第一版是逐幀累加位移的
## 長度，那把腳的橫向擺動也算進去了，自然速度因此高估了大約四成。
## 一次落腳從踩下到抬起之間的**淨位移**才是「這一步滑了多遠」。
##
## **量片段那一段不等任何一幀**（動畫切手動回呼，用 `seek()` 直接取樣），
## 但**量腳滑那一段一定要等真的幀**。兩個原因：
##
## 1. `Skeleton3D.advance()` **不會跑修改器堆疊**（實測：手動模式下呼叫它，
##    修改器一次都沒跑）。而 `FootIk` 就是修改器，不跑就量不到它。
## 2. 引擎在堆疊跑完之後會把骨頭姿勢還原，所以**從外面讀 `get_bone_global_pose()`
##    讀到的是動畫的姿勢，不含任何修改器的結果**。取樣必須自己也當一個修改器
##    掛在最後面。這就是下面 `Sampler` 存在的理由。
##
## 身體位移與動畫時間仍然用固定步長自己推，所以數字還是可比的；
## 只有修改器吃到的 delta 是真實幀的。

## 量片段時在一個循環裡取幾個樣。走路片段是 25 幀（1.0417 秒 @ 24 fps），
## 取 120 個樣等於每幀取五次，站立期的起訖抓得夠準，成本又幾乎是零。
const CYCLE_SAMPLES := 120

## 量片段時的踏地門檻：踝關節落在「自己那一整圈的垂直行程」最低的這一段
## 之內就算踏地。
##
## **不能用身高的比例當門檻。** 三隻抬腳的高度差很多——第一版用身高比例，
## 貓的站立佔比量出來是 0.97，等於整圈都判成踏地。用**這條軌自己的高度範圍**
## 當基準就自動對每一隻都成立。0.28 是照結果挑的：正常走路的站立佔比應該
## 落在 0.5–0.7，輸出裡有這個數字，改了就看得出來。
const LIFT_RANGE := 0.28

## **腳滑不用踏地判定量。**
##
## 試過兩種踏地判定，兩種都不可靠：固定高度門檻在鎖腳開著時分不出站立與
## 擺盪（實測有兩組直接判成「一次落腳都沒有」——那不是零腳滑，那是量壞了）；
## 改成比較兩隻腳的高度則會在門檻上抖，一次落腳被切成好幾次，而「每次落腳的
## 淨位移」這個指標對切法極度敏感，切錯了數字就沒有意義。
##
## 所以改成一個**完全不需要分段**的量法：每一幀取兩隻腳之中**世界空間水平
## 速度比較慢的那一隻**——那就是正在承重的那一隻——把它的速度累加起來。
## 理想值是 0（踏在地上的腳不該動）；如果腳完全跟著身體走，累加起來就會
## 等於身體走的距離。所以「滑掉的距離 ÷ 身體走的距離」是一個 0% 到 100%
## 的分數，跨速度、跨角色都可以直接比。

## 量腳滑時每一段跑幾秒、用哪幾個速度。
##
## 速度是刻意挑的：1.2 是慢走、2.6 剛好是 `RUN_SPEED` 的門檻、4.2 是播放倍率
## 被 1.8 卡死的那一點、6.0 是 `PlayerCharacter.SPEED` 的全速。
## 後兩個是這一輪真正要修的區間。
const SLIP_SECONDS := 6.0
const SLIP_SPEEDS: Array[float] = [1.2, 2.6, 4.2, 6.0]

## 待機量幾秒。重心轉移每 4–7 秒換一次邊，要涵蓋至少一次。
const IDLE_SECONDS := 8.0

## 模擬步長。跟遊戲一樣 120 Hz（project.godot），而且是固定的。
const STEP := 1.0 / 120.0

## 開始累加之前先空推幾秒，讓混合與姿態層的阻尼收斂。
const WARMUP_SECONDS := 0.8

## 掛在修改器堆疊最後面，把當下的腳踝位置記下來。
##
## 非這樣不可：引擎跑完堆疊會還原骨頭姿勢，從外面讀不到 `FootIk` 的結果。
class Sampler:
	extends SkeletonModifier3D

	var bones: Array[int] = []
	var seen: Array[Vector3] = []

	func _process_modification() -> void:
		var skeleton := get_skeleton()
		if skeleton == null:
			return
		seen.clear()
		for bone in bones:
			seen.append(skeleton.get_bone_global_pose(bone).origin)


var _visuals: Array[CharacterVisual] = []

## 角色 id -> `_measure_clip()` 量到的那一組數字。第二段要用第一段的踏地門檻，
## 兩段用同一個標準，數字才對得起來。
var _stats: Dictionary = {}


func _ready() -> void:
	for id in CharacterRoster.SLOT_ORDER:
		var visual := CharacterVisual.new()
		visual.name = String(id)
		add_child(visual)
		if not visual.load_character(id):
			push_warning("[Gait] %s 載入失敗" % id)
			continue
		_visuals.append(visual)

	for visual in _visuals:
		_stats[visual.name] = _measure_clip(visual)
	var with_ik := _argument("--ik=") != "0"
	var with_bob := _argument("--bob=") != "0"
	print("\n鎖腳：%s　起伏：%s" % [("開" if with_ik else "**關**"), ("開" if with_bob else "**關**")])
	for visual in _visuals:
		await _measure_slip(visual, with_ik, with_bob)
	for visual in _visuals:
		await _measure_idle(visual, with_bob)
	get_tree().quit(0)


func _argument(prefix: String) -> String:
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	for arg in args:
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""


## 這支片段本身的數字。
##
## 用 `seek()` 逐點取樣而不是讓它自己播：`seek(t, true)` 會當場把姿勢寫進骨頭，
## 取樣點就精確落在要的時間上。這一段刻意只讀**動畫寫的姿勢**，不含
## ProceduralPose 疊的東西——步幅是片段的性質，不是姿態層的性質。
##
## 取兩個循環的樣，跨越循環頭尾的那一次落腳才會是完整的；只採計「頭尾都在
## 取樣範圍內」的落腳，半截的不算。
func _measure_clip(visual: CharacterVisual) -> Dictionary:
	var player := _animation_player(visual)
	var skeleton := _skeleton(visual)
	var clip := visual.clip_for(&"walk")
	if player == null or skeleton == null or clip == &"":
		push_warning("[Gait] %s 少了走路片段或骨架" % visual.name)
		return {}
	var ankles := _ankles(skeleton)
	if ankles.is_empty():
		push_warning("[Gait] %s 骨架上找不到腳踝" % visual.name)
		return {}

	var length := player.get_animation(clip).length
	var dt := length / CYCLE_SAMPLES
	player.play(clip)
	player.speed_scale = 0.0

	# 逐格記下兩隻腳踝**在角色節點空間**的位置。不是骨架空間——骨架掛在
	# Armature 底下、帶著匯入時的變換，而我們要的是「相對於角色腳底那個原點」。
	var track: Array[Array] = []
	var low := INF
	var high := -INF
	for index in CYCLE_SAMPLES * 2:
		player.seek(dt * index, true)
		var frame: Array[Vector3] = []
		for bone in ankles:
			var point := _local_of(visual, skeleton, bone)
			frame.append(point)
			low = minf(low, point.y)
			high = maxf(high, point.y)
		track.append(frame)
	player.stop()

	var back := -INF
	var front := INF
	for frame in track:
		for point in frame:
			back = maxf(back, (point as Vector3).z)
			front = minf(front, (point as Vector3).z)
	var leg := _leg_length(skeleton)
	print(
		(
			"        腳踝前後行程 %.3f m　腿長（髖→踝）%.3f m　"
			+ "行程／腿長 %.2f（1.4 左右就是解剖學上限）"
		)
		% [back - front, leg, (back - front) / maxf(leg, 0.001)]
	)

	# 逐次落腳：踩下的那一格到抬起的前一格，**淨**位移除以時間。
	# 這一組是診斷用的（站立佔比與步幅），自然速度不靠它算——理由見下。
	var lift := low + (high - low) * LIFT_RANGE
	var planted := 0
	var stride := 0.0
	var falls := 0
	for side in ankles.size():
		var start := -1
		for index in track.size():
			var down: bool = (track[index][side] as Vector3).y <= lift
			if down:
				planted += 1
				if start < 0:
					start = index
				continue
			if start > 0:  # start == 0 的那一次是半截的，不算
				stride += _flat(track[index - 1][side], track[start][side])
				falls += 1
			start = -1

	var duty := float(planted) / float(track.size() * ankles.size())
	var natural := _natural_speed(track, dt)
	print(
		(
			"[Gait] %-12s 循環 %.4fs  踝關節 %+.3f ~ %+.3f（0 是地面）  站立佔比 %.2f"
			+ "  步幅 %.3f m（%d 次落腳）  自然速度 %.3f m/s"
		)
		% [
			visual.name,
			length,
			low,
			high,
			duty,
			stride / maxf(float(falls), 1.0),
			falls,
			natural,
		]
	)
	return {"natural": natural, "low": low, "lift": lift}


## 這支片段「原本」對應多快的移動速度——**不用踏地門檻算**。
##
## 為什麼要換掉門檻：踏地判定太脆弱了。三隻的踝關節離地高度差很多（豬 −0.06、
## 蛙 +0.08、貓 +0.13——腳踝不是腳底，而且三隻沉浮不一），同一個門檻算出來的
## 站立佔比從 0.32 到 0.65 都有，自然速度因此差了 3.5 倍。但三隻的步幅其實
## 只差 0.19 到 0.21 公尺——差的不是步態，是判定。
##
## 換一個不需要門檻的量法：**任何一個瞬間，正在踏地的那隻腳相對身體往後退的
## 速度就等於身體該前進的速度**（不然它就在滑）。所以逐格取「兩隻腳之中往後
## 退得最快的那一個」，再取整個循環的中位數。擺盪中的腳是往前的，永遠不會被
## 選中；雙腳同時著地時兩隻都是同一個值。中位數而不是平均，是為了讓落地與
## 離地那幾格的過渡值不影響結果。
static func _natural_speed(track: Array[Array], dt: float) -> float:
	var speeds: Array[float] = []
	for index in track.size():
		var next: Array = track[(index + 1) % track.size()]
		var here: Array = track[index]
		var backward := -INF
		for side in here.size():
			# 角色面向 −Z，所以腳相對身體往 +Z 移動就是「往後退」。
			backward = maxf(backward, (next[side] as Vector3).z - (here[side] as Vector3).z)
		speeds.append(backward / dt)
	speeds.sort()
	var n := speeds.size()
	print(
		"        往後退的速度分佈：p25 %.3f  p50 %.3f  p75 %.3f  p90 %.3f m/s"
		% [speeds[n / 4], speeds[n / 2], speeds[n * 3 / 4], speeds[n * 9 / 10]]
	)
	return speeds[speeds.size() / 2]


## 現況的成績單：以固定速度前進時，每一次落腳在地上拖了幾公分。
##
## 走的是**真正的那條路**——`drive()`（含播放倍率與它的上限）、ProceduralPose、
## 之後還會有 IK 層。所以這個數字量的是玩家實際看到的東西，不是理論值。
func _measure_slip(visual: CharacterVisual, with_ik: bool, with_bob: bool) -> void:
	var skeleton := _skeleton(visual)
	var player := _animation_player(visual)
	if skeleton == null or player == null:
		return
	var ankles := _ankles(skeleton)
	var stats: Dictionary = _stats.get(visual.name, {})
	if ankles.is_empty() or stats.is_empty():
		return
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var ik := skeleton.get_node_or_null("FootIk") as FootIk
	if ik != null:
		ik.active = with_ik
	var bob := skeleton.get_node_or_null("GaitBob") as GaitBob
	if bob != null:
		bob.active = with_bob
	var sampler := Sampler.new()
	sampler.name = "GaitSampler"
	sampler.bones = ankles + _body(skeleton)
	skeleton.add_child(sampler)  # 掛最後面，才看得到所有修改器的結果

	var clip := visual.clip_for(&"walk")
	var length := player.get_animation(clip).length
	for speed in SLIP_SPEEDS:
		visual.position = Vector3.ZERO
		for _warm in int(WARMUP_SECONDS / STEP):
			await _advance(visual, player, speed)

		var previous: Array[Vector3] = []
		var slip := 0.0
		var cycles := 0.0
		var hips_lo := Vector3(INF, INF, INF)
		var hips_hi := -hips_lo
		var frames := int(SLIP_SECONDS / STEP)
		for _index in frames:
			await _advance(visual, player, speed)
			cycles += player.speed_scale * STEP / length
			if sampler.seen.size() < ankles.size() + 2:
				continue
			# 髖在角色空間的範圍：Y 是起伏、X 是左右重心。
			var hips: Vector3 = _local_point(visual, skeleton, sampler.seen[ankles.size()])
			hips_lo = Vector3(minf(hips_lo.x, hips.x), minf(hips_lo.y, hips.y), 0.0)
			hips_hi = Vector3(maxf(hips_hi.x, hips.x), maxf(hips_hi.y, hips.y), 0.0)
			var here: Array[Vector3] = []
			for side in ankles.size():
				here.append(skeleton.global_transform * (sampler.seen[side] as Vector3))
			if previous.size() == here.size():
				# 慢的那一隻在承重。它移動了多少，就是滑掉了多少。
				var slowest := INF
				for side in here.size():
					slowest = minf(slowest, _flat(here[side], previous[side]))
				slip += slowest
			previous = here

		var travelled := SLIP_SECONDS * speed
		print(
			(
				"[Slip] %-12s %.1f m/s → 承重腳滑掉 %4.1f%%　每步 %4.1f cm（倍率 %.2f）"
				+ "　髖起伏 %.1f cm　左右 %.1f cm"
			)
			% [
				visual.name,
				speed,
				slip / travelled * 100.0,
				slip / maxf(cycles * 2.0, 1.0) * 100.0,
				player.speed_scale,
				(hips_hi.y - hips_lo.y) * 100.0,
				(hips_hi.x - hips_lo.x) * 100.0,
			]
		)
	sampler.queue_free()


## 待機像不像雕像：站 8 秒，頭與髖在角色空間動了多少。
##
## 這是「看不看得見在呼吸」的數字。原本呼吸振幅 0.6–1.4 度，頭動不到半公分，
## 在遊戲鏡頭下等於零。
func _measure_idle(visual: CharacterVisual, with_bob: bool) -> void:
	var skeleton := _skeleton(visual)
	var player := _animation_player(visual)
	if skeleton == null or player == null:
		return
	var body := _body(skeleton)
	if body.size() < 2:
		return
	var bob := skeleton.get_node_or_null("GaitBob") as GaitBob
	if bob != null:
		bob.active = with_bob
	var sampler := Sampler.new()
	sampler.name = "IdleSampler"
	sampler.bones = body
	skeleton.add_child(sampler)
	visual.position = Vector3.ZERO
	for _warm in int(WARMUP_SECONDS / STEP):
		await _advance(visual, player, 0.0)
	var hips_lo := Vector3(INF, INF, INF)
	var hips_hi := -hips_lo
	var head_lo := Vector3(INF, INF, INF)
	var head_hi := -head_lo
	for _index in int(IDLE_SECONDS / STEP):
		await _advance(visual, player, 0.0)
		if sampler.seen.size() < 2:
			continue
		var hips := _local_point(visual, skeleton, sampler.seen[0])
		var head := _local_point(visual, skeleton, sampler.seen[1])
		hips_lo = Vector3(minf(hips_lo.x, hips.x), minf(hips_lo.y, hips.y), minf(hips_lo.z, hips.z))
		hips_hi = Vector3(maxf(hips_hi.x, hips.x), maxf(hips_hi.y, hips.y), maxf(hips_hi.z, hips.z))
		head_lo = Vector3(minf(head_lo.x, head.x), minf(head_lo.y, head.y), minf(head_lo.z, head.z))
		head_hi = Vector3(maxf(head_hi.x, head.x), maxf(head_hi.y, head.y), maxf(head_hi.z, head.z))
	sampler.queue_free()
	print(
		"[Idle] %-12s 站 %.0f 秒 → 頭動了 %.1f cm　髖左右 %.1f cm　髖上下 %.1f cm"
		% [
			visual.name,
			IDLE_SECONDS,
			(head_hi - head_lo).length() * 100.0,
			(hips_hi.x - hips_lo.x) * 100.0,
			(hips_hi.y - hips_lo.y) * 100.0,
		]
	)


## 取樣器記下的骨架空間的點 → 角色空間。
func _local_point(visual: CharacterVisual, skeleton: Skeleton3D, point: Vector3) -> Vector3:
	return visual.global_transform.affine_inverse() * (skeleton.global_transform * point)


## 髖與頭。
func _body(skeleton: Skeleton3D) -> Array[int]:
	var out: Array[int] = []
	for name in ["Hips", "Head"]:
		var index := skeleton.find_bone(name)
		if index >= 0:
			out.append(index)
	return out if out.size() == 2 else [] as Array[int]


## 前進一個固定步長，餵一次 drive()，推動畫，然後等真的一幀讓修改器跑。
##
## 順序不能反：`drive()` 會挑片段、設播放倍率，`player.advance()` 把姿勢寫進
## 骨頭，最後那一幀才輪到修改器堆疊。這正是遊戲裡每一幀發生的順序。
## 位移與動畫時間是固定步長，只有修改器吃到的 delta 是真實幀的。
func _advance(visual: CharacterVisual, player: AnimationPlayer, speed: float) -> void:
	visual.position += Vector3.FORWARD * speed * STEP
	visual.drive(speed)
	player.advance(STEP)
	await get_tree().process_frame


## 兩點的水平距離。垂直不算——腳抬起來不是「滑」。
static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _world_of(skeleton: Skeleton3D, bone: int) -> Vector3:
	return skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin


## 骨頭在**角色節點**空間的位置。原點在角色腳底（`player_character.gd` 把
## `Character` 的 y 設成 −身高/2），所以 y 就是「離地多高」。
func _local_of(visual: CharacterVisual, skeleton: Skeleton3D, bone: int) -> Vector3:
	return visual.global_transform.affine_inverse() * _world_of(skeleton, bone)


## 髖到踝的靜置長度。**這是步幅的天花板**：腳往前伸多遠、往後蹬多遠，
## 都被這一段限制住。想把跑步的步幅拉大之前先看這個數字。
static func _leg_length(skeleton: Skeleton3D) -> float:
	var chain := ["LeftUpperLeg", "LeftLowerLeg", "LeftFoot"]
	var total := 0.0
	for index in chain.size() - 1:
		var a := skeleton.find_bone(chain[index])
		var b := skeleton.find_bone(chain[index + 1])
		if a < 0 or b < 0:
			return 0.0
		total += (
			skeleton.get_bone_global_rest(b).origin
			- skeleton.get_bone_global_rest(a).origin
		).length()
	return total


func _ankles(skeleton: Skeleton3D) -> Array[int]:
	var out: Array[int] = []
	for name in ["LeftFoot", "RightFoot"]:
		var index := skeleton.find_bone(name)
		if index >= 0:
			out.append(index)
	return out if out.size() == 2 else [] as Array[int]


func _animation_player(visual: CharacterVisual) -> AnimationPlayer:
	return visual.find_child("AnimationPlayer", true, false) as AnimationPlayer


func _skeleton(visual: CharacterVisual) -> Skeleton3D:
	var found := visual.find_children("*", "Skeleton3D", true, false)
	return found[0] as Skeleton3D if not found.is_empty() else null
