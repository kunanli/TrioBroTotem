class_name WeightLadder
extends RefCounted

## 重量即規則（見 docs/01-overview.md 設計支柱）。
##
## 這一個數值同時決定抓取、疊高順序、擊退距離、浮力、敵人強度讀值。
## 玩家不必背規則，物理會教——但前提是全遊戲只有這一張表。
##
## 階梯（docs/03）：長頸鹿 > 豬 > 海狸 > 蛙 > 貓 > 雞
##
## 新增動物或可搬物件前，必須先在這張表上定位。找不到位置就是設計還沒想清楚。

const GIRAFFE := 60.0
const PIG := 50.0
const LOG := 45.0
const BEAVER := 40.0
const ROCK := 35.0
const FROG := 30.0
const CRATE := 25.0
const CAT := 20.0
const CHICKEN := 10.0

## M0 的三個 slot 暫時對應上市版的三隻：豬（承重）、蛙（位移）、貓（遠距）。
## 之後由角色資料提供，這裡只是讓膠囊有重量差可以測。
const SLOT_WEIGHTS := [PIG, FROG, CAT]


static func for_slot(slot_id: int) -> float:
	if slot_id < 0:
		return CRATE
	return SLOT_WEIGHTS[slot_id % SLOT_WEIGHTS.size()]
