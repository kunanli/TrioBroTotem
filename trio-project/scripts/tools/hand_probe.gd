extends Node3D

## 手部量尺：武器現在甩多少，副手離武器多遠。
##
##     godot --headless --fixed-fps 120 --path trio-project res://scenes/tools/hand_probe.tscn
##     godot --headless --fixed-fps 120 --path trio-project \
##           res://scenes/tools/hand_probe.tscn --ik=0        # 關掉手部 IK 當對照組
##
## **一定要 `--fixed-fps 120`。** 探針自己用固定步長推位移與動畫，但修改器堆疊吃的
## `delta` 是真實幀的——headless 一幀可能只有一兩毫秒，所有淡入淡出（鎖腳、手部
## IK、起伏）都會用慢幾十倍的速度跑，量到的是假的。第一版 `[Strike]` 就是這樣
## 量到「腳滑 8 公分、手臂沒有回來」，其中一半是這個。鎖住之後每一幀的 delta
## 正好是 1/120 秒，跟 `STEP` 一致。
##
## 兩張成績單：
##
##   尖端行程   武器最遠端在**角色空間**一個取樣區間內走過的包圍盒對角線。
##              武器是焊在手骨上的，手臂擺多少它就甩多少；這個數字就是
##              「甩多少」。理想不是 0——完全不動的手臂看起來是死的。
##   副手距離   副手離「應該握住的那一點」多遠（`WeaponRack.OFF_GRIPS`）。
##              同時是可達性檢查：**最大值超過臂長就表示姿勢沒把手帶到位**，
##              那時候 IK 只會把手臂拉直，不會把手接上去。
##
## 第三張成績單 `[Strike]`：播一次 `attack1`，髖往前、往下壓了幾公分（攻擊有沒有
## 全身參與）、攻擊期間承重腳滑了幾公分（鎖腳在攻擊期間開著的代價）、以及手臂從
## 出招算起多久回到待機 2° 以內（回招有沒有滑）。`--bob=0` 關掉起伏層當對照組。
##
## 另外印兩個數字：武器離 `Head` 骨頭多近（**身高的幾成**），以及副手臂長。
##
## 離頭那個數字要印成比例而不是公分，是踩過才知道的。第一版印公分，法杖整支
## 埋進頭裡的那一格印出來是「36 公分」——看起來很安全，但這三隻是大頭身，
## 頭就佔了快一半的身高，36 公分還在頭裡面。
##
## **這一條是煙霧偵測器，不是判準。** 門檻 0.30 是拿看過的畫面回頭校準的：
## 0.43 與 0.41（法杖立在身側、弓推離身體）看起來對，0.26（法杖穿過頭）明顯錯。
## 中間那一段沒有人看過，所以低於 0.30 的意思是「去看 `shoot_anim` 的圖」，
## 不是「壞了」。穿不穿模這件事沒有便宜的數值判準——`Head` 只是一根骨頭，
## 而頭是一團網格。
##
## ## 一定要從修改器堆疊**裡面**取樣
##
## 引擎跑完堆疊會把骨頭姿勢還原，所以從外面讀 `get_bone_global_pose()` 讀到的
## 只有動畫寫的那一份——不含 `ProceduralPose`、不含 `FootIk`、更不含 `HandIk`。
## 這支探針的第一版就是這樣量的，量到的是「動畫本身甩多少」，跟畫面上看到的
## 不是同一件事。所以取樣自己也當一個修改器掛在最後面（`Sampler`），而且要跑
## **真的幀**——`Skeleton3D.advance()` 不會跑修改器堆疊（實測，0 次）。
##
## 武器的幾何一律從 `WeaponRack` 拿（`mounted()` / `tip()` / `OFF_GRIPS`），
## 這裡不抄第二份座標。抄了的話改零件表就會讓成績單靜靜地變得不可比。

## 每一段取樣幾秒。走路循環約 1.04 秒、衝刺約 0.2 秒，2 秒對每一支都涵蓋
## 至少兩個完整循環，包圍盒不會再長大。
const SAMPLE_SECONDS := 2.0

## 開始取樣前先空推幾秒，讓混合、姿態層的阻尼、以及 IK 的淡入都收斂。
const WARMUP_SECONDS := 1.0

