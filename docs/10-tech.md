# 技術規格（Godot 4）

| 項目 | 方案 |
|---|---|
| 連線架構 | 內建 high-level multiplayer；MultiplayerSpawner + MultiplayerSynchronizer；Host 即 authority |
| 物理後端 | Jolt（剛體堆疊穩定性優於預設） |
| Ragdoll | Skeleton3D + PhysicalBone3D |
| 分屏 | 多 SubViewport + 動態合併邏輯 |
| 高風險項目 | ① 玩家站在玩家頭上的連線同步 ② 本地分屏與線上連線的混合模式 |

### 建議的技術驗證順序

1. 三人連線 + 基本移動同步
2. 抓取與投擲同步
3. **疊高同步**（最高風險，越早撞牆越好）
4. **2 人本地分屏 + 1 人線上的混合連線**（第二高風險）
5. 動態分屏合併／分裂
6. Ragdoll 同步與倒地救援
7. 合體形態的三人共同輸入



---

[← 回到文件索引](../README.md)
