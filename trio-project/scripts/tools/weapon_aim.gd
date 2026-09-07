extends Node3D

## 反解武器的掛載角度：「我要劍指向那邊」→「名冊的 spin 該填多少」。
##
##     godot --headless --path trio-project res://scenes/tools/weapon_aim.tscn
##
## 把印出來的三行貼回 `character_roster.gd` 的 `weapons.spin`。
##
## **為什麼需要一支工具而不是用推的**：武器是焊在手骨上的，而手骨的朝向跟著
## 當下的姿勢跑。骨架靜置姿勢（雙手平舉的 T 字）下手骨的 +Y 是「往身體外側」，
## 垂手站著時卻幾乎是「朝下」——差了大約 75 度。照靜置姿勢推出來的角度，
## 站著看就是三把橫躺的武器（實際踩過）。
##
## 所以這裡是**在真正的待機姿勢下量**：載入角色、餵 60 幀的 `drive(0)` 讓
## `idle` 播起來、姿態層也疊完，再讀掛載點當下的世界朝向反解。
## 改了 `MotionClips.IDLE` 的手臂角度就要重跑一次——手臂動了，武器就歪了。

## 每一把武器該指的方向，寫在**角色空間**：角色面向 −Z、右手邊是 +X、上是 +Y。
##
## 三個都不是正上方，而是明顯往外扳開。理由是這三隻是大頭身：頭大約佔了
## 一半的身高，手卻在髖部旁邊——武器一垂直就整支埋進頭與軀幹的剪影裡，
## 畫面上只剩一小截。往外扳到 40–50 度才看得見整把。
##
## **法杖那一個是數像素定的。** 原本 (0.42, 0.90, −0.12) 立在身側，好看，但左肩到
## 握點 1.07 倍臂長，左手永遠搆不到。搆得到的方向試了五種，每一種都拍一張圖數
## 木頭色的像素（法杖看得見多少）：
##
##     (−0.72, 0.58, −0.38) 斜立身前      273 px   整支插在頭裡
##     (−0.55, 0.35, −0.76) 往前倒        438 px   縮成一個點
##     (−0.85, 0.25, −0.46) 橫抱胸前偏左  612 px   ← 這個
##     ( 0.42, 0.90, −0.12) 原本立身側    782 px   但副手搆不到（1.02）
##
## `hand_probe` 的「離頭」對抱在胸前的武器沒有意義（它量的是到 Head 骨頭的距離，
## 而胸前本來就離頭近），所以這裡只能看圖或數像素。改任何一個目標方向之後，
## 除了重跑這支，還要跑 `hand_probe` 看副手那個比例。
const TARGETS := {
	&"pig_warrior": Vector3(0.70, 0.68, 0.22),   # 劍扛在肩後，往上偏右偏後
	&"frog_mage": Vector3(-0.85, 0.25, -0.46),   # 法杖橫抱在胸前偏左（port arms），雙手分開握、整支看得見
	&"cat_archer": Vector3(-0.74, 0.64, -0.20),  # 弓直立、推離身體
}

## 要讓 idle 播起來並且讓 ProceduralPose 的阻尼收斂需要幾幀。
const SETTLE_FRAMES := 60


func _ready() -> void:
	var visuals: Array[CharacterVisual] = []
	for id in CharacterRoster.SLOT_ORDER:
		var visual := CharacterVisual.new()
		add_child(visual)
		visual.load_character(id)
		visual.name = String(id)
		visuals.append(visual)

	for _frame in SETTLE_FRAMES:
		for visual in visuals:
			visual.drive(0.0)
		await get_tree().process_frame

	for visual in visuals:
		for socket in visual.find_children("*Socket", "BoneAttachment3D", true, false):
			_solve(visual, socket as Node3D)
	get_tree().quit(0)


## 反解一把武器的 spin。
##
## 掛載的基準角度是 `WeaponRack.GRIP_SPIN`（繞 X 轉 180 度），名冊的 spin 疊在
## 它上面，所以總角度是 (180 + x, 0, z)。武器自己的 +Y 在骨頭座標下就是
##     (−sin z, −cos z · cos x, −cos z · sin x)
## 把目標方向換算到骨頭座標之後反解這三個式子就得到 x 與 z。
## 繞武器自身長軸的滾轉沒有被約束——劍與法杖左右對稱，弓的弦面則由這個解
## 順帶決定（實測是朝向身體那一側，剛好是對的）。
func _solve(visual: CharacterVisual, socket: Node3D) -> void:
	var target: Vector3 = (TARGETS[StringName(visual.name)] as Vector3).normalized()
	var local := socket.global_basis.orthonormalized().inverse() * target
	print(
		"%-12s %-6s spin = Vector3(%.0f, 0.0, %.0f)"
		% [
			visual.name,
			socket.get_child(0).name,
			rad_to_deg(atan2(-local.z, -local.y)),
			rad_to_deg(asin(clampf(-local.x, -1.0, 1.0))),
		]
	)
