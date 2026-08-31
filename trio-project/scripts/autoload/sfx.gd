extends Node

## 用程式合成音效，不用音效檔。
##
## 為什麼：打擊感有一半來自聲音（docs/05 的基準是 Overcooked，那套手感很吃回饋
## 密度），但現在整個專案完全無聲。而找音效、處理授權、進版控是另一條產線，
## 為了讓朋友這週就能測，先用合成的頂著。
##
## 全部是 22 kHz 單聲道 16-bit，全部加起來不到 200 KB，而且不進版控——
## 每次啟動現算，改一個數字就能聽到差別，不必重新匯出資產。
##
## 這不是最終音效。等美術與音效正式進來時整層換掉，呼叫端（play 的那些點）
## 不用改。

const RATE := 22050

## 同時最多幾個聲音。用固定池而不是每次 new——連擊時每秒好幾個音效，
## 一直配置節點會在戰鬥最激烈的時候製造卡頓。
const VOICES := 12

var _bank: Dictionary = {}
var _voices: Array[AudioStreamPlayer3D] = []
var _next := 0


func _ready() -> void:
	_build_bank()
	for index in VOICES:
		var voice := AudioStreamPlayer3D.new()
		voice.name = "Voice%d" % index
		voice.max_distance = 40.0
		voice.unit_size = 6.0
		add_child(voice)
		_voices.append(voice)


## 在世界的某個位置播放。純表演，各機各自播，不同步——
## 聲音跟著已經同步的事件走就夠了。
func play(id: StringName, position: Vector3, pitch: float = 1.0, volume_db: float = 0.0) -> void:
	var stream: AudioStreamWAV = _bank.get(id)
	if stream == null:
		return
	var voice := _voices[_next]
	_next = (_next + 1) % _voices.size()
	voice.stream = stream
	voice.volume_db = volume_db
	voice.global_position = position
	# 每次都稍微變調，同一個音效連續播才不會像壞掉的機器。
	voice.pitch_scale = pitch * randf_range(0.94, 1.06)
	voice.play()


func _build_bank() -> void:
	# 命中：低頻撞擊加一層短噪音。噪音給「打到東西」，低頻給重量。
	_bank[&"hit"] = _mix(
		_sweep(180.0, 70.0, 0.12, 0.0018), _noise(0.07, 0.0009, 0.55), 0.55
	)
	# 揮空：噪音的漸強漸弱，聽起來像空氣被劃開。
	_bank[&"whoosh"] = _noise(0.16, 0.05, 0.25)
	# 落地：更悶更短的低頻。
	_bank[&"land"] = _sweep(130.0, 55.0, 0.16, 0.004)
	# 投擲：上揚，表示東西離手。
	_bank[&"throw"] = _sweep(240.0, 520.0, 0.18, 0.02)
	# 疊高成功：兩音上行，明確告訴玩家「成了」。
	_bank[&"stack"] = _arpeggio([523.0, 784.0], 0.09)
	# 扶起：三音上行，比疊高更完整。
	_bank[&"revive"] = _arpeggio([392.0, 523.0, 659.0], 0.10)
	# 通關：五度加八度的小號角。
	_bank[&"goal"] = _arpeggio([523.0, 659.0, 784.0, 1047.0], 0.13)
	# 倒地：下墜，跟上行的那些明確相反。
	_bank[&"down"] = _sweep(420.0, 90.0, 0.38, 0.05)
	# 抬不動：短促的低頻悶哼，明確表示「有反應但失敗了」。
	# 沒有這個的話玩家會以為按鍵壞掉——第一章要教的正是重量規則。
	_bank[&"strain"] = _sweep(150.0, 105.0, 0.22, 0.03)
	# 碎裂：docs/05 三層音效的第三層（揮空／命中／碎裂），之前完全不存在——
	# 殺掉一隻雜兵跟揮空的聽感幾乎一樣，那是「打起來沒感覺」的一大來源。
	# 噪音給碎片、下掃給「散掉」，最後摻一點很低的上揚當規格說的「小歡呼」：
	# 壓得很低是刻意的，每打死一隻雜兵都來一次凱旋會很吵。
	_bank[&"shatter"] = _mix(
		_mix(_noise(0.30, 0.001, 0.30), _sweep(340.0, 90.0, 0.24, 0.002), 0.60),
		_arpeggio([784.0, 1047.0], 0.05), 0.85
	)
	# 被打中。要跟 hit（我打到別人）明顯不同——混戰時分不出「我打到了」
	# 還是「我被打了」會很煩躁。這個比較悶、比較長、音高往下。
	_bank[&"hurt"] = _mix(
		_sweep(300.0, 155.0, 0.15, 0.003), _noise(0.06, 0.001, 0.5), 0.70
	)


