# 角色資產（正規化後）

`tools/blender_normalize.py` 的輸出放這裡。**只有跑過正規化的檔案能進來**——
骨骼已改名成 `SkeletonProfileHumanoid`（TD-07）、transform 已套用、面數在規格內。

原始匯出檔在專案外的 `assets/source/`，不要放進來。

正規化之後還要跑一次 `python3 tools/fix_skin_bleed.py --apply`：Meshy 的自動蒙皮
會把手臂的權重滲進整顆頭（大頭身的頭壓在肩膀上），不收回來的話手一擺臉就歪。
`tools/check_project.py` 會量，漏了會擋。

進來之後才輪到 Godot 端的工作：`BoneMap` 資源、匯入 preset、`AnimationTree`
狀態機、ragdoll 的 `PhysicalBone3D`。那幾步要看到實際骨架才能寫。
