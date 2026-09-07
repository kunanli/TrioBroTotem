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
##
## **這個檔案裡所有手臂的數字都是相對於 STANCE（下面那一段）的。**
## 一開始不是——一開始是相對於骨架的靜置姿勢，也就是雙手平舉的 T 字，
## 所以「手舉高」寫成 −52 度實際上只是「從平舉往前掃 52 度」，手一直是打橫的。
## 加上 STANCE 那一層之後全部重調過一輪，而且是**看著畫面**調的
## （python3 tools/shoot_anim.py）——這是第一次能這樣做。

## **所有生成片段的共同底姿：把手臂從 T 字放下來。**
##
## 這是這一輪才發現的一個大坑。生成片段寫進去的是「靜置姿勢 + 偏移」
## （見 motion_forge.gd 的 `_forge()`），而這三份骨架的靜置姿勢是**雙手平舉
## 的 T 字**。所以在這個檔案裡寫 `LeftUpperArm: Vector3(-52, 0, -10)`，實際
## 看到的不是「手抬到胸前」而是「從平舉的位置再往前掃 52 度」——手從頭到尾
## 都是打橫的。
##
## 之前沒有人發現，因為在這台機器上看不到角色（那句話這一輪才被推翻）。
## 修法是給所有生成片段一個共同的底姿：上臂各往身側放下 74 度。加上這一層
## 之後，這個檔案裡其餘的手臂數字才真的是「相對於垂手站姿」的意思。
##
## 74 度是量出來的：這樣手腕大約落在髖部的高度，跟匯入的走路循環站定那一格
## 對得上——切換動畫的時候手臂才不會跳一下。
const STANCE := {
	&"LeftUpperArm": Vector3(0.0, 0.0, 74.0),
	&"RightUpperArm": Vector3(0.0, 0.0, -74.0),
}

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
			&"LeftUpperArm": Vector3(10.0, 0.0, 8.0),
			&"RightUpperArm": Vector3(10.0, 0.0, -8.0),
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
			&"LeftUpperArm": Vector3(-30.0, 0.0, -110.0),
			&"RightUpperArm": Vector3(-30.0, 0.0, 110.0),
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
			&"LeftUpperArm": Vector3(-16.0, 0.0, -60.0),
			&"RightUpperArm": Vector3(-16.0, 0.0, 60.0),
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
			&"LeftUpperArm": Vector3(14.0, 0.0, -52.0),
			&"RightUpperArm": Vector3(14.0, 0.0, 52.0),
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
		&"Spine": Vector3(12.0, -16.0, 0.0),
		&"Chest": Vector3(8.0, -10.0, 0.0),
		&"Head": Vector3(-6.0, 8.0, 0.0),
		&"LeftUpperArm": Vector3(-20.0, 0.0, -128.0),
		&"RightUpperArm": Vector3(-26.0, 0.0, 128.0),
		&"LeftLowerArm": Vector3(-46.0, 0.0, 0.0),
		&"RightLowerArm": Vector3(-52.0, 0.0, 0.0),
	},
	"impact": {
		&"Spine": Vector3(-26.0, 18.0, 0.0),
		&"Chest": Vector3(-16.0, 12.0, 0.0),
		&"Head": Vector3(-10.0, -6.0, 0.0),
		&"LeftUpperArm": Vector3(-58.0, 0.0, -30.0),
		&"RightUpperArm": Vector3(-58.0, 0.0, 30.0),
		&"LeftLowerArm": Vector3(-16.0, 0.0, 0.0),
		&"RightLowerArm": Vector3(-16.0, 0.0, 0.0),
	},
}

