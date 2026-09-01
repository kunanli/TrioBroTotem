extends Node3D

## 第一章的機關真的照規則跑嗎。
##
## `reach_probe` 驗的是靜態的東西（門接得到、門檻抬得動）。這一支驗的是**行為**，
## 而且走真的那條路：真的開一個 host、真的道具、真的玩家、真的物理幀。
##
## 為什麼值得一支獨立的探針：這個機關的四條規則沒有一條看得出來壞了。
## 秤錯重量的板子看起來完全正常，只是永遠踩不開，或者永遠開著；倒地的人
## 還算數的話，一具屍體就能撐著一道門，而那是 goal_zone.gd 早就付過的學費。
##
##     godot --headless --path trio-project res://scenes/tools/beat_probe.tscn

## host 只是為了讓 NetworkService.is_host() 成立，不會有人連進來。
const PROBE_PORT := 45999

## 一秒有幾個物理幀（project.godot：physics_ticks_per_second=120）。
const SECOND := 120

## 驗 AI 時把不相干的角色搬到哪裡去。
const PARK_X := 200.0

## gdlint 的 duplicated-load：同一個場景 load 兩次要收成一個常數。
const PLAYER_SCENE := preload("res://scenes/player/player.tscn")

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
	await _check_pool(world)
	await _check_apple(world)
	_check_ai(world)

	for line in _failures:
		printerr("[Beat] %s" % line)
	print("[Beat] 驗了 17 條規則，%d 條不成立" % _failures.size())
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
	var player: Node3D = PLAYER_SCENE.instantiate()
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


## 毒池：泡著會扣血、走出去就停、**站在池中央那塊石頭上不會扣血**。
##
## 最後那一條是這一輪最容易靜默壞掉的算術：感應區上緣在 y 0.55、墊子頂面在
## 0.7，差 0.15 公尺。把感應區調高兩公分，站在島上踩壓力板的人就會莫名其妙
## 掉血，而且看起來完全正常——毒池就在他腳邊。
func _check_pool(world: Node3D) -> void:
	var slot: int = PlayerRegistry.slots[1].slot_id
	var player: Node3D = _spawn(world, slot, Vector3(15.0, 0.9, 39.0))
	var before := DownSystem.health_of(slot)
	await _wait(SECOND * 2)
	var soaked := before - DownSystem.health_of(slot)
	_expect(
		soaked > 18.0 and soaked < 32.0,
		"泡在毒池裡兩秒掉了 %.1f HP，應該是 24 上下（12 HP／秒）" % soaked
	)

	player.global_position = Vector3(24.0, 0.9, 39.0)
	await _wait(SECOND * 2)
	_expect(
		absf(DownSystem.health_of(slot) - (before - soaked)) < 0.01,
		"走出毒池之後還在掉血：%.1f" % DownSystem.health_of(slot)
	)

	# 池子正中央那塊墊子的頂面在 0.7，蛙的原點在身高一半 0.8。
	player.global_position = Vector3(15.0, 1.5, 35.5)
	var dry := DownSystem.health_of(slot)
	await _wait(SECOND * 2)
	_expect(
		absf(DownSystem.health_of(slot) - dry) < 0.01,
		"站在毒池中央的墊子上還是掉血了（%.1f → %.1f）——感應區比墊子高"
		% [dry, DownSystem.health_of(slot)]
	)

	player.global_position = Vector3(15.0, 0.9, 39.0)
	DownSystem.apply_damage(slot, 999.0, Vector3.ZERO)
	await _wait(SECOND)
	_expect(
		DownSystem.is_downed(slot) and DownSystem.health_of(slot) <= 0.0,
		"倒地的人躺在毒池裡還在被繼續磨"
	)
	player.global_position = Vector3(30.0, 0.9, 39.0)