## `--quick`：只量待機、時間砍短。
##
## 調姿勢的時候要一直重跑這支探針，而完整一輪要三分鐘——那個長度會讓人開始
## 用猜的代替量的。待機是**唯一一格姿勢完全靜止**的，所以短時間就夠準，
## 而且副手接不接得上，看待機最直接。**定案的數字一律用完整那一輪。**
## 武器離頭至少要有身高的這個比例。校準方式見檔頭——這是煙霧偵測器。
const HEAD_CLEAR := 0.30

## `[Strike]` 播完攻擊之後再看多久（回招要在這裡面回到待機）、以及「回到待機」
## 的角度門檻。
const STRIKE_WATCH := 1.2
const STRIKE_SETTLED := 3.0

const QUICK_SAMPLE := 0.3
const QUICK_WARMUP := 0.6

## 模擬步長。跟遊戲一樣 120 Hz（project.godot），而且是固定的。
const STEP := 1.0 / 120.0

## 用哪幾個速度去點名四個速度帶。
##
## 門檻是 `walk_speed × LOCOMOTION_BANDS.from`，三隻的 walk_speed 是 0.75–0.92，
## 所以 run 的門檻落在 1.28–1.55、sprint 落在 2.71–3.29。挑 1.0 / 2.4 / 5.0
## 三隻都會落在同一個帶上——**要是哪天改了門檻，這裡點到的帶就會跟標籤對不上**，
## 所以輸出裡也印實際播的片段名稱。
const BANDS := [
	{"label": "idle", "speed": 0.0},
	{"label": "walk", "speed": 1.0},
	{"label": "run", "speed": 2.4},
	{"label": "sprint", "speed": 5.0},
]

## 掛在修改器堆疊最後面，把當下的骨頭姿勢記下來。
##
## 非這樣不可，理由見檔頭。持械手要整個 Transform3D（武器的朝向是主導尖端
## 行程的東西，光有位置量不到），其餘只要位置。
class Sampler:
	extends SkeletonModifier3D

	var hand := -1
	var others: Array[int] = []
	var hand_pose := Transform3D.IDENTITY
	var seen: Array[Vector3] = []
	var captured := false

	func _process_modification() -> void:
		var skeleton := get_skeleton()
		if skeleton == null or hand < 0:
			return
		hand_pose = skeleton.get_bone_global_pose(hand)
		seen.clear()
		for bone in others:
			seen.append(skeleton.get_bone_global_pose(bone).origin)
		captured = true


var _quick := false
var _with_bob := true


func _ready() -> void:
	var with_ik := _argument("--ik=") != "0"
	_with_bob = _argument("--bob=") != "0"
	_quick = _has_flag("--quick")
	print(
		"\n手部 IK：%s%s"
		% [("開" if with_ik else "**關**"), ("　（--quick：只量待機）" if _quick else "")]
	)
	for id in CharacterRoster.SLOT_ORDER:
		var visual := CharacterVisual.new()
		visual.name = String(id)
		add_child(visual)
		if not visual.load_character(id):
			push_warning("[Hand] %s 載入失敗" % id)
			continue
		await _report(visual, with_ik)
	get_tree().quit(0)


func _has_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args() or flag in OS.get_cmdline_args()


func _argument(prefix: String) -> String:
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	for arg in args:
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""