## 貓弓手：快抽快放。軀幹幾乎不動，動作集中在手臂——收招最快的一隻。
##
## 軀幹的 Y（扭轉）是整個動作前後方向的來源，比手臂本身還關鍵：
## 蓄力時 Y 負（向右轉、右肩拉到後面），出手時 Y 正（向左轉、右肩推出去）。
## 正負顛倒的話會變成「蓄力時手往前伸、出手時手往後縮」——實測踩過。
const CAT_SHOT := {
	"windup": {
		&"Spine": Vector3(0.0, -18.0, 0.0),
		&"Chest": Vector3(-3.0, -10.0, 0.0),
		&"Head": Vector3(0.0, 14.0, 0.0),
		&"LeftUpperArm": Vector3(-80.0, 0.0, -64.0),
		&"RightUpperArm": Vector3(-58.0, 0.0, 34.0),
		&"LeftLowerArm": Vector3(-6.0, 0.0, 0.0),
		&"RightLowerArm": Vector3(-92.0, 0.0, 0.0),
	},
	"impact": {
		&"Spine": Vector3(0.0, 6.0, 0.0),
		&"Chest": Vector3(-2.0, 4.0, 0.0),
		&"Head": Vector3(2.0, -2.0, 0.0),
		&"LeftUpperArm": Vector3(-82.0, 0.0, -66.0),
		&"RightUpperArm": Vector3(-40.0, 0.0, 46.0),
		&"LeftLowerArm": Vector3(-4.0, 0.0, 0.0),
		&"RightLowerArm": Vector3(-30.0, 0.0, 0.0),
	},
}

## 蛙法師：前推法杖。蓄力時手收到胸前畫圓，出手時整條手臂直推出去。
const FROG_CAST := {
	"windup": {
		&"Spine": Vector3(8.0, -12.0, 0.0),
		&"Chest": Vector3(6.0, -8.0, 0.0),
		&"Head": Vector3(-6.0, 4.0, 0.0),
		&"LeftUpperArm": Vector3(-48.0, 0.0, -30.0),
		&"RightUpperArm": Vector3(-54.0, 0.0, 34.0),
		&"LeftLowerArm": Vector3(-70.0, 0.0, 0.0),
		&"RightLowerArm": Vector3(-78.0, 0.0, 0.0),
	},
	"impact": {
		&"Spine": Vector3(-14.0, 10.0, 0.0),
		&"Chest": Vector3(-9.0, 7.0, 0.0),
		&"Head": Vector3(-4.0, -4.0, 0.0),
		&"LeftUpperArm": Vector3(-70.0, 0.0, -44.0),
		&"RightUpperArm": Vector3(-84.0, 0.0, 50.0),
		&"LeftLowerArm": Vector3(-16.0, 0.0, 0.0),
		&"RightLowerArm": Vector3(-10.0, 0.0, 0.0),
	},
}

