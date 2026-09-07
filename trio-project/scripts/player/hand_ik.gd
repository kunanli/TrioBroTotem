class_name HandIk
extends SkeletonModifier3D

## 兩件事：讓武器不要跟著手臂亂甩，讓副手真的握住它。
##
## ## 為什麼武器會亂甩
##
## 武器是焊在手骨上的（`weapon_rack.gd` 的 `BoneAttachment3D`），所以手臂擺多少
## 它就甩多少——而**尖端離手掌 0.5 到 1.0 公尺**，手腕轉十度，尖端就走十幾公分。
## 量出來：走路時貓的弓尖端在一個循環裡掃過一公尺，而且幾乎全在前後方向。
##
## 這件事本來是用 `MotionClips.RUN_ARM_SWING` 壓的——一個全域倍率，壓的是**整支
## 生成片段的兩隻手臂**，而且它壓不動：0.85 之後尖端還是掃 101 公分。
##
## **但那個常數沒有因此被刪掉。** 本來是要刪的（它存在的唯一理由就是壓武器，
## 而這一層已經逐手逐幀在做同一件事），量了才知道兩者是相加的——把它放掉之後
## 即使 IK 開著，尖端行程還是從 24/23/31 掉到 35/33/48 公分。理由寫在
## `motion_clips.gd` 那兩個常數上面。
##
## ## 這一層怎麼做
##
## 把持械手的姿勢換算到**角色空間**做指數平滑，得到一個「安靜的」參考姿勢，
## 再往它插值。位置用 CCD 解（`limb_ik.gd`），**朝向直接寫到手骨上**。
##
## 朝向那一半才是重點，而且這是與 `foot_ik` 最大的差別：腳只要解位置就夠了
## （腳掌上沒有掛一公尺長的東西），手只解位置的話尖端行程幾乎不會動。
##
## **平滑一定要在角色空間做，不能在世界空間。** 世界空間裡「往前走」本身就是
## 一個持續的位移，會被當成要壓掉的東西——結果是武器被留在身後。角色空間跟著
## 身體走也跟著身體轉，所以急轉彎時武器不會慢半拍。
##
## ## 副手
##
## 量出來副手離武器 64–115 公分，而手臂只有 52–57 公分——**副手根本構不到武器**。
## 所以這不是 IK 問題，是姿勢問題：`MotionClips.IDLE` 要先把武器帶到身前、把副手
## 帶到附近，IK 才收得掉最後那幾公分。搆不到的時候這一層會**按比例淡出**，
## 不會硬把手臂拉直——拉直的手臂比沒接上更難看，而且那本身就是「姿勢沒調好」
## 的訊號（`hand_probe` 印的最大距離就是在看這件事）。
##
## 哪一把武器有副手握點寫在 `WeaponRack.OFF_GRIPS`，那是武器的幾何性質。
## 劍不在表上，所以豬維持單手。

## 持械手用兩根骨頭，副手用三根（多一根鎖骨）。
##
## 不對稱是故意的：持械手的修正量只有幾公分，動到鎖骨會變成聳肩；副手要橫過
## 身體去搆武器，少了鎖骨就差那十幾公分。CCD 由末端往根部掃，所以鎖骨本來就
## 做最少的功——它只補最後搆不到的那一點。
const HOLD_CHAIN := ["%sUpperArm", "%sLowerArm"]
const OFF_CHAIN := ["%sShoulder", "%sUpperArm", "%sLowerArm"]

## 平滑的時間常數（秒）。
##
## 指數平滑對頻率 f 的衰減是 1 / sqrt(1 + (2πfτ)²)，所以**同一個 τ 對走路壓得少、
## 對衝刺壓得多**——那正好是想要的：走路的擺手該留著，衝刺的亂甩才是問題。
## 走路循環約 1.04 秒（f ≈ 0.96 Hz），0.35 秒的時間常數在那裡大約壓掉七成。
const STEADY_TIME := 0.35

## 最多往「安靜的姿勢」走多少。1.0 是完全不動——那看起來是死的，不是穩。
const STEADY_SHARE := 0.8

## 淡入淡出的時間。攻擊開始的那一瞬間不能硬切，會「啪」一下。
const FADE_TIME := 0.09

## 持械手的 CCD 迭代輪數。跟腳一樣，修正量只有幾公分，兩輪就夠。
const PASSES := 2

