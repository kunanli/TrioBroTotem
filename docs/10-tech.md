# 技術規格（Godot 4）

> 本文是**方案總覽**。已經拍板、改動成本很高的決定另見〈[技術決策](13-tech-decisions.md)〉；兩份衝突時以〈技術決策〉為準。

| 項目 | 方案 |
|---|---|
| 渲染器 | Forward+（TD-01） |
| 連線架構 | 內建 high-level multiplayer；MultiplayerSpawner + MultiplayerSynchronizer |
| 權威模型 | 自己的角色 client 權威，其餘 host 權威（TD-02） |
| 傳輸層 | 開發用 ENet，上市用 Steam relay（TD-03） |
| 物理後端 | Jolt（剛體堆疊穩定性優於預設） |
| 疊高 | 邏輯附掛，非網路化剛體堆疊（TD-05） |
| Ragdoll | Skeleton3D + PhysicalBone3D；狀態與根位置同步，骨骼各機自算（TD-06） |
| 骨架 | SkeletonProfileHumanoid + BoneMap 重定向（TD-07） |
| 分屏 | 多 SubViewport + 動態合併邏輯（上市後） |
| 高風險項目 | ① 玩家站在玩家頭上的連線同步 ② 本地分屏與線上連線的混合模式 |

### 技術驗證順序

1. `NetworkService` autoload + `PlayerSlot` 抽象 + 三人連線基本移動同步
2. 抓取與投擲同步
3. **疊高同步**（最高風險，越早撞牆越好）
4. Ragdoll 同步與倒地救援（與疊高潰散共用邏輯，故提前）
5. 在 80–150 ms 延遲下重跑 M0 驗收（TD-10）

以下延後至上市後更新：

6. **2 人本地分屏 + 1 人線上的混合連線**（第二高風險）
7. 動態分屏合併／分裂
8. 合體形態的三人共同輸入

> 順序 1–5 即 M0 的工作切分，細節見〈[技術決策](13-tech-decisions.md)〉。第 6 項雖然延後，但 `PlayerSlot`（TD-04）現在就要留好位子。



---

[← 回到文件索引](../README.md)
