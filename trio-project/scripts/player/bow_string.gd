class_name BowString
extends Node3D

## 拉弓的時候把弓弦拉開。
##
## 弦是兩段方塊（`WeaponRack.BOW` 的 `string_upper` / `string_lower`），這一層每幀
## 把它們的端點重新接到「上梢 → 搭箭點 → 下梢」，搭箭點跟著右手跑。
##
## ## 搭箭點的來源是右手實際的位置，不是另一條時間軸
##
## 大可以在攻擊片段旁邊再寫一條「弦被拉開多少」的曲線，但那就變成兩個時鐘：
## 調了 `CAT_SHOT` 的手臂角度而忘了調弦，弦就會在手還沒到位時先彈回去。
## 直接投影右手的位置的話，弦永遠貼著手——這與腳步聲跟動畫共用
## `CharacterVisual.step_length()` 是同一招。
##
## ## 為什麼不自己去讀骨頭
##
## **從修改器堆疊外面讀 `get_bone_global_pose()` 讀到的是還原後的動畫姿勢**，
## 不含 `ProceduralPose`、也不含 `HandIk` 解出來的結果（實測差 4.8 公分）。
## 所以右手的位置由 `HandIk.draw_point` 發佈——那是它在堆疊裡面算完的值，
## 而且已經換算到武器自己的座標，這裡直接用。
##
## `BoneAttachment3D` 倒是看得到堆疊的結果（實測驗過），所以這個節點掛在武器
## 底下就會跟著穩定過的弓走，不必自己補償。

## 弦拉不動的門檻（武器自己的座標）。小於這個距離就當作沒在拉——不然待機時
## 右手的一點點呼吸位移會讓弦一直抖。
const SLACK := 0.02

## 追上手的時間常數（秒）。弦是有張力的東西，不會瞬間跟上，但也不能拖。
const FOLLOW_TIME := 0.04

## 箭什麼時候出現、什麼時候算放手（拉開的距離，武器自己的座標）。
##
## 兩個門檻不一樣是遲滯：走路時 IK 把右手接在弦上、身體在晃，`pull` 會在 `SLACK`
## 附近抖，用同一個門檻箭會一閃一閃。拉到 6 公分才算在拉弓，掉回 2 公分以下才算
## 放手——放手那一幀箭消失、放一道箭痕。**放手是從弦的狀態判的，不另外接時間軸**：
## 弦本來就是跟著右手走的。
const ARROW_SHOW := 0.06
const ARROW_RELEASE := 0.02

var _upper: MeshInstance3D = null
var _lower: MeshInstance3D = null
var _hand: HandIk = null
var _nock := Vector3.ZERO
var _ready_parts := false
var _arrow: MeshInstance3D = null
var _arrow_head: MeshInstance3D = null
var _pull := 0.0
var _drawn := false


## 由 `CharacterVisual` 在 `HandIk` 建好之後接上。沒接上的話弦就是靜止的直線，
## 不會壞掉——`animation_lab` 之外的地方（例如探針）不見得有手部 IK。
func bind(hand: HandIk) -> void:
	_hand = hand


func _ready() -> void:
	var root := get_parent()
	if root == null:
		return
	_upper = root.get_node_or_null("string_upper") as MeshInstance3D
	_lower = root.get_node_or_null("string_lower") as MeshInstance3D
	_arrow = root.get_node_or_null("arrow") as MeshInstance3D
	_arrow_head = root.get_node_or_null("arrow_head") as MeshInstance3D
	_ready_parts = _upper != null and _lower != null
	if not _ready_parts:
		push_warning("[BowString] 找不到弦的兩段，弓弦不會被拉開")
	_nock = WeaponRack.BOW_NOCKS["rest"]


func _process(delta: float) -> void:
	if not _ready_parts:
		return
	_nock = _nock.lerp(_wanted(), 1.0 - exp(-delta / FOLLOW_TIME))
	_stretch(_upper, WeaponRack.BOW_NOCKS["upper"], _nock)
	_stretch(_lower, WeaponRack.BOW_NOCKS["lower"], _nock)
	_track_arrow()


## 搭箭點該在哪。右手的位置投影到弦所在的那個平面（x = 0），再夾在合理範圍內。
##
## 只准往 −Z 走：弦可以被拉向身體，不能被推到弓的前面去。
func _wanted() -> Vector3:
	var rest: Vector3 = WeaponRack.BOW_NOCKS["rest"]
	if _hand == null:
		return rest
	var hand := _hand.draw_point
	var pull := minf(rest.z - hand.z, WeaponRack.BOW_DRAW)
	_pull = pull
	if pull < SLACK:
		return rest
	# 上下也跟著手走一點，但範圍要小——搭箭點跑到弓臂上就不是拉弓了。
	var lift := clampf(hand.y, -0.2, 0.2)
	return Vector3(0.0, lift, rest.z - pull)


## 箭跟著搭箭點走；拉到位才出現，放手那一幀消失並放箭痕。
func _track_arrow() -> void:
	if _arrow == null:
		return
	if not _drawn and _pull > ARROW_SHOW:
		_drawn = true
	elif _drawn and _pull < ARROW_RELEASE:
		_drawn = false
		_release()
	_arrow.visible = _drawn
	if _arrow_head != null:
		_arrow_head.visible = _drawn
	if not _drawn:
		return
	# 箭桿的原點在弦上（搭箭點），往 +Z 伸出去；箭頭在桿子末端。
	var rest: Vector3 = WeaponRack.BOW_NOCKS["rest"]
	var shift := _nock - rest
	_arrow.position = Vector3(0.0, 0.0, 0.146) + shift
	if _arrow_head != null:
		_arrow_head.position = Vector3(0.0, 0.0, 0.486) + shift


## 放手：一道兩公尺的箭痕從搭箭點飛向弓的前方（+Z）然後熄掉。
##
## **不是投射物、不是射程**——判定照舊是 `AttackController` 那顆 2 公尺內的球，
## 這只是讓「放箭」看得見。粒子的速度與壽命乘起來大約就是判定球的距離。
func _release() -> void:
	var here := to_global(_nock)
	var forward := global_transform.basis.z.normalized()
	Vfx.burst(&"arrow_streak", here, forward)


## 把一段弦接在兩點之間。方塊的長軸是 +Y，所以要把它轉到兩點的連線上。
static func _stretch(part: MeshInstance3D, from: Vector3, to: Vector3) -> void:
	var span := to - from
	var length := span.length()
	if length < 0.0001:
		return
	# `looking_at` 讓 −Z 對上目標，所以再繞 X 轉 −90 度把 +Y 轉過去。
	var basis := Basis.looking_at(span.normalized(), Vector3.UP, true).rotated(
		Basis.looking_at(span.normalized(), Vector3.UP, true).x.normalized(), -PI * 0.5
	)
	part.transform = Transform3D(basis, (from + to) * 0.5)
	# 網格本身是 0.515 長（`WeaponRack.BOW` 寫死的），用縮放調到實際長度。
	part.scale = Vector3(1.0, length / 0.515, 1.0)
