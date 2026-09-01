class_name Pickup
extends Area3D

## 場景補給（docs/04 治療系統的第二層）。走過去就撿起來。
##
## host 權威（TD-02）：只有 host 判定誰吃到，狀態同步，每一端自己把它收起來。
## **絕不 queue_free**——場景擺好的節點不是 MultiplayerSpawner 生成的，
## host 刪掉不會複製到客戶端，結果是 host 看到消失、客戶端還飄著一顆。
##
## ## 兩條比看起來重要的規則
##
##  - **滿血時吃不掉**，就放在那裡等你。這正是「補給要放在危險**之前**」能夠
##    成立的理由：你會先看到它、發現吃不掉、於是知道等一下會用到它。
##    可以吃掉滿血的人的補給等於逼玩家先扣自己一下血，那是很蠢的最佳解。
##  - **扶不起倒地的人。** 血量歸零不能自行復活，扶起是隊友的工作（docs/04）。
##    補給要是能救倒地的人，救援系統就會被繞過去。

const SYNC_HZ := 10.0

## 浮動與自轉。一顆不動的球讀作石頭，會動的才讀作「可以撿」。
const BOB_HEIGHT := 0.12
const BOB_SPEED := 2.1
const SPIN_SPEED := 1.3

## 回多少血。**跟 DownSystem.REVIVE_HEAL 同一個數字，而且是刻意的**：
## 全遊戲「一次回血」只有一個量，玩家不必分別記兩個。
@export var heal: float = 35.0

var is_taken: bool = false

var _applied := false
var _clock := 0.0
var _home_y: float = 0.0


func _ready() -> void:
	add_to_group("pickups")
	_home_y = position.y
	_setup_synchronizer()
	set_multiplayer_authority(1)


func _setup_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	var path := NodePath(".:is_taken")
	config.add_property(path)
	config.property_set_spawn(path, false)
	config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	var sync := MultiplayerSynchronizer.new()
	sync.name = "Synchronizer"
	sync.replication_config = config
	sync.replication_interval = 1.0 / SYNC_HZ
	add_child(sync)


func _process(delta: float) -> void:
	# 每一端各自套用——is_taken 是同步欄位，客戶端讀到它變 true 的那一刻
	# 就自己把蘋果收起來，不必額外的 RPC。
	if is_taken:
		if not _applied:
			_applied = true
			_vanish()
		return
	_clock += delta
	position.y = _home_y + sin(_clock * BOB_SPEED) * BOB_HEIGHT
	rotate_y(SPIN_SPEED * delta)


func _physics_process(_delta: float) -> void:
	if is_taken or not NetworkService.is_host():
		return
	for body in get_overlapping_bodies():
		if not body.is_in_group("player_characters"):
			continue
		var slot := int(body.get("slot_id"))
		if DownSystem.is_downed(slot):
			continue
		if DownSystem.health_of(slot) >= DownSystem.MAX_HEALTH:
			continue
		DownSystem.apply_heal(slot, heal)
		is_taken = true
		return


## 收起來而不是刪除。monitoring 要 set_deferred——在物理回呼裡直接改
## Area3D 的監聽狀態，Godot 會擋下來。
func _vanish() -> void:
	Sfx.play(&"revive", global_position, 1.3)
	Vfx.burst(&"hit_spark", global_position, Vector3.UP, 0.8)
	visible = false
	set_deferred(&"monitoring", false)
