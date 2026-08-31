class_name Breakable
extends StaticBody3D

## 可破壞的擋路物（docs/07 第一章的藤蔓）。
##
## 教學責任：教玩家「攻擊可以用在場景上」，而不只是打敵人。所以它擋住唯一的
## 通道——不打就過不去，不需要任何文字說明。
##
## host 權威（TD-02）：只有 host 算血量，狀態透過 MultiplayerSynchronizer 廣播。
## 沿用 mud_puppet.gd 已經驗證過的那一套，包含它踩過的坑：
## **場景擺好的節點不是 MultiplayerSpawner 生成的，host 呼叫 queue_free()
## 不會複製到客戶端**，結果是 host 看到消失、客戶端還擋在那裡。
## 所以是逐端把碰撞與顯示關掉，不刪節點。

const SYNC_HZ := 10.0

## 每一段的碰撞形狀縮到多小才算「破了」。不是直接消失——留一點殘骸比較好看，
## 也讓玩家看得出「這裡本來有東西」。
const RUBBLE_SCALE := 0.18

@export var max_health: float = 40.0

var health: float = 0.0
var is_broken: bool = false

var _applied := false


func _ready() -> void:
	add_to_group("breakables")
	health = max_health
	_setup_synchronizer()
	set_multiplayer_authority(1)


func _setup_synchronizer() -> void:
	var config := SceneReplicationConfig.new()
	for property in [".:health", ".:is_broken"]:
		var path := NodePath(property)
		config.add_property(path)
		config.property_set_spawn(path, false)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	var sync := MultiplayerSynchronizer.new()
	sync.name = "Synchronizer"
	sync.replication_config = config
	sync.replication_interval = 1.0 / SYNC_HZ
	add_child(sync)


## 攻擊系統只認得 combat_kind() 與 take_hit()，所以藤蔓跟泥偶走同一條路徑。
func combat_kind() -> StringName:
	return &"mud_puppet"


func take_hit(damage: float, _impulse: Vector3) -> void:
	if is_broken or not NetworkService.is_host():
		return
	health = maxf(health - damage, 0.0)
	if health <= 0.0:
		is_broken = true


func _process(_delta: float) -> void:
	# 每一端各自套用，不靠 RPC——is_broken 是同步欄位，
	# 客戶端讀到它變 true 的那一刻就自己收起來。
	if is_broken and not _applied:
		_applied = true
		_collapse()


func _collapse() -> void:
	Sfx.play(&"hit", global_position, 0.7)
	# 整個層清掉：擋路的那一位（1）與被攻擊判定看得到的那一位（4）都要拿掉，
	# 只清擋路的話殘骸還會一直吃到攻擊。
	collision_layer = 0
	for child in get_children():
		var mesh := child as MeshInstance3D
		if mesh != null:
			mesh.scale = Vector3(1.0, RUBBLE_SCALE, 1.0)
			mesh.position.y -= 0.5
