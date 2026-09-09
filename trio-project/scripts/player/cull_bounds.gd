class_name CullBounds
extends RefCounted

## 壞掉的匯出檔會讓角色被視錐剔除或 LOD 畫成空的；這裡替它加保險。
## 從 `character_visual.gd` 搬出來的，內容沒改——那支檔案超過 1000 行了。

## 修正蒙皮網格的剔除範圍。
##
## 這是「角色明明是 1.6 公尺卻整個不畫」的真正原因。
##
## 匯出檔把頂點寫在 1/100 的尺度，再用 100 倍的 inverse bind 矩陣補回來
## （實測：頂點外框 0.0150、bind_pose 尺度 100、蒙皮後 1.5046）。這在 glTF 裡
## 合法，但 Godot 拿來做視錐剔除的是 mesh.get_aabb()，也就是**沒有蒙皮**的原始
## 頂點範圍——比真正的幾何小 100 倍。引擎因此以為那是一個 1.6 公分的東西，
## 鏡頭一移動、那個小盒子離開視錐，整隻角色就消失，而且不會有任何錯誤訊息。
##
## 用骨骼靜置範圍算出真實外框並明寫 custom_aabb。留 60% 餘裕給舉手過頭之類
## 超出靜置姿勢的動作。重跑美術管線把頂點寫回正常尺度之後，這一段會算出
## 幾乎一樣的結果，留著也不會有壞處。
static func fix(skeleton: Skeleton3D, character_id: String, target_height: float) -> void:
	if skeleton == null:
		return
	var low := Vector3(INF, INF, INF)
	var high := -low
	for index in skeleton.get_bone_count():
		var point := skeleton.get_bone_global_rest(index).origin
		low = Vector3(minf(low.x, point.x), minf(low.y, point.y), minf(low.z, point.z))
		high = Vector3(maxf(high.x, point.x), maxf(high.y, point.y), maxf(high.z, point.z))
	if not (high.y > low.y):
		return

	# 資產正常時網格外框本來就跟角色一樣大，不需要補救。
	# 只有壞掉的匯出檔（頂點寫在 1/100 的尺度、用 100 倍的 inverse bind 補回來）
	# 才會出現「剖面盒比幾何體小 100 倍」，那時角色會被剔除或被 LOD 畫成空的。
	var mesh_height := 0.0
	for node in skeleton.find_children("*", "MeshInstance3D", true, false):
		mesh_height = maxf(mesh_height, (node as MeshInstance3D).get_aabb().size.y)
	if mesh_height > (high.y - low.y) * 0.5:
		return
	push_warning(
		"[Visual] %s 的網格外框只有 %.4f，骨架卻有 %.4f——剖面盒對不上幾何體，"
		% [character_id, mesh_height, high.y - low.y]
		+ "已加保險。正解是重跑美術管線：python tools/run_blender.py normalize-all"
	)
	var centre := (low + high) * 0.5
	var size := (high - low) * 1.6
	size = Vector3(maxf(size.x, size.y * 0.8), size.y, maxf(size.z, size.y * 0.8))

	for node in skeleton.find_children("*", "MeshInstance3D", true, false):
		var mesh: MeshInstance3D = node
		if mesh.skin == null:
			continue
		# custom_aabb 是網格自己的區域座標；網格掛在骨架底下，換算過去。
		var to_local := mesh.transform.affine_inverse()
		mesh.custom_aabb = AABB(to_local * (centre - size * 0.5), size)
		# 剖面盒同時也是 LOD 的依據：1.6 公分的盒子在 5 公尺外，引擎算出來的
		# 螢幕佔比幾乎是 0，會挑最粗的 LOD——粗到可能一個三角形都不畫。
		# 視錐剔除只有整個盒子離開畫面才會生效，LOD 卻是「在畫面裡但畫成空的」，
		# 更符合「標籤看得到、人看不到」的症狀。兩個都堵起來。
		mesh.lod_bias = 128.0
		# 真正有效的那一個。custom_aabb 蓋不掉——骨架掛上去之後，引擎每幀會從
		# 骨骼的外框重算實例的剖面盒，把我們設的值覆蓋掉。extra_cull_margin 是
		# 加在「重算之後」的結果上，所以蓋得住，也正是 Godot 文件給這個情況
		# （網格被骨架變形到超出自己的 AABB）開的藥。
		#
		# 實測（重跑正規化之後的資產）：幾何體 1.6000 公尺、剔除盒 0.0159 公尺。
		# 差距來自 inverse bind 矩陣帶的 100 倍——網格座標系與骨骼座標系差 100 倍，
		# 而剖面盒取的是網格座標系。這與資產尺寸無關，重跑管線也修不掉。
		# 餘裕用「公尺」算，不要用骨架空間的單位——這個骨架一單位是 1 公分，
		# 拿它乘出來會得到 1024 這種看不懂的數字。
		mesh.extra_cull_margin = target_height * 4.0
