class_name RagdollRecovery
extends SkeletonModifier3D

## 從布娃娃回到動畫的混合（TD-06 點名的難點）。
##
## 沒有這一層的話，扶起的瞬間骨骼會從「癱在地上的姿勢」直接跳回動畫姿勢——
## 實測第一幀有 80 度的跳動，畫面上是「啪」地彈一下。
##
## 關鍵是**姿勢要在 modifier 堆疊裡面side錄**，不能在外面拍照。
## 引擎在跑完 modifier 之後會把骨骼姿勢還原，所以從 stop_ragdoll() 那種
## 一般函式裡讀到的是動畫姿勢，不是布娃娃的姿勢——拍到的照片是錯的，
## 混合等於沒做（實測過，跳動一樣是 80 度）。
##
## 所以這一層永遠開著：模擬進行中每幀側錄它上游算出來的姿勢，
## 停止模擬時就用最後一份側錄當起點，往動畫姿勢球面插值。
## 它排在最後，讀到的「動畫姿勢」已經含 ProceduralPose 疊的呼吸與職業姿態。
##
## 用 ease-out 而不是線性：剛起身動得快、接近站姿慢下來，
## 看起來像「撐起來」而不是「被拉回去」。

enum Mode { IDLE, RECORD, RECOVER }

## 混合時間。TD-06 建議 0.2–0.3 秒；太短仍會看到跳，太長會像慢動作起身。
const RECOVER_TIME := 0.28

var _mode: int = Mode.IDLE
var _pose: Array[Quaternion] = []
var _elapsed := 0.0


## 布娃娃開始模擬時呼叫。之後每幀側錄上游（模擬器）算出來的姿勢。
func start_record() -> void:
	_mode = Mode.RECORD
	_pose.clear()


## 布娃娃停止模擬時呼叫。用最後一份側錄當起點開始混合回動畫。
func begin_recovery() -> void:
	if _pose.is_empty():
		_mode = Mode.IDLE
		return
	_mode = Mode.RECOVER
	_elapsed = 0.0


func _process_modification() -> void:
	if _mode == Mode.IDLE:
		return
	var skeleton := get_skeleton()
	if skeleton == null:
		return

	if _mode == Mode.RECORD:
		_pose.resize(skeleton.get_bone_count())
		for index in skeleton.get_bone_count():
			_pose[index] = skeleton.get_bone_pose_rotation(index)
		return

	_elapsed += get_process_delta_time()
	var ratio := clampf(_elapsed / RECOVER_TIME, 0.0, 1.0)
	var blend := 1.0 - pow(1.0 - ratio, 3.0)  # ease-out
	var count := mini(_pose.size(), skeleton.get_bone_count())
	for index in count:
		var animated := skeleton.get_bone_pose_rotation(index)
		skeleton.set_bone_pose_rotation(index, _pose[index].slerp(animated, blend))

	if ratio >= 1.0:
		_mode = Mode.IDLE
		_pose.clear()