## 蘋果：回血、夾在上限、滿血的人吃不掉、倒地的人吃不掉。
func _check_apple(world: Node3D) -> void:
	var apple: Node3D = world.get_node("AppleA")
	var spare: Node3D = world.get_node("AppleB")
	var slot: int = PlayerRegistry.slots[2].slot_id
	var player: Node3D = _spawn(world, slot, Vector3(30.0, 0.9, 32.0))

	# 先扣到 50，吃一顆 35 應該變 85——不是 100，也不是 135。
	DownSystem.apply_damage(slot, 50.0, Vector3.ZERO)
	player.global_position = apple.global_position
	await _wait(SECOND)
	_expect(
		absf(DownSystem.health_of(slot) - 85.0) < 0.01,
		"吃了蘋果之後是 %.1f HP，應該是 85" % DownSystem.health_of(slot)
	)
	_expect(bool(apple.get("is_taken")) and not apple.visible, "蘋果吃掉了卻還在那裡")

	# 補到只差 10，第二顆只能補到 100。
	DownSystem.apply_heal(slot, 5.0)
	player.global_position = spare.global_position
	await _wait(SECOND)
	_expect(
		absf(DownSystem.health_of(slot) - DownSystem.MAX_HEALTH) < 0.01,
		"第二顆蘋果把人補到 %.1f，上限是 %.1f" % [
			DownSystem.health_of(slot), DownSystem.MAX_HEALTH
		]
	)

	# 兩顆都吃掉了，換一顆重生的來驗「滿血吃不掉」與「倒地吃不掉」。
	var fresh: Node3D = load("res://scenes/world/apple.tscn").instantiate()
	world.add_child(fresh)
	fresh.global_position = Vector3(30.0, 0.45, 32.0)
	player.global_position = fresh.global_position
	await _wait(SECOND)
	_expect(not bool(fresh.get("is_taken")), "滿血的人把蘋果吃掉了——它應該留在那裡等你")

	DownSystem.apply_damage(slot, 999.0, Vector3.ZERO)
	await _wait(SECOND)
	_expect(
		not bool(fresh.get("is_taken")),
		"倒地的人把蘋果吃掉了——扶起是隊友的工作，不是補給的工作"
	)


## AI 不會自己淹死。
##
## 避讓有三道各自獨立的關卡，所以要分三個場景驗——**把它們湊在同一個場景裡驗，
## 拿掉其中一道也照樣會過**，那就等於沒驗到。實測踩過：只拿掉 think() 那道，
## 十六條規則全綠。
##
## 每一條開始之前先清場（見 `_clear_stage`），否則場上的殘局與會亂走的泥偶
## 會製造假的通過——實測全部踩過一次。
func _check_ai(world: Node3D) -> void:
	var brain := AiBrain.new()
	add_child(brain)
	var intent := PlayerIntent.new()

	# 一、倒在毒池裡的人不會被選為扶起目標，而且 AI 要改去做別的事。
	_clear_stage()
	var helper := _spawn(world, PlayerRegistry.slots[0].slot_id, Vector3(23.5, 0.9, 33.0))
	var fallen := _find_downed()
	if fallen == null:
		_failures.append("探針自己壞了：找不到任何倒地的人可以拿來驗 AI")
		brain.queue_free()
		return
	fallen.global_position = Vector3(15.0, 0.9, 39.0)
	var buddy := _spawn(world, PlayerRegistry.slots[1].slot_id, Vector3(30.0, 0.9, 33.0))
	brain.think(helper, intent)
	var toward := _flat_toward(helper.global_position, fallen.global_position)
	_expect(
		intent.move.dot(toward) < 0.8,
		"AI 往毒池裡的倒地隊友走過去了（move %s）——先拖出來是人類的工作" % intent.move
	)
	# **而且要改去做別的事，不是站著發呆。** `_try_revive` 一旦回報「我在處理
	# 了」，打架與跟隨都會被跳過；避讓寫在它裡面才會往下掉到 `_follow`。
	#
	# 「做了事」要連 attack 一起看：站得夠近的話 `_try_fight` 會原地揮拳、
	# 完全不移動，那也是有在做事。只看 move 的話這一條會在正確的行為上誤報。
	_expect(
		intent.attack or intent.move.length() > 0.5,
		"AI 因為隊友倒在毒池裡就站著不動了（move %s）" % intent.move
	)

	# 二、同一個人躺在乾地上就要去扶。反過來驗一次，避免上面兩條是因為
	#     別的理由才通過的。
	fallen.global_position = Vector3(22.0, 0.9, 30.0)
	brain.think(helper, intent)
	toward = _flat_toward(helper.global_position, fallen.global_position)
	_expect(
		intent.move.dot(toward) > 0.9,
		"倒在乾地上的隊友 AI 也不去扶（move %s）——避讓寫過頭了" % intent.move
	)

	# 三、要跟的人**站在池子裡**時，AI 停在岸邊，不跟進去。
	#     這一條驗的是 think() 那道保險：它蓋的是 _try_fight 與 _follow，
	#     而那兩條路徑 _try_revive 裡的避讓完全管不到。
	#     凹室方圓十五公尺沒有敵人，所以只有跟隨會生效。
	_clear_stage()
	helper.global_position = Vector3(16.0, 0.9, 22.0)
	buddy.global_position = Vector3(22.0, 0.9, 22.0)
	brain.think(helper, intent)
	_expect(
		intent.move.length() < 0.5,
		"要跟的人站在毒池中央，AI 直接跟進去了（move %s）" % intent.move
	)

	# 四、沒事泡在毒池裡就往外走。把人放在旁邊，_follow 就不會產生目的地——
	#     少了這一條，一個站在毒池裡等你的 AI 會安安靜靜地泡到倒。
	helper.global_position = Vector3(24.0, 0.9, 22.0)
	buddy.global_position = Vector3(24.5, 0.9, 22.0)
	brain.think(helper, intent)
	_expect(
		intent.move.x > 0.5,
		"AI 泡在凹室的毒池裡卻不往外走（move %s）" % intent.move
	)
	brain.queue_free()


