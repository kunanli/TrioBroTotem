extends CanvasLayer

## 遊戲中的面板。**不是** HUD——正式 HUD 見 docs/06-controls-ui.md，
## 那一套要等 M1 才做，而且會受分屏約束（能放世界空間就不放螢幕空間）。
##
## 連線的控制不在這裡，在開始畫面（title_ui.gd）。遊戲進行中不該還有
## 「開房／加入」按鈕——那些按鈕在遊戲中按下去只會製造意外。
##
## 整個介面用程式碼建，因為它是拋棄式的工具，不值得為它維護一份 .tscn。

## 三層疊高要維持多久才算通過 M0（docs/11、TD-10）。
const STACK_TARGET := 30.0

var _root: Control
var _status: Label
var _objective: Label
var _slots: Label
var _stack_best: float = 0.0
var _stack_now: float = 0.0
var _leave_button: Button


func _ready() -> void:
	_build()
	NetworkService.hosted.connect(_refresh)
	NetworkService.joined.connect(_refresh)
	NetworkService.disconnected.connect(_refresh)
	PlayerRegistry.slots_changed.connect(_refresh)
	GameFlow.phase_changed.connect(_on_phase_changed)
	_on_phase_changed(GameFlow.phase)
	_refresh()


## 只在遊戲中顯示。開始畫面自己有一整頁，這一層蓋上去會很亂。
func _on_phase_changed(phase: int) -> void:
	if _root != null:
		_root.visible = phase != GameFlow.Phase.TITLE
	_refresh()


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(12, 12)
	panel.custom_minimum_size = Vector2(300, 0)
	_root.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)


	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	_objective = Label.new()
	_objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_objective)

	_leave_button = Button.new()
	_leave_button.text = "Leave room"
	_leave_button.pressed.connect(_on_leave_pressed)
	box.add_child(_leave_button)

	_slots = Label.new()
	_slots.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_slots)

	var hint := Label.new()
	hint.text = (
		"WASD move  |  Space jump  |  Tab toggle mouse look\n"
		+ "F grab / drop  |  while holding, hold attack to charge, release to throw\n"
		+ "J or left mouse  attack (tap three times for the combo)\n"
		+ "E interact / hold to revive a downed teammate  |  walk onto a teammate to stack\n"
		+ "R respawn if you get stuck"
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(hint)

	panel.reset_size()


func _on_leave_pressed() -> void:
	NetworkService.leave()


## Tab 切換滑鼠鎖定。
##
## 原本轉視角要一直按著滑鼠右鍵，玩一小時手會廢。鎖定之後移動滑鼠就是轉視角，
## 但那樣按不到大廳的按鈕，所以要能切回來。切換前先放掉輸入框的焦點，
## 否則 Tab 會被當成「跳到下一個欄位」。
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and event.keycode == KEY_TAB):
		return
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if captured else Input.MOUSE_MODE_CAPTURED
	get_viewport().set_input_as_handled()


## 疊高計時是 M0 的驗收數字（TD-10：三人疊高走動 30 秒）。
## 測試時自動量，不必有人拿碼錶。
func _process(delta: float) -> void:
	var tallest := 0
	for slot in PlayerRegistry.slots:
		var height := 1
		var below := StackSystem.below_of(slot.slot_id)
		while below >= 0:
			height += 1
			below = StackSystem.below_of(below)
		tallest = maxi(tallest, height)
	if tallest >= 3:
		_stack_now += delta
		_stack_best = maxf(_stack_best, _stack_now)
	else:
		_stack_now = 0.0
	_refresh_objective()


## 目標跟著階段與關卡的段落走（docs/07 第一章）。
##
## 只寫最終目標的話，玩家在藤蔓前面卡住時看到的是「站上北邊的高台」——
## 那不是他現在該解的問題。一次只講一件事。
func _current_step() -> String:
	if not GameFlow.is_in_mission():
		return (
			"Practise anything in camp. When you are ready, walk to the\n"
			+ "mission board to the north and press E to set out."
		)
	for node in get_tree().get_nodes_in_group("breakables"):
		if not node.is_broken:
			return "Break the vines blocking the way (attacks work on scenery too)"
	for node in get_tree().get_nodes_in_group("log_sockets"):
		if not node.is_bridged:
			return (
				"Bridge the ravine with the log on the stump\n"
				+ "(the pig can carry it alone, or the frog and cat together)"
			)
	return "Reach the platform to the north (3.6 m — a two-high stack still falls short)"


func _refresh_objective() -> void:
	if _objective == null:
		return
	var lines: Array[String] = []
	var cleared := false
	for node in get_tree().get_nodes_in_group("goal_zones"):
		var zone: GoalZone = node
		cleared = cleared or zone.is_cleared
	if cleared:
		# 不寫倒數秒數：倒數只在 host 端跑（見 game_flow.gd 的 _process），
		# 客戶端顯示的數字會是假的。寧可不給數字也不要給錯的。
		lines.append("Returning to camp...")
		# 通關之後給第二個目標，否則星星亮了就沒事做了。
		# 這一項才是 M0 真正的驗收標準（TD-10）。
		if _stack_best >= STACK_TARGET:
			lines.append("**  All done — cleared, and held a three-high stack for %.0f s" % STACK_TARGET)
		else:
			lines.append("*  Cleared. Next: walk with a three-high stack for %.0f s" % STACK_TARGET)
	else:
		lines.append("Objective: %s" % _current_step())
	# 驗收句子要自帶條件。只寫「撐了 34 秒」沒有意義——TD-10 要的是
	# 「在 80 ms、1% 丟包之下撐了 34 秒」。截圖存證時這一行就是證明。
	var condition := NetworkService.simulation_label()
	lines.append(
		"Stack timer: now %.1f s  |  best %.1f / %.0f s   (%s)"
		% [
			_stack_now,
			_stack_best,
			STACK_TARGET,
			condition if not condition.is_empty() else "no network simulation",
		]
	)
	if NetworkService.is_host():
		var addresses := NetworkService.local_addresses()
		if not addresses.is_empty():
			lines.append("Tell your friends to join: %s" % addresses[0])
	_objective.text = "\n".join(lines)


func _refresh() -> void:
	_refresh_objective()
	_leave_button.disabled = not NetworkService.is_online()

	# 用 if/elif 而不是 match：autoload 上的 enum 成員不是常數運算式，
	# 當 match 的 pattern 會被剖析器拒絕。
	if NetworkService.mode == NetworkService.Mode.HOST:
		_status.text = "HOST (peer %d)" % NetworkService.local_peer_id()
	elif NetworkService.mode == NetworkService.Mode.CLIENT:
		_status.text = "CLIENT (peer %d)" % NetworkService.local_peer_id()
	else:
		_status.text = "Offline"
		if not NetworkService.last_error.is_empty():
			_status.text += " — " + NetworkService.last_error

	var lines: Array[String] = []
	for slot in PlayerRegistry.slots:
		var mark := "  <- you" if slot.peer_id == NetworkService.local_peer_id() else ""
		var state := ""
		if DownSystem.is_downed(slot.slot_id):
			state = "  (down)"
		elif StackSystem.is_stacked(slot.slot_id):
			state = "  (stacked on slot %d)" % StackSystem.below_of(slot.slot_id)
		lines.append("slot %d  %s%s  %.0f HP%s" % [
			slot.slot_id, slot.display_name, mark,
			DownSystem.health_of(slot.slot_id), state
		])
	_slots.text = "Team (%d/%d)\n%s" % [
		PlayerRegistry.slots.size(), PlayerSlot.MAX_SLOTS, "\n".join(lines)
	]