## 站姿：三隻各自的持械架式。**這一支補起來之前，「待機」是把走路動畫停在
## 第 0.55 幀**（character_roster.gd 的 idle_hold），而 CharacterVisual._stand()
## 從第一天就在問 `idle` 了，只是沒有人做過。
##
## **畫面上的姿勢是三層相加的**，調數字之前要先弄清楚在調哪一層：
##
##   ① STANCE          上臂放下 74 度的共同底姿（上面那一段）
##   ② 這裡            這一隻的持械架式
##   ③ 名冊的 pose.bones  ProceduralPose 每幀再疊的職業姿態
##
## 所以手臂的數字看起來會怪：法師的右上臂在這裡是 +82，因為名冊那一層已經
## 往內收了 52 度（那是為了修這隻骨架本身手張太開，走路時要，站著時太多）。
## −74 + 82 − 52 = −44 度，那才是畫面上看到的角度。想改「站著的時候手臂在哪」
## 就改這裡；想改「走路的時候」才去動名冊。
##
## 腿一定要寫。生成的片段只驅動有寫到的骨頭，沒寫的會停在上一支動畫留下的
## 那一格——不寫腿的話，站定時的腳會停在走路循環的隨機一步上，而且**每次
## 停下來的姿勢都不一樣**。攻擊片段可以不寫腿（它只播 0.3 秒就還給走路），
## 待機不行，那是會一直停在畫面上的東西。
const IDLE := {
	# 戰士：方肩、重心壓低、雙腳張開，右臂往外撐讓劍離開身體的剪影
	#（右上臂淨值 −74 + 12 + 14 = −48 度），左手空著微微張開。
	&"pig_warrior": {
		&"Spine": Vector3(-6.0, -8.0, 0.0),
		&"Chest": Vector3(3.0, 6.0, 0.0),
		&"Head": Vector3(0.0, 4.0, 0.0),
		&"RightUpperArm": Vector3(-16.0, 0.0, 12.0),
		&"RightLowerArm": Vector3(-32.0, 0.0, 0.0),
		&"LeftUpperArm": Vector3(-6.0, 0.0, -8.0),
		&"LeftLowerArm": Vector3(-14.0, 0.0, 0.0),
		&"LeftUpperLeg": Vector3(0.0, 0.0, -6.0),
		&"RightUpperLeg": Vector3(0.0, 0.0, 6.0),
		&"LeftLowerLeg": Vector3(-8.0, 0.0, 0.0),
		&"RightLowerLeg": Vector3(-8.0, 0.0, 0.0),
	},
	# 法師：站得最直，**法杖橫抱在胸前、雙手分開握在杖身上**。
	#
	# 右上臂的 Z 是**大的正值**，跟另外兩隻相反：這隻的名冊 pose 已經把右臂
	# 往內收了 52 度（那是為了修骨架本身手張太開），照抄另外兩隻的寫法會把
	# 手臂插進軀幹。+74 是把它扳回來，淨值 −52 度。
	#
	# **手臂的 X 是為了讓左手搆得到法杖才調到 −62／−42 的，不是為了好看。**
	# 原本法杖立在身側（右上臂 X −24），左肩到杖身握點是 1.07 倍臂長——
	# 差那 7% 就是「手在法杖旁邊比劃」而不是「握著法杖」。
	#
	# 法杖的朝向試了六種才定下來，而且最後是**數像素**定的（`weapon_aim.gd`）：
	# 斜立在身前會整支插進頭裡（這三隻的頭佔一半身高）、往前倒又被縮成一個點。
	# 橫抱在胸前偏左才兩件都對：左肩到握點 0.48 倍臂長，整支看得見。
	#
	# 左臂那兩個數字只影響 CCD 的**起始姿勢**（IK 會整條重解），但起始離目標
	# 太遠的話肩膀會被轉一大圈才搆到——看起來像脫臼。所以它也要先擺到附近。
	#
	# 改這裡就要重跑：`weapon_aim`（貼回名冊的 spin）→ `hand_probe`（看握不握得住）。
	&"frog_mage": {
		&"Spine": Vector3(3.0, 6.0, 0.0),
		&"Chest": Vector3(2.0, -4.0, 0.0),
		&"Head": Vector3(-4.0, 0.0, 0.0),
		&"RightUpperArm": Vector3(-62.0, 0.0, 40.0),
		&"RightLowerArm": Vector3(-40.0, 0.0, 0.0),
		&"LeftUpperArm": Vector3(-42.0, 0.0, -62.0),
		&"LeftLowerArm": Vector3(-40.0, 0.0, 0.0),
		&"LeftUpperLeg": Vector3(0.0, 0.0, -4.0),
		&"RightUpperLeg": Vector3(0.0, 0.0, 4.0),
		&"LeftLowerLeg": Vector3(-4.0, 0.0, 0.0),
		&"RightLowerLeg": Vector3(-4.0, 0.0, 0.0),
	},
	# 弓手：側身站（Spine 的 Y 是三隻裡唯一大的），左手把弓抬起來推離身體
	#（左上臂淨值 +74 − 42 − 5 = +27 度，三隻裡抬得最高的一隻手），
	# **右手搭在弓弦上**。側身是弓手最強的剪影特徵。
	#
	# 右臂的 X −38、前臂 −74 是把手送到弦附近。弓本來就在臂長之內（肩到弦
	# 0.92 倍臂長），所以這裡調的不是「搆不搆得到」而是**起始姿勢**：
	# 原本右手停在腰側，離弦 85 公分，CCD 每一輪只削掉 7%，八輪之後還差
	# 13 公分。手先擺到附近，殘差就進到 1 公分以內。
	&"cat_archer": {
		&"Spine": Vector3(0.0, 14.0, 0.0),
		&"Chest": Vector3(-2.0, -6.0, 0.0),
		&"Head": Vector3(0.0, -10.0, 0.0),
		&"LeftUpperArm": Vector3(-26.0, 0.0, -42.0),
		&"LeftLowerArm": Vector3(4.0, 0.0, 0.0),
		&"RightUpperArm": Vector3(-38.0, 0.0, 12.0),
		&"RightLowerArm": Vector3(-74.0, 0.0, 0.0),
		&"LeftUpperLeg": Vector3(0.0, 0.0, -7.0),
		&"RightUpperLeg": Vector3(0.0, 0.0, 5.0),
		&"LeftLowerLeg": Vector3(-6.0, 0.0, 0.0),
		&"RightLowerLeg": Vector3(-6.0, 0.0, 0.0),
	},
}