## 頻率掃描。attack 是起音時間（秒），太短會有喀啦聲。
func _sweep(from_hz: float, to_hz: float, seconds: float, attack: float) -> AudioStreamWAV:
	var count := int(RATE * seconds)
	var data := PackedByteArray()
	data.resize(count * 2)
	var phase := 0.0
	for index in count:
		var t := float(index) / count
		var hz: float = lerpf(from_hz, to_hz, t)
		phase += TAU * hz / RATE
		var envelope := _envelope(float(index) / RATE, seconds, attack)
		_write(data, index, sin(phase) * envelope)
	return _wrap(data)


## 白噪音加低通（用一階平滑代替，聽起來比純白噪音厚）。
func _noise(seconds: float, attack: float, smooth: float) -> AudioStreamWAV:
	var count := int(RATE * seconds)
	var data := PackedByteArray()
	data.resize(count * 2)
	var last := 0.0
	for index in count:
		last = lerpf(randf_range(-1.0, 1.0), last, smooth)
		var envelope := _envelope(float(index) / RATE, seconds, attack)
		_write(data, index, last * envelope)
	return _wrap(data)


## 一串音，每音等長。
func _arpeggio(notes: Array, note_seconds: float) -> AudioStreamWAV:
	var per := int(RATE * note_seconds)
	var count := per * notes.size()
	var data := PackedByteArray()
	data.resize(count * 2)
	var phase := 0.0
	for step in notes.size():
		var hz: float = notes[step]
		for index in per:
			phase += TAU * hz / RATE
			var envelope := _envelope(float(index) / RATE, note_seconds, 0.008)
			# 加一點三次諧波，純正弦太像測試音。
			var value := sin(phase) * 0.8 + sin(phase * 3.0) * 0.2
			_write(data, step * per + index, value * envelope * 0.7)
	return _wrap(data)


## 兩段疊在一起。
func _mix(a: AudioStreamWAV, b: AudioStreamWAV, weight: float) -> AudioStreamWAV:
	var left := a.data
	var right := b.data
	var count := maxi(left.size(), right.size()) / 2
	var data := PackedByteArray()
	data.resize(count * 2)
	for index in count:
		var value := _read(left, index) * weight + _read(right, index) * (1.0 - weight)
		_write(data, index, clampf(value, -1.0, 1.0))
	return _wrap(data)


## 起音—衰減包絡。沒有起音時間的話波形從 0 直接跳到滿幅，會聽到喀啦聲。
func _envelope(elapsed: float, total: float, attack: float) -> float:
	if attack > 0.0 and elapsed < attack:
		return elapsed / attack
	var left := maxf(total - attack, 0.0001)
	return pow(clampf(1.0 - (elapsed - attack) / left, 0.0, 1.0), 1.6)


func _write(data: PackedByteArray, index: int, value: float) -> void:
	data.encode_s16(index * 2, int(clampf(value, -1.0, 1.0) * 32000.0))


func _read(data: PackedByteArray, index: int) -> float:
	if index * 2 + 1 >= data.size():
		return 0.0
	return data.decode_s16(index * 2) / 32000.0


func _wrap(data: PackedByteArray) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = data
	return stream
