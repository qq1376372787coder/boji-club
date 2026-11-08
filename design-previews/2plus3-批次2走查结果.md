# 批次 2 走查结果（界面设计 · 2026-11-09）

按《2plus3-批次2走查清单》A/B/C/D 逐条核源码。结论：**A 玻璃沉浸 5/7 达标、2 项需改；B 三联动 15/17 达标、2 项观察；C 音效 6/6 达标。**

---

## ✅ 达标项

### A 玻璃沉浸
| # | 证据 | 结论 |
|---|---|---|
| A1 视频整屏 | ClubAIShell.swift:1130-1205 `heroGlassContent` 高 **380pt**（原 132pt），视频 `scaledToFill` 铺满，护字渐变 `clear→black 0.58`（:1154-1158） | ✅ 完全符合 §2.1 |
| A2 收缩玻璃条 | :1044-1068 `heroCollapsedBar` 高 **46pt**，`clubGlassEffect(in: Capsule())`，含唯一主操作「开始」＋46pt 高度 | ✅ |
| A4 玻璃件数量 | 收缩态 1 件（玻璃条）、展开态 2 件（Hero 卡 + 暂停钮），≤3 | ✅ |
| A5 深色模式 | :1153 `if colorScheme == .dark { black.opacity(0.2) }` 压暗后再叠护字 | ✅ |
| A6 暂停/播放 | :1195-1196 视觉 30pt、`.frame(44,44)` + `contentShape(Circle())`；:1098-1103 离场 pause + seek(.zero) | ✅ |
| A7 首帧占位（上一批遗留 H-02） | :1082-1096 `loadHeroPoster` 用 AVAssetImageGenerator 取第 0 帧，:1132-1145 占位图在视频下无缝切换 | ✅ **已补上** |

### B 三联动
- B3 完成一组 ✅ TrainingRegistrationViews:322 `latch()` + `play(.setDone, delay: 0.055)`，实测延迟贴合 latch 第二脉冲
- B5 步进/分段 ✅ :308/:308 `tick()` + `play(.tap)`
- B7/B8 训练收官 ✅ WorkoutView:187 `milestone()` + `play(.workoutDone)`
- B10 休息 3/2/1 秒 ✅ WorkoutView:603 同拍 + :606 `setDone` 轻收
- B13 错误 ✅ WorkoutView:81/754 `play(.error)` 挂在 alert `.onAppear`，不重播、文案中性
- B15/B16/B17 不配音效 ✅ Tab/转场/滚动均无音效，符合 §3

### C 音效素材 ✅ 6/6
参数全对《三联动设计表》§2；`BojiSound.swift` 质量高：`.ambient` + `mixWithOthers`（硬件静音天然优先，:46）、启动预加载 `prepareToPlay`（:51）、0.05s 去抖不叠声（:61）、开关 `boji.soundEnabled` 默认开（:34）、`delay` 参数贴触感脉冲（:63-67）。

---

## ❌ 需改（2 项）

### W-1（P2）首页标题重复「薄肌俱乐部」两行
`ClubAIShell.swift:1210-1218` `headerArea`：
```
Text("薄肌俱乐部").bojiType(.caption)   ← 品牌小字
Text("薄肌俱乐部").bojiType(.section)   ← 战区名（原「战备决策舱」被替换成同一词）
```
黑话清理时把「战备决策舱」直接换成「薄肌俱乐部」，与上方品牌小字**撞成两行同样的字**，页面顶上一个词出现两次。
**改法**：按运营文案定稿「区块名取消、做系统大标题」——`headerArea` 只保留品牌标 + 日期 chip，区块名整行删除；若要大标题，用 `navigationTitle("今天")` 系统大标题，不加自绘标题。

### W-2（P3）Hero 主标题字号档位未按规格
`:1172` 用 `.font(.system(size: 52, weight: .bold))`，规格表 §0.2 `.hero` 是 **52pt / 字重 800 / 字距 -2pt**。当前字重偏轻、无字距调整，视觉比稿子「软」一点。
**改法**：`.font(.system(size: 52, weight: .heavy)).tracking(-2)`，或等 `BojiEditorialNumber` 统一档位后走 Token。

---

## ⚠️ 观察项（不阻塞，提请苹果开发顺手）

1. **收缩是二值切换**：`:1029` `if heroShrunk { 条 } else { 卡 }` + `.animation(state)` 做的是**交叉过渡**，不是规格 A3 写的「连续收缩」。观感上问题不大（420pt→46pt 靠 spring 淡入淡出），但真机上如果觉得「跳」，可改为渐变高度 + 淡出，注意不要每帧改 frame（会掉帧，与性能基线冲突）。**先不动，等真机看效果定。**
2. **`heroShrunk` 时 TimelineView 暂停**（:1027 `paused: reduceMotion || heroShrunk`）——收缩后流光停，正确省电；但展开回来会重新计时，流光相位跳变，肉眼几乎无感，接受。
3. **`:1175` 副标题仍是「按计划开始 · 组间自动计时 · 训练后自动生成日报」**——功能说明式，偏工程腔。建议改教练口吻短句：「按计划开练 · 组间自动计时 · 练完自动出日报」（属文案线，交运营文案定，不阻塞玻璃验收）。
4. **iOS 17 下无收缩**（`clubTrackScrollY` 走 `#available(iOS 18)`）——符合「降级功能不减」，但 iOS 17 用户永远看到 380pt 大 Hero，滚动时占屏较多。若真机反馈挤，可给 iOS 17 一个「滚动后固定 46pt 条」的简化降级。

---

## 走查结论

**A 玻璃沉浸：通过（2 项小改）**
**B 三联动：通过（源码级）**
**C 音效：通过**

W-1 建议本批内改掉（一个词的重复，用户一眼就看见）；W-2 可随批次 3 排印统一档位一起改。真机三联动实测（同步性 + 静音/减动效矩阵）待装机后由测试验收执行。