## 副手的 CCD 迭代輪數。**要多得多**，而這是逐輪印殘差才知道的。
##
## 副手每一幀要被搬 50–85 公分——動畫把它擺在身側，而武器在另一邊。逐輪量到的
## 收斂速度分成兩種：
##
##   修正 50 公分以內   第 1 輪就掉到 3 公分，第 3 輪進到 0.02 公分
##   修正 85 公分       0.41 → 0.26 → 0.20 → 0.18 → 0.16 → 0.15 → 0.14 → 0.13
##
## 第二種是 CCD 的老問題：起始姿勢離目標太遠時每一輪只削掉 7%，加輪數幾乎是
## 白加。真正的解法有兩個，兩個都用上了——`LimbIk.solve()` 的 `reach_first`
## 先讓整條鏈朝向目標，以及**把姿勢調到手本來就在武器附近**（`MotionClips.IDLE`）。
## 八輪是給後面那些細修用的。
const OFF_PASSES := 8

## 副手放手的門檻，單位是臂長的比例。1.0（剛好搆到）之前吃滿，超過 1.15 完全
## 放開，中間線性淡出。**不留這一段的話，姿勢一沒帶到位就會看到一條直手臂。**
const RELEASE := 1.15

## 副手最後停在武器自己的座標上的哪一點。弓弦要靠它決定被拉開多少。
##
## 由這一層發佈而不是讓弦自己去讀骨頭：**從修改器堆疊外面讀到的是還原後的
## 動畫姿勢**，不含這一層解出來的結果（實測差了 4.8 公分）。
var draw_point := Vector3.ZERO


var _space: Node3D = null
var _hold: Dictionary = {}
var _off: Dictionary = {}
var _built := false
var _steadying := false
var _weight := 0.0
var _steady := Transform3D.IDENTITY
var _steady_seen := false
var _to_space := Transform3D.IDENTITY
var _from_space := Transform3D.IDENTITY

## 武器擺放的逆變換，把世界／骨架空間的點換回**武器自己的座標**（零件表用的
## 那一套）。弓弦要在那個座標系裡決定被拉開多少。
var _mount_inverse := Transform3D.IDENTITY

## `owner_space` 是角色空間的基準節點（`CharacterVisual` 本身），與
## `ProceduralPose` 用同一個。
func configure(owner_space: Node3D) -> void:
	_space = owner_space


## 現在該不該穩定持械手與接上副手。由 `CharacterVisual` 每幀餵。
func set_steadying(steadying: bool) -> void:
	_steadying = steadying


func _process_modification() -> void:
	var skeleton := get_skeleton()
	if skeleton == null or _space == null:
		return
	if not _built:
		_build(skeleton)
		if not _built:
			active = false  # 沒有武器或沒有手臂，這一層沒有意義
			return

	var delta := get_process_delta_time()
	_weight = lerpf(_weight, 1.0 if _steadying else 0.0, 1.0 - exp(-delta / FADE_TIME))
	if _weight < 0.01:
		# 下次啟用時要從當下的姿勢重新起算，不要用停用前的舊值——不然一恢復
		# 就會把手從攻擊結束的位置一路拖回來。
		_steady_seen = false
	else:
		_steady_hand(skeleton, delta)
		_grip_off_hand(skeleton)
	# **淡出的時候也要發佈副手在哪。**
	#
	# 這是踩過的：原本這一段寫在上面那個 `_weight < 0.01` 的提前 return 後面，
	# 所以整個攻擊期間 `draw_point` 停在攻擊前的舊值——而拉弓正是攻擊期間發生的。
	# 弓弦因此在該被拉開的那 0.3 秒完全不動，也就是這一輪本來要修掉的那件事。
	_publish_draw(skeleton)


## 持械手：往「安靜的姿勢」插值，位置用 CCD、朝向直接寫。
func _steady_hand(skeleton: Skeleton3D, delta: float) -> void:
	var hand := int(_hold["hand"])
	var in_space := _to_space * skeleton.get_bone_global_pose(hand)
	if not _steady_seen:
		_steady = in_space
		_steady_seen = true
	else:
		_steady = _steady.interpolate_with(in_space, 1.0 - exp(-delta / STEADY_TIME))

	var target := _from_space * in_space.interpolate_with(_steady, _weight * STEADY_SHARE)
	LimbIk.solve(skeleton, _hold["chain"], hand, target.origin, PASSES, float(_hold["span"]))
	# 朝向不必解，直接寫——手骨是鏈的末端，轉它不會影響前面幾根。
	# 位置用 CCD 解完之後的實際值，不是 target.origin：搆不到的時候硬寫位置會
	# 把手從手腕上扯下來。
	skeleton.set_bone_global_pose(
		hand, Transform3D(target.basis, skeleton.get_bone_global_pose(hand).origin)
	)