## 把場上所有玩家與敵人搬到關卡外面，每一條規則自己擺自己要的東西。
##
## **泥偶會自己亂走**（`mud_puppet.gd` 的 WANDER_SPEED 1.2），而這支探針跑到
## 這裡已經模擬了十秒的物理——牠們早就不在關卡檔寫的位置上了。不清場的話
## 「AI 有沒有改去做別的事」這一條會隨著泥偶今天晃到哪裡而時好時壞。
##
## 玩家也要清：前面幾條規則留下了三個倒在各處的角色，其中一個剛好在十一
## 公尺外，AI 跑去扶他，`move.x` 剛好也大於 0.5，於是「泡在池子裡會往外走」
## 這一條在完全沒有實作的情況下通過了。
func _clear_stage() -> void:
	for group in ["player_characters", "enemies"]:
		for node in get_tree().get_nodes_in_group(group):
			var stray: Node3D = node
			stray.global_position = Vector3(PARK_X, 0.9, 0.0)


func _spawn(world: Node3D, slot: int, where: Vector3) -> Node3D:
	var player: Node3D = PLAYER_SCENE.instantiate()
	player.slot_id = slot
	world.add_child(player)
	player.global_position = where
	return player


## 倒地的用**節點上的旗標**判，不要問 DownSystem。
##
## 這支探針會為了不同的規則生出好幾個共用同一個 slot 的角色，而 DownSystem
## 是照 slot 記帳的——問它的話，一個剛生出來、站得好好的角色會被當成倒地。
## `_try_revive` 判的也是節點上的旗標，跟它一致才驗得到同一件事。
func _find_downed() -> Node3D:
	for node in get_tree().get_nodes_in_group("player_characters"):
		var player: Node3D = node
		if bool(player.get("is_downed")):
			return player
	return null


func _flat_toward(from: Vector3, to: Vector3) -> Vector2:
	var offset := to - from
	return Vector2(offset.x, offset.z).normalized()


func _wait(frames: int) -> void:
	for _index in frames:
		await get_tree().physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
