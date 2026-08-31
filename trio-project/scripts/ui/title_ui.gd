extends CanvasLayer

## 開始畫面（docs/08 流程的第一格：Game Start → Server Host & Join）。
##
## 連線的控制全部收在這裡，遊戲中的面板就不必再擺一次開房／加入按鈕——
## 那些按鈕在遊戲進行中按下去只會製造意外。連上線之後這一層整個隱藏，
## 斷線時再出現。
##
## 整個介面用程式碼建。M0 的 UI 是拋棄式的（正式的見 docs/06），
## 不值得為它維護 .tscn。

## 網路模擬的檔位。中間兩檔正好涵蓋 TD-10 要求的 80–150 ms、1% 丟包。
## 「區網」那一檔不是為了測驗收，是為了讓人先在寬鬆條件下確認操作沒問題。
const NETWORK_PRESETS := [
	{"label": "直連（不模擬）", "latency": 0.0, "loss": 0.0},
	{"label": "區網 20 ms", "latency": 20.0, "loss": 0.0},
	{"label": "一般 80 ms／1%（驗收）", "latency": 80.0, "loss": 0.01},
	{"label": "惡劣 150 ms／3%", "latency": 150.0, "loss": 0.03},
]

var _root: Control
var _status: Label
var _name: LineEdit
var _address: LineEdit
var _network: OptionButton


func _ready() -> void:
	layer = 2  # 蓋在遊戲面板上面
	_build()
	NetworkService.join_failed.connect(_on_join_failed)
	GameFlow.phase_changed.connect(_on_phase_changed)
	_on_phase_changed(GameFlow.phase)


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.06, 0.07, 0.09)
	_root.add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var title := Label.new()
	title.text = "TrioBroTotem"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	box.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "三人合作冒險　·　M0 技術驗證"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(subtitle)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_status)

	# 名字要能自己填。預設是 Player-483 這種亂數，回報問題時
	# 「Player-483 疊在我身上」對誰都沒有意義。
	_name = LineEdit.new()
	_name.text = PlayerRegistry.local_display_name
	_name.placeholder_text = "你的名字"
	_name.max_length = 12
	box.add_child(_name)

	var host_button := Button.new()
	host_button.text = "開一個房間（當房主）"
	host_button.pressed.connect(_on_host_pressed)
	box.add_child(host_button)

	var join_row := HBoxContainer.new()
	box.add_child(join_row)

	_address = LineEdit.new()
	_address.text = NetworkService.DEFAULT_ADDRESS
	_address.placeholder_text = "房主的位址"
	_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_row.add_child(_address)

	var join_button := Button.new()
	join_button.text = "加入"
	join_button.pressed.connect(_on_join_pressed)
	join_row.add_child(join_button)

	# 網路模擬要在開房／加入之前選好——連線建立之後才改不會生效，
	# 所以這個選項只出現在開始畫面。
	_network = OptionButton.new()
	for preset in NETWORK_PRESETS:
		_network.add_item("網路：" + String(preset["label"]))
	_network.item_selected.connect(_on_network_selected)
	box.add_child(_network)

	var hint := Label.new()
	hint.text = (
		"一個人按「開一個房間」，其他人填他的位址按「加入」。\n"
		+ "湊不到三個人也能玩，空位會由電腦補上。\n"
		+ "連上之後會一起出現在營地，走到任務看板前出發。"
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)


## 開始畫面顯示與否完全跟著階段走，不自己判斷連線狀態——
## 兩套判斷遲早會不一致，而不一致的症狀是「選單蓋在遊戲上」。
func _on_phase_changed(phase: int) -> void:
	var at_title := phase == GameFlow.Phase.TITLE
	_root.visible = at_title
	if at_title:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh_status()


func _refresh_status() -> void:
	if not NetworkService.last_error.is_empty():
		_status.text = "連不上：" + NetworkService.last_error
	else:
		_status.text = ""


func _on_host_pressed() -> void:
	_commit_name()
	NetworkService.host_game()


func _on_join_pressed() -> void:
	_commit_name()
	NetworkService.join_game(_address.text)


## 名字要在連線之前定案——PlayerRegistry 是在開房／報到的當下讀它的。
func _commit_name() -> void:
	var wanted := _name.text.strip_edges()
	if not wanted.is_empty():
		PlayerRegistry.local_display_name = wanted


func _on_network_selected(index: int) -> void:
	var preset: Dictionary = NETWORK_PRESETS[index]
	NetworkService.sim_latency_ms = float(preset["latency"])
	NetworkService.sim_loss = float(preset["loss"])


func _on_join_failed(_reason: String) -> void:
	_refresh_status()