func _report(visual: CharacterVisual, with_ik: bool) -> void:
	var skeleton := _skeleton(visual)
	var player := visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if skeleton == null or player == null:
		return
	var weapons := WeaponRack.mounted(skeleton)
	if weapons.is_empty():
		push_warning("[Hand] %s 身上沒有武器" % visual.name)
		return
	var weapon: Dictionary = weapons[0]
	var kind: StringName = weapon["kind"]
	var hand := int(weapon["bone"])
	var mount: Transform3D = (weapon["root"] as Node3D).transform
	var tip_local: Vector3 = mount * WeaponRack.tip(kind)
	var butt_local: Vector3 = mount.origin
	var has_off: bool = WeaponRack.OFF_GRIPS.has(kind)
	var off_local: Vector3 = (
		mount * (WeaponRack.OFF_GRIPS[kind] as Vector3) if has_off else Vector3.ZERO
	)

	var side := "Left" if skeleton.get_bone_name(hand).begins_with("Right") else "Right"
	var off_chain := LimbIk.find_chain(
		skeleton, ["%sShoulder" % side, "%sUpperArm" % side, "%sLowerArm" % side]
	)
	var off_hand := skeleton.find_bone("%sHand" % side)
	var head := skeleton.find_bone("Head")
	var arm := LimbIk.chain_length(skeleton, off_chain, off_hand)
	var shoulder := off_chain[0] if not off_chain.is_empty() else -1

	var ik := skeleton.get_node_or_null("HandIk") as SkeletonModifier3D
	if ik != null:
		ik.active = with_ik
	var bob := skeleton.get_node_or_null("GaitBob") as GaitBob
	if bob != null:
		bob.active = _with_bob
	var sampler := Sampler.new()
	sampler.name = "HandSampler"
	sampler.hand = hand
	sampler.others = [off_hand, head, shoulder]
	skeleton.add_child(sampler)  # 掛最後面，才看得到所有修改器的結果

	print(
		"\n=== %s（%s 掛在 %s）　副手臂長 %.3f m　副手握點 %s ==="
		% [
			visual.name,
			kind,
			skeleton.get_bone_name(hand),
			arm,
			("有" if has_off else "**這把是單手的**"),
		]
	)
	for entry in BANDS:
		var band: Dictionary = entry
		if _quick and String(band["label"]) != "idle":
			continue
		await _measure(visual, player, skeleton, sampler, band, {
			"tip": tip_local,
			"butt": butt_local,
			"off": off_local,
			"has_off": has_off,
			"arm": arm,
			"height": _skeleton_height(skeleton),
		})
	sampler.queue_free()
	if not _quick:
		await _measure_strike(visual, player, skeleton, hand)


## 一個速度帶的四個數字。全部換算到**角色空間**——角色本身在往前走，
## 在世界空間量的話「往前走了兩公尺」會被算進尖端行程裡。
func _measure(
	visual: CharacterVisual,
	player: AnimationPlayer,
	skeleton: Skeleton3D,
	sampler: Sampler,
	band: Dictionary,
	geometry: Dictionary
) -> void:
	var speed := float(band["speed"])
	visual.position = Vector3.ZERO
	for _warm in int((QUICK_WARMUP if _quick else WARMUP_SECONDS) / STEP):
		await _advance(visual, player, speed)

	var low := Vector3(INF, INF, INF)
	var high := -low
	var gap_min := INF
	var gap_max := -INF
	var over_max := 0.0
	var head_min := INF
	var arrow := skeleton.find_child("arrow", true, false) as MeshInstance3D
	var arrow_frames := 0
	var to_space := visual.global_transform.affine_inverse() * skeleton.global_transform
	for _index in int((QUICK_SAMPLE if _quick else SAMPLE_SECONDS) / STEP):
		await _advance(visual, player, speed)
		if not sampler.captured:
			continue
		if arrow != null and arrow.visible:
			arrow_frames += 1
		# 角色一直在往前走，所以每一幀的換算矩陣都要重取。
		to_space = visual.global_transform.affine_inverse() * skeleton.global_transform
		var hand_pose: Transform3D = sampler.hand_pose
		var tip: Vector3 = to_space * (hand_pose * (geometry["tip"] as Vector3))
		low = Vector3(minf(low.x, tip.x), minf(low.y, tip.y), minf(low.z, tip.z))
		high = Vector3(maxf(high.x, tip.x), maxf(high.y, tip.y), maxf(high.z, tip.z))
		if sampler.seen.size() < 3:
			continue
		if bool(geometry["has_off"]):
			var socket: Vector3 = hand_pose * (geometry["off"] as Vector3)
			var gap: float = (sampler.seen[0] as Vector3).distance_to(socket)
			gap_min = minf(gap_min, gap)
			gap_max = maxf(gap_max, gap)
			# 「搆不搆得到」看的是**肩膀**離握點多遠，不是手離握點多遠——手本來
			# 就可能在別的地方。超過 1.0 就是這一格的姿勢把武器放到臂長之外了，
			# IK 只能淡出。這個數字直接告訴我姿勢還差多少，不必用猜的。
			over_max = maxf(
				over_max,
				(sampler.seen[2] as Vector3).distance_to(socket) / maxf(float(geometry["arm"]), 0.001)
			)
		head_min = minf(
			head_min,
			_segment_gap(
				sampler.seen[1],
				hand_pose * (geometry["butt"] as Vector3),
				hand_pose * (geometry["tip"] as Vector3)
			)
		)

	var swing := high - low
	var reach := (
		""
		if not bool(geometry["has_off"])
		else (
			"　副手離握點 %4.1f ~ %4.1f cm（肩到握點 %.2f 倍臂長%s）"
			% [
				gap_min * 100.0,
				gap_max * 100.0,
				over_max,
				("" if over_max <= 1.0 else "，**搆不到**"),
			]
		)
	)
	print(
		"  %-6s %-14s 尖端行程 %5.1f cm（X %3.0f Y %3.0f Z %3.0f）%s　離頭 %.2f 個身高%s"
		% [
			band["label"],
			player.current_animation,
			swing.length() * 100.0,
			swing.x * 100.0,
			swing.y * 100.0,
			swing.z * 100.0,
			reach,
			head_min / maxf(float(geometry["height"]), 0.001),
			(
				""
				if head_min / maxf(float(geometry["height"]), 0.001) >= HEAD_CLEAR
				else "　← 太靠近頭了，去看 shoot_anim 的圖"
			),
		]
		+ (
			"　**箭出現 %d 幀（不該出現）**" % arrow_frames
			if arrow != null and arrow_frames > 0
			else ""
		)
	)


