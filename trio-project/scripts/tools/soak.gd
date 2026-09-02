extends Node

## 兩個 peer 真的跑一趟，然後把狀態拍成指紋。
##
## 這是這個專案**第一次同時跑兩個 peer**。README 的進度表從第一天起就寫著
## 「已寫，未在引擎驗證」，而 TD-10 的延遲驗收是空的 ⬜——不是因為做不到，
## 是因為沒有人按下去。`LagPeer` 早就寫好了、`main.gd` 早就吃 `--lag=`，
## 缺的只有「跑完之後拿什麼跟什麼比」。
##
## 用法（由 tools/netplay_test.py 驅動）：
##
##     godot --headless --path trio-project -- --host --soak=20 --dump=/tmp/host.json
##     godot --headless --path trio-project -- --join=127.0.0.1 --soak=20 --dump=/tmp/client.json
##
## host 會走 GameFlow.request_mission（跟任務看板同一條路）進第一章，跑滿指定
## 秒數，兩端各自把**同一組欄位**寫成 JSON。比對的事交給 Python。
##
## **這一支不進正式版**：export_presets.cfg 排除了 scripts/tools/*。

## 最多等多久等客戶端連上來。等到人就馬上出發，不會等滿。
const CONNECT_TIMEOUT := 12.0

## 出任務之後再等多久才開始計時。世界要載、同步器要跑幾輪。
const SETTLE := 1.0

var _seconds := 0.0
var _linger := 0.0
var _dump := ""
var _clock := 0.0
var _started := false
var _started_at := 0.0
var _sampled := false
var _poked := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	for arg in args:
		if arg.begins_with("--soak="):
			_seconds = float(arg.split("=", true, 1)[1])
		elif arg.begins_with("--dump="):
			_dump = arg.split("=", true, 1)[1]
		elif arg.begins_with("--linger="):
			_linger = float(arg.split("=", true, 1)[1])
	print("[Soak] 起跑：%.0f 秒，指紋寫到 %s" % [_seconds, _dump])


func _process(delta: float) -> void:
	_clock += delta
	if not _started:
		# **一定要等客戶端連上來才出發。**
		#
		# GameFlow 只在階段**改變**的時候廣播，所以晚一步連進來的人永遠停在
		# 開始畫面：世界是空的、一個角色都沒有，而且不會有任何錯誤訊息。
		# 第一版是「host 等固定兩秒就出發」，而客戶端要三秒才連上——
		# 於是兩端的指紋一個有十二拍、一個是空的。
		var ready_to_go := multiplayer.get_peers().size() > 0
		if not (ready_to_go or _clock >= CONNECT_TIMEOUT):
			return
		_started = true
		_started_at = _clock
		print("[Soak] %s：%.1f 秒時出發（對面 %d 個 peer）" % [
			"host" if NetworkService.is_host() else "client",
			_clock, multiplayer.get_peers().size()
		])
		# 出任務的決定一律送給 host（跟任務看板同一條路）。
		if NetworkService.is_host():
			GameFlow.request_mission.rpc_id(1)
		return
	# **拍照與收工要分開。**
	#
	# 兩端必須在**同一個時刻**拍照，否則場上還在動的 AI 當然對不起來——
	# 實測 host 晚五秒拍，一個角色就差了 3.7 公尺，看起來像同步壞掉，
	# 其實只是兩張照片差了五秒。而 host 又必須活得比客戶端久（它先走的話，
	# 客戶端會被踢回開始畫面、世界拆光，然後才拍到一張空的）。
	# 所以：同時拍，host 拍完再多待一會兒。
	# 半途讓 host 動幾個狀態出來。
	#
	# **不動的話這個比對幾乎沒有價值**：十二拍全部停在初始值，兩端當然一樣，
	# 那只證明「兩邊都載了同一個場景檔」。要證明的是複製真的有在跑，
	# 所以 host 打破藤蔓牆、把木箱放上壓力板，然後看客戶端有沒有跟上。
	if not _poked and _clock >= _started_at + SETTLE + _seconds * 0.5:
		_poked = true
		if NetworkService.is_host():
			_poke()
	if not _sampled and _clock >= _started_at + SETTLE + _seconds:
		_sampled = true
		_write()
	if _sampled and _clock >= _started_at + SETTLE + _seconds + _linger:
		get_tree().quit(0)


## host 半途動幾個狀態，看客戶端跟不跟得上。
func _poke() -> void:
	for node in get_tree().get_nodes_in_group("breakables"):
		var wall: Node3D = node
		if wall.name == "VineWall":
			wall.take_hit(999.0, Vector3.ZERO)
	for node in get_tree().get_nodes_in_group("weight_plates"):
		var plate: Node3D = node
		if plate.name != "ShelfPlate":
			continue
		for prop in get_tree().get_nodes_in_group("props"):
			var crate: Node3D = prop
			if crate.name != "BankCrate":
				continue
			crate.global_position = plate.global_position + Vector3(0.0, 0.6, 0.0)
			crate.set("linear_velocity", Vector3.ZERO)
			crate.set("net_position", crate.global_position)
	print("[Soak] host 動了兩個狀態：打破藤蔓牆、把木箱放上遠岸的壓力板")


## 狀態指紋。**兩端要看同一組欄位**，否則比對沒有意義。
##
## 只收「應該一致」的東西：複製過的旗標與數值、以及角色的 slot 與血量。
## 位置給 Python 那邊容差——那是 20 Hz 插值出來的，本來就不會逐位元組相同。
func _write() -> void:
	var world := get_tree().get_first_node_in_group("scenery")
	var state := {
		"peer": "host" if NetworkService.is_host() else "client",
		"beats": {},
		"players": {},
	}
	for group in ["breakables", "log_sockets", "weight_plates", "goal_zones", "pickups"]:
		for node in get_tree().get_nodes_in_group(group):
			var beat: Node3D = node
			state["beats"][String(beat.name)] = _beat_state(group, beat)
	for node in get_tree().get_nodes_in_group("player_characters"):
		var player: Node3D = node
		var slot := int(player.get("slot_id"))
		state["players"][str(slot)] = {
			"health": DownSystem.health_of(slot),
			"downed": DownSystem.is_downed(slot),
			"position": [player.global_position.x, player.global_position.y, player.global_position.z],
		}
	state["world"] = "" if world == null else String(world.get("level_id"))
	var file := FileAccess.open(_dump, FileAccess.WRITE)
	if file == null:
		printerr("[Soak] 寫不進 %s" % _dump)
		return
	file.store_string(JSON.stringify(state, "\t"))
	file.close()
	print("[Soak] 收工：%d 拍、%d 個角色" % [state["beats"].size(), state["players"].size()])


func _beat_state(group: String, beat: Node3D) -> Dictionary:
	match group:
		"breakables":
			return {"broken": bool(beat.get("is_broken")), "health": float(beat.get("health"))}
		"log_sockets":
			return {"bridged": bool(beat.get("is_bridged"))}
		"weight_plates":
			return {"open": bool(beat.get("is_open")), "load": float(beat.get("load_weight"))}
		"goal_zones":
			return {"cleared": bool(beat.get("is_cleared"))}
		"pickups":
			return {"taken": bool(beat.get("is_taken"))}
	return {}
