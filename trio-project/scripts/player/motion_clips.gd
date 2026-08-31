class_name MotionClips
extends RefCounted

## 生成用的戰鬥動作資料。角度約定見 bone_space.gd。
##
## 為什麼戰鬥動作用生成而不是外購（TD-12）：判定窗口只有 0.08 秒
## （見 CombatSpec.COMBO）。現成動畫要對上它得逐支手動重新計時，而且每次調
## windup 都要重對一次。這裡的關鍵影格是**相對於相位**寫的，時間由 CombatSpec
## 填進去——出手的那一格永遠正好是判定打開的那一刻，不可能飄。
##
## 每一格是 {"phase": 相位, "at": 該相位內的比例 0~1, "pose": {骨名: 角度}}。
## 相位順序固定 windup → active → recovery。沒寫到的骨頭不建軌，
## 留給 procedural_pose.gd 繼續疊（它在單次動作播放時本來就會淡出職業姿態）。
##
## 動作設計的共同原則（docs/05 的基準是 Overcooked：回饋速度優先）：
##   - 蓄力要「反方向拉開」，出手才有落差。但 windup 只有 0.07–0.13 秒，
##     幅度不能大，大了會變成慢動作。
##   - 出手的那一格是**整段最極端的姿勢**，不是中間值。
##   - 收招走回中性，最後一格一定是空 pose，否則會殘留姿勢。

## 三隻共用：受擊。短、只有一格衝擊 + 回復。
const HURT := [
	{"phase": &"windup", "at": 0.0, "pose": {}},
	{
		"phase": &"active", "at": 0.0,
		"pose": {
			&"Spine": Vector3(14.0, 0.0, 0.0),
			&"Chest": Vector3(10.0, 0.0, 0.0),
			&"Head": Vector3(12.0, 0.0, 0.0),
			&"LeftUpperArm": Vector3(0.0, 0.0, -18.0),
			&"RightUpperArm": Vector3(0.0, 0.0, 18.0),
		},
	},
	{"phase": &"recovery", "at": 1.0, "pose": {}},
]

## 三隻共用：倒下。倒地的整體傾倒由 PlayerCharacter 的 DOWNED_PITCH 負責，
## 這裡只做上半身癱軟，兩者疊起來才像「腿軟了」而不是「木板倒下」。
const DEATH := [
	{"phase": &"windup", "at": 0.0, "pose": {}},
	{
		"phase": &"active", "at": 0.6,
		"pose": {
			&"Spine": Vector3(-22.0, 0.0, 6.0),
			&"Chest": Vector3(-14.0, 0.0, 4.0),
			&"Head": Vector3(-26.0, 0.0, 8.0),
			&"LeftUpperArm": Vector3(0.0, 0.0, -26.0),
			&"RightUpperArm": Vector3(0.0, 0.0, 12.0),
			&"LeftLowerArm": Vector3(-18.0, 0.0, 0.0),
		},
	},
	{
		"phase": &"recovery", "at": 1.0,
		"pose": {
			&"Spine": Vector3(-28.0, 0.0, 8.0),
			&"Chest": Vector3(-16.0, 0.0, 5.0),
			&"Head": Vector3(-30.0, 0.0, 10.0),
			&"LeftUpperArm": Vector3(0.0, 0.0, -30.0),
			&"RightUpperArm": Vector3(0.0, 0.0, 14.0),
			&"LeftLowerArm": Vector3(-22.0, 0.0, 0.0),
		},
	},
]


## 三隻共用：起跳。**第一組會碰到腿骨的姿勢資料。**
##
## 之前的片段都只寫上半身，因為攻擊看的是手。但跳躍與落地讀不讀得出來
## 幾乎完全靠腿——不縮腿的跳躍看起來只是整個人往上平移。
## 腿骨（LeftUpperLeg／LowerLeg）確實存在，管線的必要骨清單裡就有（TD-07）。
##
## 起跳的形狀：蹲一下（windup）→ 蹬直、手往上帶（active）→ 空中把腿縮起來
## （recovery）。第三格刻意不回中性，因為離開地面之後這個姿勢要接著被
## ProceduralPose 的滯空層接手。
const JUMP := [
	{
		"phase": &"windup", "at": 0.0,
		"pose": {
			&"Spine": Vector3(-10.0, 0.0, 0.0),
			&"LeftUpperLeg": Vector3(26.0, 0.0, 0.0),
			&"RightUpperLeg": Vector3(26.0, 0.0, 0.0),
			&"LeftLowerLeg": Vector3(-40.0, 0.0, 0.0),
			&"RightLowerLeg": Vector3(-40.0, 0.0, 0.0),
			&"LeftUpperArm": Vector3(14.0, 0.0, -6.0),
			&"RightUpperArm": Vector3(14.0, 0.0, 6.0),
		},
	},
	{
		"phase": &"active", "at": 0.5,
		"pose": {
			&"Spine": Vector3(6.0, 0.0, 0.0),
			&"Chest": Vector3(4.0, 0.0, 0.0),
			&"LeftUpperLeg": Vector3(-8.0, 0.0, 0.0),
			&"RightUpperLeg": Vector3(-8.0, 0.0, 0.0),
			&"LeftLowerLeg": Vector3(-4.0, 0.0, 0.0),
			&"RightLowerLeg": Vector3(-4.0, 0.0, 0.0),
			&"LeftUpperArm": Vector3(-52.0, 0.0, -10.0),
			&"RightUpperArm": Vector3(-52.0, 0.0, 10.0),
		},
	},
	{
		"phase": &"recovery", "at": 1.0,
		"pose": {
			&"Spine": Vector3(-4.0, 0.0, 0.0),
			&"LeftUpperLeg": Vector3(18.0, 0.0, 0.0),
			&"RightUpperLeg": Vector3(12.0, 0.0, 0.0),
			&"LeftLowerLeg": Vector3(-34.0, 0.0, 0.0),
			&"RightLowerLeg": Vector3(-24.0, 0.0, 0.0),
			&"LeftUpperArm": Vector3(-24.0, 0.0, -12.0),
			&"RightUpperArm": Vector3(-24.0, 0.0, 12.0),
		},
	},
]