## 副手：搆得到就接上武器，搆不到就按比例放開。
func _grip_off_hand(skeleton: Skeleton3D) -> void:
	if _off.is_empty():
		return
	var hand := int(_off["hand"])
	# 讀持械手**這一幀最後**的姿勢，副手才會跟著穩定過的武器走，
	# 而不是跟著動畫裡那個還在甩的武器。
	var weapon := skeleton.get_bone_global_pose(int(_hold["hand"]))
	var grip: Vector3 = weapon * (_off["grip"] as Vector3)
	var span := float(_off["span"])
	var shoulder: Vector3 = skeleton.get_bone_global_pose((_off["chain"] as Array[int])[0]).origin
	var over := shoulder.distance_to(grip) / maxf(span, 0.001)
	var reach := clampf((RELEASE - over) / (RELEASE - 1.0), 0.0, 1.0)
	var weight := _weight * reach
	if weight > 0.01:
		var here: Vector3 = skeleton.get_bone_global_pose(hand).origin
		LimbIk.solve(
			skeleton, _off["chain"], hand, here.lerp(grip, weight), OFF_PASSES, span, true
		)



## 副手最後停在哪，換算到武器自己的座標。弓弦讀這個值。
##
## 每一幀都要更新，**包含這一層淡出的時候**：拉弓時 `HandIk` 是關的（攻擊的手臂
## 是刻意擺的），但弦還是得跟著手走。
func _publish_draw(skeleton: Skeleton3D) -> void:
	if _off.is_empty():
		return
	draw_point = _mount_inverse * (
		skeleton.get_bone_global_pose(int(_hold["hand"])).affine_inverse()
		* skeleton.get_bone_global_pose(int(_off["hand"])).origin
	)


## 建好就把 `_built` 立起來。**只有持械手、沒有副手也算建好**——豬的劍是單手的，
## 那不是失敗。真正的失敗是連武器或手臂都找不到，那時候整層關掉。
func _build(skeleton: Skeleton3D) -> void:
	_collect(skeleton)
	_built = not _hold.is_empty()


func _collect(skeleton: Skeleton3D) -> void:
	var weapons := WeaponRack.mounted(skeleton)
	if weapons.is_empty():
		return
	var weapon: Dictionary = weapons[0]
	var bone := int(weapon["bone"])
	if bone < 0:
		return
	var held := "Right" if skeleton.get_bone_name(bone).begins_with("Right") else "Left"
	var free := "Left" if held == "Right" else "Right"

	var chain := LimbIk.find_chain(skeleton, _named(HOLD_CHAIN, held))
	if chain.is_empty():
		return
	_hold = {
		"hand": bone,
		"chain": chain,
		"span": LimbIk.chain_length(skeleton, chain, bone),
	}

	# 骨架相對於角色節點的變換是**常數**（骨架是它的子孫，中間那幾層的
	# transform 載入之後就不再動）。所以算一次就好，而且不必碰 global_transform
	# ——那個東西要求節點已經在場景樹裡，而且會吃到命中擠壓寫的非等比縮放。
	_to_space = _relative_transform(skeleton)
	_from_space = _to_space.affine_inverse()

	var kind: StringName = weapon["kind"]
	if not WeaponRack.OFF_GRIPS.has(kind):
		return  # 單手武器，副手空著
	var off_chain := LimbIk.find_chain(skeleton, _named(OFF_CHAIN, free))
	var off_hand := skeleton.find_bone("%sHand" % free)
	if off_chain.is_empty() or off_hand < 0:
		return
	var mount: Transform3D = (weapon["root"] as Node3D).transform
	_mount_inverse = mount.affine_inverse()
	_off = {
		"hand": off_hand,
		"chain": off_chain,
		"span": LimbIk.chain_length(skeleton, off_chain, off_hand),
		"grip": mount * (WeaponRack.OFF_GRIPS[kind] as Vector3),
	}


static func _named(pattern: Array, side: String) -> Array:
	var out: Array = []
	for entry in pattern:
		out.append(String(entry) % side)
	return out


## 骨架相對於角色節點的變換，沿著父節點逐層相乘。
## 與 `BoneSpace._relative_basis()` 同一個理由：不用 global_transform。
func _relative_transform(skeleton: Skeleton3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var walker: Node3D = skeleton
	while walker != null and walker != _space:
		result = walker.transform * result
		walker = walker.get_parent() as Node3D
	if walker == null:
		push_warning("[HandIk] 骨架不在角色節點底下，平滑的座標系可能不對")
	return result