## 三隻共用：轉身時往內側傾。**這是疊加姿勢，不是片段。**
##
## 本來做成一支 `turn` 片段，做完才發現**它永遠不會播**：`player_character.gd`
## 的 `_yaw` 只在 `moving` 為真時才更新，所以「站著不動卻轉了一大圈」這個
## 觸發條件在遊戲裡根本不成立。那正是這個專案一路在抓的那類東西——
## 一支做好了、掛好了、驗證也「通過」了，但從第一天起就沒有播過的動畫。
##
## 改成疊加層之後三個問題一起解掉：不必挑觸發時機（轉多快就疊多少）、
## 不會擋住走路（片段會整支蓋掉 locomotion，轉身時腿會僵住）、
## 而且**跑步中轉彎也吃得到**——那才是真正看得出來的地方。
##
## 這一組數字是「往左轉」的。往右轉時整組乘上負的權重就好，所以**只准放
## Y 與 Z 分量、只准放軀幹骨**：手臂左右不對稱，乘負號不等於鏡像。
const PIVOT_POSE := {
	&"Hips": Vector3(0.0, -4.0, -7.0),
	&"Spine": Vector3(0.0, 6.0, -5.0),
	&"Chest": Vector3(0.0, 6.0, -3.0),
	&"Head": Vector3(0.0, 10.0, 0.0),
}

## 跑步不是手刻的，是**把匯入的走路循環改出來的**。
##
## 為什麼：走路是這三份 GLB 唯一帶進來的動畫，而它有真正的落腳時機——
## 那是手刻關鍵影格最難做對、也最容易露餡的東西。與其從零刻一支跑步，
## 不如把走路的每一格繞著**這條軌自己的平均姿勢**外插放大（同一個擺動、
## 幅度更大），再疊一個固定的前傾。落腳的節奏原封不動保留下來。
##
## STRIDE 同時是外插倍率**與**速度匹配的依據：步幅放大 1.45 倍之後，同樣的
## 移動速度只需要 1/1.45 的步頻。CharacterVisual 的移動片段表就是從這個數字
## 算基準速度的——兩邊分開寫的話，調了這裡而忘了那裡，腳就會開始滑。
##
## **1.45 已經是解剖學上限，不要再往上調。** `gait_probe` 量到走路片段的腳踝
## 前後行程是 0.53 公尺、髖到踝的腿長也是 0.53 公尺，比值 0.99；而兩腿都伸直
## 時的極限大約是 1.4。0.99 × 1.45 = 1.44，正好頂到。再放大，腳會被送到腿構不
## 到的位置，畫面上是腿打直、腳陷進地面。
##
## 這件事的後果寫在 `CharacterVisual` 的移動片段表：**全速要靠步頻，不是步幅。**
const RUN_STRIDE := 1.45

## 手臂骨。放大幅度時手臂要單獨算——見 motion_forge.gd 的 `_forge_run()`。
const ARM_BONES: Array[StringName] = [
	&"LeftShoulder", &"LeftUpperArm", &"LeftLowerArm", &"LeftHand",
	&"RightShoulder", &"RightUpperArm", &"RightLowerArm", &"RightHand",
]