## 三隻共用：落地。屈膝吸收再站直。
##
## 最極端的那一格在 active 的開頭而不是中間——落地的衝擊是瞬間的，
## 慢慢蹲下去會變成「緩緩坐下」。這與攻擊「出手那一格最極端」是同一條原則。
const LAND := [
	{"phase": &"windup", "at": 0.0, "pose": {}},
	{
		"phase": &"active", "at": 0.0,
		"pose": {
			&"Spine": Vector3(-16.0, 0.0, 0.0),
			&"Chest": Vector3(-8.0, 0.0, 0.0),
			&"Head": Vector3(-10.0, 0.0, 0.0),
			&"LeftUpperLeg": Vector3(34.0, 0.0, 0.0),
			&"RightUpperLeg": Vector3(34.0, 0.0, 0.0),
			&"LeftLowerLeg": Vector3(-52.0, 0.0, 0.0),
			&"RightLowerLeg": Vector3(-52.0, 0.0, 0.0),
			&"LeftUpperArm": Vector3(20.0, 0.0, -20.0),
			&"RightUpperArm": Vector3(20.0, 0.0, 20.0),
		},
	},
	{"phase": &"recovery", "at": 1.0, "pose": {}},
]

## 滯空與扛東西是**疊加姿勢**不是片段（見 procedural_pose.gd）。
##
## 兩者都沒有固定長度——你可能掉半秒也可能掉五秒，扛著東西可能走一分鐘。
## 一次性片段靠 animation_finished 收尾，播不完就永遠鎖住 _action，
## locomotion 會再也不播。所以這兩個走加法層，讓腿繼續走它的路。
const AIRBORNE_POSE := {
	&"Spine": Vector3(-6.0, 0.0, 0.0),
	&"Chest": Vector3(-4.0, 0.0, 0.0),
	&"LeftUpperArm": Vector3(-18.0, 0.0, -16.0),
	&"RightUpperArm": Vector3(-18.0, 0.0, 16.0),
	&"LeftLowerArm": Vector3(-14.0, 0.0, 0.0),
	&"RightLowerArm": Vector3(-14.0, 0.0, 0.0),
}

## 扛東西：雙手抬到身前，上身微微後仰抗衡重量。
## 只有上半身——腿要照常走路，這正是走加法層而不是片段的理由。
const CARRY_POSE := {
	&"Spine": Vector3(8.0, 0.0, 0.0),
	&"Chest": Vector3(5.0, 0.0, 0.0),
	&"Head": Vector3(-4.0, 0.0, 0.0),
	&"LeftUpperArm": Vector3(-62.0, 0.0, 14.0),
	&"RightUpperArm": Vector3(-62.0, 0.0, -14.0),
	&"LeftLowerArm": Vector3(-46.0, 0.0, 0.0),
	&"RightLowerArm": Vector3(-46.0, 0.0, 0.0),
}


## 豬戰士：過頂重砸。蓄力時整個上身向後拉開、雙手舉高，出手時壓下去。
## 幅度是三隻裡最大的——戰士的辨識度就在「慢半拍但很重」。
const PIG_SWING := {
	"windup": {
		&"Spine": Vector3(9.0, -14.0, 0.0),
		&"Chest": Vector3(7.0, -10.0, 0.0),
		&"Head": Vector3(-4.0, 8.0, 0.0),
		&"LeftUpperArm": Vector3(-64.0, 0.0, -18.0),
		&"RightUpperArm": Vector3(-70.0, 0.0, 16.0),
		&"LeftLowerArm": Vector3(-40.0, 0.0, 0.0),
		&"RightLowerArm": Vector3(-46.0, 0.0, 0.0),
	},
	"impact": {
		&"Spine": Vector3(-22.0, 16.0, 0.0),
		&"Chest": Vector3(-14.0, 12.0, 0.0),
		&"Head": Vector3(-10.0, -6.0, 0.0),
		&"LeftUpperArm": Vector3(36.0, 0.0, -10.0),
		&"RightUpperArm": Vector3(40.0, 0.0, 8.0),
		&"LeftLowerArm": Vector3(-12.0, 0.0, 0.0),
		&"RightLowerArm": Vector3(-10.0, 0.0, 0.0),
	},
}

