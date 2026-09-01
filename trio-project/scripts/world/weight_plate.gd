class_name WeightPlate
extends Area3D

## 重量壓力板：把夠重的東西放上去，它連著的那道門就沉下去。
##
## 這一塊板子教的是整個遊戲的支柱——**一個身體跟一堆物件是同一個數字**。
## `WeightLadder` 一直在決定抓取、疊高順序、擊退、浮力，但玩家從頭到尾沒有
## 一次需要把重量**加起來**。板子逼他們算一次。
##
## host 權威（TD-02）：只有 host 秤重，結果同步，兩端各自把門推到位。
##
## ## 每幀從頭重算，不維護「誰在裡面」的字典
##
## goal_zone.gd 已經為這件事付過代價：人可以「站在裡面才倒下」，那一刻沒有
## 任何 body_exited，字典就會一直算著他。從重疊清單重建是天然自我修正的。

const SYNC_HZ := 10.0

## 門要沉多深、多快。**沉的深度等於門的高度**，沉完頂面剛好與地面齊平。
const GATE_DROP := 8.0
const GATE_SPEED := 3.2

## 浮點數的門檻餘裕。木箱正好是 25.0，而板子的門檻也正好是 25.0。
const WEIGHT_EPSILON := 0.01

## 自發光的強度範圍：沒有重量時的微光 → 滿載時的亮。
##
## **下限不能太低。** 遠岸那一塊在 2.4 公尺高的台上，從地面看只剩薄薄一條——
## 「上面有東西」跟「上面有多少」是兩件事，前者要一直看得到，玩家才會想爬上去。
const GLOW_IDLE := 0.55
const GLOW_FULL := 2.6

## 要多重才開。放在關卡檔裡，因為「這一塊要 50」是關卡設計不是元件行為。
@export var needed_weight: float = WeightLadder.PIG

## 開了就不再關。
##
## **第一章一定要 true。** 不閂住的話，撐著門的人一倒地，隊伍就被一道牆分開，
## 而這一章沒有檢查點可退。副作用剛好也擋掉「門夾人」——永不關閉的門壓不到人。
## 這個 export 存在是為了第二章的控制點以後可以用 false。
@export var latch: bool = true

## 這塊板子連著哪一道門。
@export var gate_path: NodePath

## 這一拍在目標列上的文字。**空字串＝支線，不進主線。**
##
## 型別必須是 String 不是 StringName——godot-parser 解析不了 `.tscn` 裡的
## `&"foo"`，而 check_project.py 會整檔解析每一個場景。
@export var objective: String = ""

var load_weight: float = 0.0
var is_open: bool = false

var _gate: Node3D = null
var _gate_closed_y: float = 0.0
var _sounded := false
var _glow: StandardMaterial3D = null


func _ready() -> void:
	add_to_group("weight_plates")
	_gate = get_node_or_null(gate_path) as Node3D
	if _gate == null:
		# 這是這個機關唯一會**靜默**壞掉的方式：板子照亮、門不動、玩家卡在
		# 關卡中間，而且不會有任何錯誤訊息。reach_probe 也驗這一條。
		push_warning("[Plate] %s 的 gate_path 指不到任何節點：%s" % [name, gate_path])
	else:
		_gate_closed_y = _gate.position.y
	_setup_glow()
	_setup_synchronizer()
	set_multiplayer_authority(1)


## 板子自己就是它的 UI。共用材質要先 duplicate——Palette 那一份是大家共用的。
func _setup_glow() -> void:
	var mesh := $Mesh as MeshInstance3D
	if mesh == null:
		return
	var source := mesh.material_override as StandardMaterial3D
	if source == null:
		return
	_glow = source.duplicate()
	mesh.material_override = _glow


func _setup_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	for property in [".:load_weight", ".:is_open"]:
		var path := NodePath(property)
		config.add_property(path)
		config.property_set_spawn(path, false)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	var sync := MultiplayerSynchronizer.new()
	sync.name = "Synchronizer"
	sync.replication_config = config
	sync.replication_interval = 1.0 / SYNC_HZ
	add_child(sync)


func _physics_process(delta: float) -> void:
	# 先做每一端都要做的事：門與燈都是從同步欄位推出來的，不必額外的 RPC。
	_drive_gate(delta)
	_show_load()
	if not NetworkService.is_host():
		return
	load_weight = _weigh()
	if load_weight >= needed_weight - WEIGHT_EPSILON:
		is_open = true
	elif not latch:
		is_open = false


## 門往目標高度走。move_toward 走向固定目標，所以兩端必然收斂，不會因為
## 封包晚到就停在不同的地方。
func _drive_gate(delta: float) -> void:
	if _gate == null:
		return
	var want := _gate_closed_y - (GATE_DROP if is_open else 0.0)
	_gate.position.y = move_toward(_gate.position.y, want, GATE_SPEED * delta)
	if is_open and not _sounded:
		_sounded = true
		Sfx.play(&"gate", _gate.global_position, 0.9)


## 「現在是 50 之中的 25」要能從二十公尺外讀出來。成本是一次插值。
func _show_load() -> void:
	if _glow == null:
		return
	var ratio := clampf(load_weight / maxf(needed_weight, WEIGHT_EPSILON), 0.0, 1.0)
	_glow.emission_energy_multiplier = lerpf(GLOW_IDLE, GLOW_FULL, ratio)


func _weigh() -> float:
	var total := 0.0
	for body in get_overlapping_bodies():
		total += _weight_of(body)
	return total


## 這一個物體算幾公斤。算不算數的兩條規則都寫在這裡。
func _weight_of(body: Node3D) -> float:
	# **玩家要先判**：玩家身上也掛著一個 Carryable（player_character.gd 會把
	# 自己的重量寫進去），先走下面那條路的話就查不到「他倒地了」。
	if body.is_in_group("player_characters"):
		var slot := int(body.get("slot_id"))
		# 屍體不該撐著一道門——跟 goal_zone.gd 同一條規則，理由也一樣。
		if DownSystem.is_downed(slot):
			return 0.0
		if int(body.get("carried_by_slot")) >= 0:
			return 0.0
		return float(body.get("weight"))
	var carryable := body.get_node_or_null("Carryable") as Carryable
	# 還被扛著就不算數——要放下才算數，這就是那個教學。
	if carryable == null or carryable.is_held():
		return 0.0
	return carryable.weight


## 這一拍完成了嗎。lobby_ui 靠它決定目標列要顯示哪一句，不必認得每一種型別。
func objective_done() -> bool:
	return is_open