## 跑步時手臂的擺動倍率。
##
## 比步幅小很多，而且是**故意的**：三隻手上都有武器，而武器是焊在手骨上的，
## 手臂擺多少武器就甩多少。0.85 讓上半身穩住、步幅照樣放大——拿著東西跑本來
## 就不會大甩手。
##
## **這個數字差點在做手部 IK 那一輪被刪掉。** 當時的想法是：它存在的唯一理由就是
## 壓武器，而 `hand_ik.gd` 已經逐手逐幀在做同一件事，所以這個全域倍率該退休。
## 量了才知道不行——把它與 `SPRINT_ARM_SWING` 都設成 `RUN_STRIDE`（手臂跟著腿
## 一起放大）之後，即使 IK 開著，武器尖端一個循環的行程還是明顯變差：
##
##     跑步   豬 24 → 35　蛙 20 → 33　貓 31 → 48 公分
##     衝刺   豬 23 → 27　蛙 24 → 30　貓 31 → 37 公分
##
## 而且蛙的副手「肩到握點」剛好頂到 1.00 倍臂長——再多一點就握不住法杖了。
## 所以它留下來，但**理由從「不然法杖跑起來會像在划船」換成上面那組數字**：
## 它與 IK 是相加的，不是二選一。要動它，先跑 `hand_probe`。
const RUN_ARM_SWING := 0.85

## 疊在跑步每一格上的固定偏移。頭要往回抬，否則前傾會變成低頭衝刺。
const RUN_LEAN := {
	&"Spine": Vector3(-13.0, 0.0, 0.0),
	&"Chest": Vector3(-6.0, 0.0, 0.0),
	&"Head": Vector3(10.0, 0.0, 0.0),
}

## 衝刺：全速那一段用的片段。
##
## **它的步幅跟跑步一樣**，因為 `RUN_STRIDE` 已經頂到解剖學上限（見上）。
## 差別全在姿勢——壓得更低、手臂擺得更開、下巴更收。同樣的步頻下，這個姿勢
## 讀起來就是「在衝」，而不是「跑步動畫被快轉」。
##
## 為什麼不乾脆讓跑步一路用到底：`PlayerCharacter.SPEED` 是 6.0 m/s，而這三隻
## 走路的自然速度只有 0.75–0.92 m/s。步幅頂到 1.45 之後，全速還是需要大約
## 4.7 倍的步頻——一秒九步。那個節奏配跑步的中等前傾會很怪，配壓低的衝刺
## 姿勢才對得起來。**這是大頭身角色的代價**：腿只有身高的三分之一，
## 要跑那麼快就只能拿步頻換。
const SPRINT_LEAN := {
	&"Spine": Vector3(-26.0, 0.0, 0.0),
	&"Chest": Vector3(-12.0, 0.0, 0.0),
	&"Head": Vector3(22.0, 0.0, 0.0),
	&"LeftUpperArm": Vector3(0.0, 0.0, -16.0),
	&"RightUpperArm": Vector3(0.0, 0.0, 16.0),
	&"LeftLowerArm": Vector3(-34.0, 0.0, 0.0),
	&"RightLowerArm": Vector3(-34.0, 0.0, 0.0),
}

## 衝刺時手臂的擺動倍率。比跑步大一點——衝刺就是靠手臂帶步頻。
##
## **但拿著武器的那隻手看不出這件事。** `hand_ik.gd` 的平滑對高頻壓得比低頻重
## （衰減是 1/√(1+(2πfτ)²)），而衝刺的步頻是走路的四五倍。實測武器尖端在衝刺時
## 的行程反而比跑步**小**（豬 23.2 vs 24.2 公分）。空著的那隻手仍然吃得到，
## 所以這個數字還是有作用——只是作用在剪影上，不在武器上。
const SPRINT_ARM_SWING := 1.15


## 每隻角色的出手姿勢。之後多一隻角色就多一組，不必動 motion_forge.gd。
const SWINGS := {
	&"pig_warrior": PIG_SWING,
	&"cat_archer": CAT_SHOT,
	&"frog_mage": FROG_CAST,
}


## 收招的跟隨：後搖到這個比例時擺到出手姿勢的**負**這麼多倍（收過頭），再回中性。
##
## 原本只有重擊與衝刺撞擊有（`settle`），輕擊是出手完直接滑回中性——畫面上是
## 「啄一下」。真人揮完手臂一定會收過頭再回來，那是慣性。輕擊的後搖只有 0.16 秒，
## 這一格落在 0.056 秒，60 fps 下三格，看得到。`settle` 的招式用比較大的倍率。
const FOLLOW_AT := 0.35
const FOLLOW_FACTOR := -0.15


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