## 出招：髖壓了多少、腳滑了多少、手臂多久回來。
func _measure_strike(
	visual: CharacterVisual, player: AnimationPlayer, skeleton: Skeleton3D, hand: int
) -> void:
	var hips := skeleton.find_bone("Hips")
	var feet := LimbIk.find_chain(skeleton, ["LeftFoot", "RightFoot"])
	if hips < 0 or feet.is_empty():
		return
	var sampler := Sampler.new()
	sampler.name = "StrikeSampler"
	sampler.hand = hand
	sampler.others = [hips, feet[0], feet[1]]
	skeleton.add_child(sampler)
	# 呼吸與擺動關掉：「回到待機」要跟一個不動的基準比，而待機現在會呼吸
	# （2–3.6 度，比門檻還大），不關的話永遠量到「沒有回來」。
	var pose := skeleton.get_node_or_null("ProceduralPose") as ProceduralPose
	if pose != null:
		pose.breath_amplitude = 0.0
		pose.sway_amplitude = 0.0
	visual.position = Vector3.ZERO
	for _warm in int(WARMUP_SECONDS / STEP):
		await _advance(visual, player, 0.0)
	var rest_hips := _space_point(visual, skeleton, sampler.seen[0])
	var rest_feet: Array[Vector3] = [
		_space_point(visual, skeleton, sampler.seen[1]),
		_space_point(visual, skeleton, sampler.seen[2]),
	]
	var rest_axis := _weapon_axis(visual, skeleton, sampler.hand_pose)

	var arrow := skeleton.find_child("arrow", true, false) as MeshInstance3D
	var arrow_frames := 0
	visual.play_action(&"attack1")
	var clip_length := player.get_animation(player.current_animation).length
	var forward := 0.0
	var down := 0.0
	var back := 0.0
	var up := 0.0
	var slip := 0.0
	var settled := -1.0
	var t := 0.0
	while t < clip_length + STRIKE_WATCH:
		await _advance(visual, player, 0.0)
		t += STEP
		if arrow != null and arrow.visible:
			arrow_frames += 1
		var here := _space_point(visual, skeleton, sampler.seen[0])
		forward = maxf(forward, rest_hips.z - here.z)  # 面向 −Z，往前是 z 變小
		down = maxf(down, rest_hips.y - here.y)
		back = maxf(back, here.z - rest_hips.z)
		up = maxf(up, here.y - rest_hips.y)
		for side in 2:
			var foot := _space_point(visual, skeleton, sampler.seen[1 + side])
			slip = maxf(slip, Vector2(foot.x - rest_feet[side].x, foot.z - rest_feet[side].z).length())
		var apart := rad_to_deg(_weapon_axis(visual, skeleton, sampler.hand_pose).angle_to(rest_axis))
		if t > clip_length and apart <= STRIKE_SETTLED and settled < 0.0:
			settled = t
		elif apart > STRIKE_SETTLED:
			settled = -1.0
	sampler.queue_free()
	print(
		(
			"  [Strike] attack1 %.2fs → 髖前 %.1f 後 %.1f 上 %.1f 下 %.1f cm　腳滑 %.1f cm"
			+ "　手臂回到待機 %s　第二段 %s"
		)
		% [
			clip_length,
			forward * 100.0,
			back * 100.0,
			up * 100.0,
			down * 100.0,
			slip * 100.0,
			("%.2fs（從出招算起）" % settled) if settled >= 0.0 else "**沒有回來**",
			_mirror_report(player, visual),
		]
		+ ("　箭出現 %d 幀" % arrow_frames if arrow != null else "")
	)


