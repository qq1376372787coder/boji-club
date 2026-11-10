# CHANGELOG-UPGRADE.md · 本次实际改动

版本：0.15.0 / Build 108（基线 Build 107）。日期：2026-10-16～17。
分两类：**UI/视觉**（界面升级）与 **V2 业务能力**（追加任务）。后端：无必须部署变更（见 account-server/BACKEND-DELIVERABLES-20261016.md）。

## 一、UI/视觉（界面升级，沿用已确认参考图方向）

### 新增文件
- `DesignTokens.swift` — 全局 Token：颜色/尺寸/字体角色（动态字号）/三种表面/四级按钮/动效（含减少动态效果）。
- `BojiComponents.swift` — 公共组件：动作缩略图、BOJI 沙金点阵封面、提示带、入口行、分段进度、组次表骨架。
- `BojiComponentGalleryView.swift` — 开发预览展示页（不进产品导航）。
- `TrainingRegistrationViews.swift` — 训练登记页组件（顶栏计时/展开/收起卡/组次表/数字编辑面板/建议带）。
- `PlanHubViews.swift` — 计划日程卡（周/月、五种日期语义）、日期摘要卡、计划封面卡。
- `TrainingPreviewView.swift` — 训练预览页（2.1:1 封面、单容器列表、底部开始按钮）。

### 重构
- `WorkoutView.swift` — 训练登记全套重构；旧 TrainingSetRow/TrainingSetNumberEditor 删除；顶栏训练用时＋结束训练；休息条（剩余/调整/跳过）。
- `HomeView.swift` — 首页三块重排；分享预览外壳对齐。
- `ProductArchitecture.swift` — ClubPlanHub（§4.3 顺序）＋ClubRecordsHub 四类统一。
- `TrainingPlansView.swift` — 日行接训练预览；开始训练入口。
- `ProfileView / BodyWeightView / NutritionView / ClubSeasonView / JourneyComponents / FlowDesign / AIViews / PlanView / ManualPlanView / MealEditorView / WeeklyReviewView / ReviewCamera / RevenueCatViews / ClubAdaptive / ClubInsightTimelineView / ClubCoachView / ClubWorkoutSummaryView / BojiClubApp` — 标题层级（30/20/18/17 等宽分层）、按钮材质（主黑胶囊/次浅底）、入口行统一、图标权重保留。
- `Design.swift` — ClubUI 桥接 Token（存量调用零改动）。
- 字号分层规则：只动文本标题，图标与统计数字保留原视觉权重；分享卡深色导出图保留；BrandAccent #161616 未引酒红。

**视觉状态：源码完成，待用户视觉确认（云 Mac 截图对照参考图后校正 Token）。**

## 二、V2 业务能力（追加任务，全部可选字段/向后兼容）

### A 核心体验与设置
- **A1** Club AI 中心 `fullScreenCover` 独立全屏（动态/报告/对话保留会话与定位）。
- **A2/A3** 首页身体面板：多点趋势摘要（14 天窗口、样本不足明说）＋本周训练次数/今日热量/蛋白（未记录/部分标注）。
- **A4** 训练提醒时间用户可设（默认 19:30 保留；签名含时区，时区变化重排）。
- **A5** 早/午/晚三餐登记提醒分别设置；已有记录不提醒；文案「尚未看到你今天的X记录」；记录后重排取消。
- **A6** 提醒/自动分析/系统推送三分说明（NotificationSettingsView）。
- **A7** `ClubProactiveBudget`：普通主动推送每账号每日 ≤1 预算＋规则记录；与会员手动 AI 额度隔离。
- **A8** 免打扰 22:00–08:00 默认值核对通过（按账号持久化不重置）。

### B 计划调整闭环（新文件 PlanShiftViews.swift）
- **B1–B3** 顺延/调整日期：选范围→前后预览→冲突检查（hard 整批拒绝/soft 显式勾选替换留档）→确认→版本记录（`DayLog.planShifts`）→只动未来安排；复制新 ID＋源日恢复标记，不重复不漏。
- **B4** 漏练跟进：连续 ≥2 天「尚未看到完成记录」事实（阈值集中配置），动作=查看与调整。
- **B5** 对话日程提案：`ClubScheduleProposal`＋`ClubCoachRules.validatedMoves` 程序核查→同一顺延预览；模型输出不直接执行。
- **B6/B7** 参数与日程调整共享建议→确认→执行；指纹/hasAppliedAIJob 幂等；回滚=另建未来版本。

### C 洞察可信度
- **C2/C3** `ClubActionRecord` 行动状态机（待处理/供参考/已完成/已过期/执行失败）；阅读状态独立；完成不可回退；提案卡显示状态。

### D 趋势与阶段报告（新文件 TrendAnalysis.swift）
- **D1/D2** `ClubTrendRules` 跨次趋势（同动作身份/单位/负重、跨天样本）；样本不足降级；结论恒带条件。
- **D3/D4** 阶段报告（客户端规则计算版）：≥28 天区间、显式起止/覆盖、无上一阶段不环比；报告库「阶段报告」分类＋生成＋`PhaseReportView`；`DayLog.phaseReports` 持久化同步。
- **D5** `ClubTrendThresholds` 阈值集中；`bodyPlateau` 平台期判定（不满足=不提）。
- **D6** 部分：显式「减少提醒」已有；自动学习未做。

### E 模型扩展
- **E1** `planDescription`/`planIntent`（与全局身体目标分清）。
- **E2/E3** `PlanCyclePattern`（按周固定/练二休一/练三休一/自定义循环）＋可预览日期＋`planPatternLabel` 显式范围；只填空白日。
- **E4** `swapDays` 训练日交换（复制/动作排序已有）。
- **E5** 草稿/模板跨设备同步：`planDrafts`/`planTemplates` 入 SavedState/CloudState；同 ID 取最新；删除标记并集；本地文件一次性迁移＋双写。
- **E7** `targetWeightKg` 目标体重（目标概念，UI 标注）。
- **E8** 全部新字段可选/默认；CloudMerge 合并规则扩展。

### 同步/合并（CloudSync.swift）
- 新增合并键：planShifts/phaseReports（ID 并集）；actionStates/planDrafts/planTemplates（同 ID 取 updatedAt 最新）；deletedPlanDraftIDs/deletedPlanTemplateIDs（并集）。

## 三、未实现（如实）
- E6 距离计量（八层贯通，列独立批次）。
- D6 提醒频率自动学习。
- E7 独立围度/体脂测量记录流程（现用 WeeklyReview.survey 可选字段）。
- AI 阶段报告服务端生成版（客户端计算版已可用；服务端迁移方案在 BACKEND-DELIVERABLES）。
