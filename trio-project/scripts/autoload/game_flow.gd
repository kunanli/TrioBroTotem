extends Node

## 遊戲流程：開始畫面 → 營地 → 任務關卡（docs/08 的流程圖）。
##
##     Game Start → Server Host & Join → 在營地生成角色
##                → 走到任務看板 → 出發冒險
##
## **不用 change_scene_to_file 換場**，只換 World 底下的子樹。
##
## 理由是連線：整個場景換掉會連 Players 與 MultiplayerSpawner 一起銷毀重建，
## 所有複製關係要重來。更麻煩的是 NodePath——CombatSystem.report_hit 傳的是
## 節點路徑字串（`/root/Main/Players/Player0`），換場之後那些路徑會全部失效。
## 只換世界的話，玩家節點與它們的路徑從頭到尾沒動過。
##
## host 權威（TD-02）：階段由 host 決定並廣播。客戶端不自行換場，
## 否則會出現「有人在營地、有人在關卡」而且誰都不知道發生什麼事。

signal phase_changed(phase: int)

enum Phase { TITLE, CAMP, MISSION }

## 每個階段對應的世界場景。TITLE 沒有世界——開始畫面背後是空的。
const WORLDS := {
	Phase.CAMP: "res://scenes/world/camp.tscn",
	Phase.MISSION: "res://scenes/world/test_arena.tscn",
}

## 通關之後停留幾秒才回營地。要夠久讓大家看到「★ 通關」，
## 又不能久到有人以為卡住了。
const RETURN_DELAY := 4.0

var phase: int = Phase.TITLE

var _return_timer: float = 0.0


func _ready() -> void:
	NetworkService.hosted.connect(_on_online)
	NetworkService.joined.connect(_on_online)
	NetworkService.disconnected.connect(_on_offline)
	NetworkService.peer_joined.connect(_on_peer_joined)


func world_path(value: int) -> String:
	return WORLDS.get(value, "")


func is_in_mission() -> bool:
	return phase == Phase.MISSION


## 英文：這個函式現在只給 print() 用，但名字叫 label，遲早有人把它塞進 UI。
## 到時候不會有人記得回來翻譯。
func phase_label() -> String:
	match phase:
		Phase.CAMP:
			return "Camp"
		Phase.MISSION:
			return "Mission"
		_:
			return "Title"


# --- 階段轉換 ---------------------------------------------------------------

## 連上線就進營地。docs/08 的流程是「Host & Join → 在營地生成角色」，
## 所以連線本身就是進營地的條件，不需要再按一次「開始」。
func _on_online() -> void:
	if NetworkService.is_host():
		_apply_phase.rpc(Phase.CAMP)
	# 客戶端不自己切——等 host 廣播。剛連上時 host 會補送目前的階段
	# （見 _on_peer_joined），中途加入的人才會落在正確的地方。


func _on_offline() -> void:
	_set_phase(Phase.TITLE)


## 中途加入的人要知道現在打到哪了。不補送的話，任務進行中加入的玩家
## 會停在營地，而且畫面上沒有任何線索說明為什麼看不到隊友。
func _on_peer_joined(peer_id: int) -> void:
	if NetworkService.is_host():
		_apply_phase.rpc_id(peer_id, phase)


## 由任務看板呼叫。任何人都可以發起——這是合作遊戲，
## 規定只有房主能開始只會製造「欸你按一下」的等待。
@rpc("any_peer", "call_local", "reliable")
func request_mission() -> void:
	if not NetworkService.is_host() or phase == Phase.MISSION:
		return
	_apply_phase.rpc(Phase.MISSION)


@rpc("any_peer", "call_local", "reliable")
func request_camp() -> void:
	if not NetworkService.is_host() or phase == Phase.CAMP:
		return
	_apply_phase.rpc(Phase.CAMP)


@rpc("authority", "call_local", "reliable")
func _apply_phase(value: int) -> void:
	_set_phase(value)


func _set_phase(value: int) -> void:
	if phase == value:
		return
	phase = value
	_return_timer = 0.0
	print("[Flow] 進入 %s" % phase_label())
	phase_changed.emit(phase)


# --- 通關之後自動回營地 -----------------------------------------------------

## 營地同時是失敗與通關的回歸點（docs/08）。沒有這一段的話，通關之後
## 只能重開遊戲才能再玩一次——測試一輪就結束了。
func _process(delta: float) -> void:
	if phase != Phase.MISSION or not NetworkService.is_host():
		return
	var cleared := false
	for node in get_tree().get_nodes_in_group("goal_zones"):
		var zone: GoalZone = node
		cleared = cleared or zone.is_cleared
	if not cleared:
		_return_timer = 0.0
		return
	_return_timer += delta
	if _return_timer >= RETURN_DELAY:
		request_camp()