## 貓弓手：快抽快放。軀幹幾乎不動，動作集中在手臂——收招最快的一隻。
##
## 軀幹的 Y（扭轉）是整個動作前後方向的來源，比手臂本身還關鍵：
## 蓄力時 Y 負（向右轉、右肩拉到後面），出手時 Y 正（向左轉、右肩推出去）。
## 正負顛倒的話會變成「蓄力時手往前伸、出手時手往後縮」——實測踩過。
const CAT_SHOT := {
	"windup": {
		&"Spine": Vector3(0.0, -16.0, 0.0),
		&"Chest": Vector3(-3.0, -10.0, 0.0),
		&"Head": Vector3(0.0, 12.0, 0.0),
		&"LeftUpperArm": Vector3(-46.0, 0.0, -8.0),
		&"RightUpperArm": Vector3(-16.0, 0.0, 22.0),
		&"LeftLowerArm": Vector3(-18.0, 0.0, 0.0),
		&"RightLowerArm": Vector3(-64.0, 0.0, 0.0),
	},
	"impact": {
		&"Spine": Vector3(-4.0, 8.0, 0.0),
		&"Chest": Vector3(-2.0, 6.0, 0.0),
		&"Head": Vector3(2.0, -2.0, 0.0),
		&"LeftUpperArm": Vector3(-52.0, 0.0, -6.0),
		&"RightUpperArm": Vector3(-30.0, 0.0, 30.0),
		&"LeftLowerArm": Vector3(-6.0, 0.0, 0.0),
		&"RightLowerArm": Vector3(-20.0, 0.0, 0.0),
	},
}

## 蛙法師：前推法杖。蓄力時手收到胸前畫圓，出手時整條手臂直推出去。
const FROG_CAST := {
	"windup": {
		&"Spine": Vector3(6.0, -10.0, 0.0),
		&"Chest": Vector3(5.0, -8.0, 0.0),
		&"Head": Vector3(-6.0, 4.0, 0.0),
		&"LeftUpperArm": Vector3(-20.0, 0.0, -20.0),
		&"RightUpperArm": Vector3(-24.0, 0.0, 20.0),
		&"LeftLowerArm": Vector3(-56.0, 0.0, 0.0),
		&"RightLowerArm": Vector3(-62.0, 0.0, 0.0),
	},
	"impact": {
		&"Spine": Vector3(-12.0, 8.0, 0.0),
		&"Chest": Vector3(-8.0, 6.0, 0.0),
		&"Head": Vector3(-4.0, -4.0, 0.0),
		&"LeftUpperArm": Vector3(-44.0, 0.0, -12.0),
		&"RightUpperArm": Vector3(-48.0, 0.0, 12.0),
		&"LeftLowerArm": Vector3(-8.0, 0.0, 0.0),
		&"RightLowerArm": Vector3(-6.0, 0.0, 0.0),
	},
}

## 每隻角色的出手姿勢。之後多一隻角色就多一組，不必動 motion_forge.gd。
const SWINGS := {
	&"pig_warrior": PIG_SWING,
	&"cat_archer": CAT_SHOT,
	&"frog_mage": FROG_CAST,
}


## 連擊每一段的幅度倍率與鏡像。
##
## 第二段鏡像過來（mirror = -1），左右交替看起來才像連擊而不是同一招播兩次；
## 第三段是重擊，幅度放大，而且它的 recovery 有 0.32 秒——夠長，可以讓收招
## 走一個「站不穩再站定」的中間格。
const COMBO_SHAPE := [
	{"scale": 1.0, "mirror": 1.0, "settle": false},
	{"scale": 0.95, "mirror": -1.0, "settle": false},
	{"scale": 1.35, "mirror": 1.0, "settle": true},
]

## 情境攻擊。衝刺撞擊是整個人壓低往前撞，空中下劈是由上往下。
const DASH_SHAPE := {"scale": 1.1, "mirror": 1.0, "settle": true}
const AIR_SHAPE := {"scale": 1.25, "mirror": 1.0, "settle": true}


## 鏡像一組姿勢：左右骨頭對調，Y（轉向）與 Z（側傾）反號，X（俯仰）不變。
static func mirrored(pose: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key in pose:
		var bone: StringName = key
		var value: Vector3 = pose[bone]
		var name := String(bone)
		if name.begins_with("Left"):
			name = "Right" + name.substr(4)
		elif name.begins_with("Right"):
			name = "Left" + name.substr(5)
		out[StringName(name)] = Vector3(value.x, -value.y, -value.z)
	return out


static func scaled(pose: Dictionary, factor: float) -> Dictionary:
	var out: Dictionary = {}
	for key in pose:
		var bone: StringName = key
		out[bone] = (pose[bone] as Vector3) * factor
	return out
