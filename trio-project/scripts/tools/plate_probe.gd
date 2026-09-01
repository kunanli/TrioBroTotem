extends Node3D

## 壓力板真的秤得到重量嗎、門真的沉下去嗎。
##
## `reach_probe` 驗的是靜態的東西（門接得到、門檻抬得動）。這一支驗的是**行為**，
## 而且走真的那條路：真的開一個 host、真的道具、真的玩家、真的物理幀。
##
## 為什麼值得一支獨立的探針：這個機關的四條規則沒有一條看得出來壞了。
## 秤錯重量的板子看起來完全正常，只是永遠踩不開，或者永遠開著；倒地的人
## 還算數的話，一具屍體就能撐著一道門，而那是 goal_zone.gd 早就付過的學費。
##
##     godot --headless --path trio-project res://scenes/tools/plate_probe.tscn

## host 只是為了讓 NetworkService.is_host() 成立，不會有人連進來。
const PROBE_PORT := 45999

var _failures: Array[String] = []


func _ready() -> void:
	NetworkService.host_game(PROBE_PORT)
	var world: Node3D = load("res://scenes/world/test_arena.tscn").instantiate()
	add_child(world)
	for _index in 4:
		await get_tree().physics_frame

	await _check_prop(world)
	await _check_player(world)
	_check_objectives()

	for line in _failures:
		printerr("[Plate] %s" % line)
	print("[Plate] 驗了 7 條規則，%d 條不成立" % _failures.size())
	get_tree().quit(1 if _failures.size() > 0 else 0)


## 道具那一半：放上去會開、門會沉、拿走了不會關（latch）。
func _check_prop(world: Node3D) -> void:
	var plate: Node3D = world.get_node("ShelfPlate")
	var gate: Node3D = world.get_node("BankGate")
	var crate: Node3D = world.get_node("BankCrate")
	var closed_y: float = gate.position.y
	_expect(not bool(plate.get("is_open")), "遠岸的門一開始就是開的")

	# 木箱 25.0 對上門檻 25.0：浮點數剛好相等，WEIGHT_EPSILON 就是為了這一格。
	crate.global_position = plate.global_position + Vector3(0.0, 0.6, 0.0)
	var prop := crate as Prop
	prop.linear_velocity = Vector3.ZERO
	prop.net_position = crate.global_position
	for _index in 20:
		await get_tree().physics_frame
	_expect(
		absf(float(plate.get("load_weight")) - WeightLadder.CRATE) < 0.01,
		"放上木箱之後載重是 %.1f，應該是 %.1f" % [plate.get("load_weight"), WeightLadder.CRATE]
	)
	_expect(bool(plate.get("is_open")), "載重夠了但門沒開")

	for _index in 60:
		await get_tree().physics_frame
	_expect(gate.position.y < closed_y - 1.0, "門沒有在沉：y 還在 %.2f" % gate.position.y)

	crate.global_position = Vector3(0.0, 1.0, -12.0)
	prop.net_position = crate.global_position
	for _index in 20:
		await get_tree().physics_frame
	_expect(bool(plate.get("is_open")), "拿走木箱之後門關回去了——latch 沒有生效")


## 玩家那一半：一個身體跟一堆物件是同一個數字，而倒地的人不算數。
func _check_player(world: Node3D) -> void:
	var plate: Node3D = world.get_node("SeepPlate")
	var slot: int = PlayerRegistry.slots[0].slot_id
	var player: Node3D = load("res://scenes/player/player.tscn").instantiate()
	player.slot_id = slot
	world.add_child(player)
	player.global_position = plate.global_position + Vector3(0.0, 0.9, 0.0)
	for _index in 20:
		await get_tree().physics_frame
	_expect(
		absf(float(plate.get("load_weight")) - WeightLadder.PIG) < 0.01,
		"豬站上去載重是 %.1f，應該是 %.1f" % [plate.get("load_weight"), WeightLadder.PIG]
	)

	DownSystem.apply_damage(slot, 999.0, Vector3.ZERO)
	for _index in 10:
		await get_tree().physics_frame
	_expect(
		float(plate.get("load_weight")) < 0.01,
		"倒地的人還算 %.1f 公斤——屍體不該撐著一道門" % plate.get("load_weight")
	)


## 目標列的順序。
##
## `lobby_ui._current_step()` **用 z 由大到小當章節順序**——關卡在 z 上是單調的，
## 所以那是對的，但也表示**一個擺錯 z 的機關會靜默打亂整章的提示**：玩家會被
## 叫去做一件他還到不了的事。這裡把「應該的順序」寫死一次當基準。
func _check_objectives() -> void:
	var beats: Array[Node3D] = []
	for group in ["breakables", "log_sockets", "weight_plates", "goal_zones"]:
		for node in get_tree().get_nodes_in_group(group):
			var beat: Node3D = node
			if not String(beat.get("objective")).is_empty():
				beats.append(beat)
	beats.sort_custom(
		func(a: Node3D, b: Node3D) -> bool: return a.global_position.z > b.global_position.z
	)
	var names: Array[String] = []
	for beat in beats:
		names.append(beat.name)
	var wanted: Array[String] = [
		"SeepPlate", "VineWall", "LogSocket", "ShelfPlate", "GoalZone"
	]
	_expect(
		names == wanted,
		"目標列的順序是 %s，應該是 %s（依 z 由大到小）" % [names, wanted]
	)
	for plate in get_tree().get_nodes_in_group("weight_plates"):
		_expect(
			not String(plate.get("objective")).is_empty(),
			"%s 沒有 objective，玩家不會被告知要做什麼" % plate.name
		)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