## 第二段有沒有鏡像：比 attack2 片段裡左右上臂各轉了多少。鏡像的話跟第一段相比
## 左右會對調——這裡直接印兩邊的幅度，弓與杖該是持械那一側大。
func _mirror_report(player: AnimationPlayer, visual: CharacterVisual) -> String:
	var clip := visual.clip_for(&"attack2")
	if clip == &"" or not player.has_animation(clip):
		return "（沒有 attack2）"
	var anim := player.get_animation(clip)
	var swing := {"LeftUpperArm": 0.0, "RightUpperArm": 0.0}
	for track in anim.get_track_count():
		if anim.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			continue
		var bone := String(anim.track_get_path(track).get_subname(0))
		if not swing.has(bone):
			continue
		var first: Quaternion = anim.track_get_key_value(track, 0)
		for key in anim.track_get_key_count(track):
			var q: Quaternion = anim.track_get_key_value(track, key)
			swing[bone] = maxf(swing[bone], rad_to_deg(first.angle_to(q)))
	return "左臂 %.0f° 右臂 %.0f°" % [swing["LeftUpperArm"], swing["RightUpperArm"]]


## 武器指的方向（角色空間）。武器掛在手骨的 −Y 上（`weapon_rack.gd` 的 GRIP_SPIN）。
func _weapon_axis(visual: CharacterVisual, skeleton: Skeleton3D, hand: Transform3D) -> Vector3:
	var to_space := (visual.global_transform.affine_inverse() * skeleton.global_transform).basis
	return -(to_space * hand.basis.y)


## 取樣器記下的骨架空間的點 → 角色空間。
func _space_point(visual: CharacterVisual, skeleton: Skeleton3D, point: Vector3) -> Vector3:
	return visual.global_transform.affine_inverse() * (skeleton.global_transform * point)


## 前進一個固定步長，餵一次 drive()，推動畫，然後等真的一幀讓修改器跑。
## 順序與 `gait_probe._advance()` 一致，理由也一樣（見那邊）。
func _advance(visual: CharacterVisual, player: AnimationPlayer, speed: float) -> void:
	visual.position += Vector3.FORWARD * speed * STEP
	visual.drive(speed)
	player.advance(STEP)
	await get_tree().process_frame


## 點到線段的最短距離。武器是一條線段，不是一個點。
static func _segment_gap(point: Vector3, a: Vector3, b: Vector3) -> float:
	var span := b - a
	var len2 := span.length_squared()
	if len2 < 1e-9:
		return point.distance_to(a)
	return point.distance_to(a + span * clampf((point - a).dot(span) / len2, 0.0, 1.0))


## 骨架的靜置高度。離頭的距離要除以它才跨得了角色比較——三隻身高 1.4 到 1.7。
static func _skeleton_height(skeleton: Skeleton3D) -> float:
	var low := INF
	var high := -INF
	for index in skeleton.get_bone_count():
		var y := skeleton.get_bone_global_rest(index).origin.y
		low = minf(low, y)
		high = maxf(high, y)
	return maxf(high - low, 0.001)


func _skeleton(visual: CharacterVisual) -> Skeleton3D:
	var found := visual.find_children("*", "Skeleton3D", true, false)
	return found[0] as Skeleton3D if not found.is_empty() else null
