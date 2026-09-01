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

## 這一拍在目標列上的文字。**空字串＝支線，不進主線。**
##
## 文字寫在關卡檔而不是這裡：每一拍要講的那句話是關卡設計，不是這個元件的行為。
## 型別必須是 String 不是 StringName——godot-parser 解析不了 `.tscn` 裡的
## `&"foo"`，而 check_project.py 會整檔解析每一個場景。
@export var objective: String = ""

var health: float = 0.0
var is_broken: bool = false

var _applied := false

## 每一片網格原本的底部高度（本節點座標系）。壓扁之後要讓底部留在原地。
var _mesh_floor: Dictionary = {}


func _ready() -> void:
	add_to_group("breakables")
	for child in get_children():
		var mesh := child as MeshInstance3D
		if mesh != null:
			# 壓扁前先記下底部在哪（本節點的座標系）。
			_mesh_floor[mesh.get_instance_id()] = mesh.position.y + mesh.get_aabb().position.y
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
	Sfx.play(&"shatter", global_position, 0.8)
	Vfx.burst(&"shatter", global_position, Vector3.BACK, 2.0)
	# 整個層清掉：擋路的那一位（1）與被攻擊判定看得到的那一位（4）都要拿掉，
	# 只清擋路的話殘骸還會一直吃到攻擊。
	collision_layer = 0
	for child in get_children():
		var mesh := child as MeshInstance3D
		if mesh != null:
			# 壓扁之後把底部放回原來的位置。
			#
			# 舊版是 `position.y -= 0.5` 這個硬寫的數字：4 公尺高的網格壓成 0.18
			# 只剩 0.72 高，位置卻只降 0.5，殘骸就卡在半空（實測浮在 1.14 公尺）。
			# 牆改成 8 公尺之後那個數字錯得更多。改成從網格自己的外框算。
			var box := mesh.get_aabb()
			var bottom: float = _mesh_floor.get(mesh.get_instance_id(), 0.0)
			mesh.scale = Vector3(1.0, RUBBLE_SCALE, 1.0)
			mesh.position.y = bottom - box.position.y * RUBBLE_SCALE

## 這一拍完成了嗎。lobby_ui 靠它決定目標列要顯示哪一句，不必認得每一種型別。
func objective_done() -> bool:
	return is_broken
