extends CanvasLayer

## M0 的開發用連線面板。**不是** HUD——正式 HUD 見 docs/06-controls-ui.md，
## 那一套要等 M1 才做，而且會受分屏約束（能放世界空間就不放螢幕空間）。
##
## 整個介面用程式碼建，因為它是拋棄式的工具，不值得為它維護一份 .tscn。

## 三層疊高要維持多久才算通過 M0（docs/11、TD-10）。
const STACK_TARGET := 30.0

var _status: Label
var _objective: Label
var _slots: Label
var _stack_best: float = 0.0
var _stack_now: float = 0.0
var _address: LineEdit
var _host_button: Button
var _join_button: Button
var _leave_button: Button


func _ready() -> void:
	_build()
	NetworkService.hosted.connect(_refresh)
	NetworkService.joined.connect(_refresh)
	NetworkService.disconnected.connect(_refresh)
	NetworkService.join_failed.connect(_on_join_failed)
	PlayerRegistry.slots_changed.connect(_refresh)
	_refresh()


func _build() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(12, 12)
	panel.custom_minimum_size = Vector2(300, 0)
	add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var title := Label.new()
	title.text = "TrioBroTotem — M0 連線測試"
	box.add_child(title)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	_objective = Label.new()
	_objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_objective)

	_address = LineEdit.new()
	_address.text = NetworkService.DEFAULT_ADDRESS
	_address.placeholder_text = "host 位址"
	box.add_child(_address)

	var buttons := HBoxContainer.new()
	box.add_child(buttons)

	_host_button = Button.new()
	_host_button.text = "開房"
	_host_button.pressed.connect(_on_host_pressed)
	buttons.add_child(_host_button)

	_join_button = Button.new()
	_join_button.text = "加入"
	_join_button.pressed.connect(_on_join_pressed)
	buttons.add_child(_join_button)

	_leave_button = Button.new()
	_leave_button.text = "離開"
	_leave_button.pressed.connect(_on_leave_pressed)
	buttons.add_child(_leave_button)

	_slots = Label.new()
	_slots.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_slots)

	var hint := Label.new()
	hint.text = (
		"WASD 移動｜滑鼠右鍵拖曳轉鏡頭｜空白鍵跳\n"
		+ "E 抓起／放下｜按住 F 蓄力，放開投擲\n"
		+ "滑鼠左鍵攻擊（連按三下接連擊）｜走到隊友身上疊高\n"
		+ "按住 E 靠近倒地的隊友＝扶起"
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(hint)

	panel.reset_size()


func _on_host_pressed() -> void:
	NetworkService.host_game()


func _on_join_pressed() -> void:
	NetworkService.join_game(_address.text)


func _on_leave_pressed() -> void:
	NetworkService.leave()


func _on_join_failed(_reason: String) -> void:
	_refresh()


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


func _refresh_objective() -> void:
	if _objective == null:
		return
	var lines: Array[String] = []
	var cleared := false
	for node in get_tree().get_nodes_in_group("goal_zones"):
		var zone: GoalZone = node
		cleared = cleared or zone.is_cleared
	if cleared:
		lines.append("★ 已通關——有人站上高台了")
	else:
		lines.append("目標：想辦法站上北邊的高台（3.6 公尺，跳不上去）")
	lines.append(
		"疊高計時：現在 %.1f 秒｜最久 %.1f / %.0f 秒"
		% [_stack_now, _stack_best, STACK_TARGET]
	)
	if NetworkService.is_host():
		var addresses := NetworkService.local_addresses()
		if not addresses.is_empty():
			lines.append("叫朋友連：%s" % addresses[0])
	_objective.text = "\n".join(lines)


func _refresh() -> void:
	_refresh_objective()
	var online := NetworkService.is_online()
	_host_button.disabled = online
	_join_button.disabled = online
	_leave_button.disabled = not online
	_address.editable = not online

	# 用 if/elif 而不是 match：autoload 上的 enum 成員不是常數運算式，
	# 當 match 的 pattern 會被剖析器拒絕。
	if NetworkService.mode == NetworkService.Mode.HOST:
		_status.text = "HOST（peer %d）" % NetworkService.local_peer_id()
	elif NetworkService.mode == NetworkService.Mode.CLIENT:
		_status.text = "CLIENT（peer %d）" % NetworkService.local_peer_id()
	else:
		_status.text = "離線"
		if not NetworkService.last_error.is_empty():
			_status.text += " — " + NetworkService.last_error

	var lines: Array[String] = []
	for slot in PlayerRegistry.slots:
		var mark := " ←你" if slot.peer_id == NetworkService.local_peer_id() else ""
		var state := ""
		if DownSystem.is_downed(slot.slot_id):
			state = "（倒地）"
		elif StackSystem.is_stacked(slot.slot_id):
			state = "（疊在 slot %d 上）" % StackSystem.below_of(slot.slot_id)
		lines.append("slot %d｜%s%s %.0f 血%s" % [
			slot.slot_id, slot.display_name, mark,
			DownSystem.health_of(slot.slot_id), state
		])
	_slots.text = "隊伍（%d/%d）\n%s" % [
		PlayerRegistry.slots.size(), PlayerSlot.MAX_SLOTS, "\n".join(lines)
	]
