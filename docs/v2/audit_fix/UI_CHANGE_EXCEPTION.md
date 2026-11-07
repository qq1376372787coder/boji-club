# UI CHANGE EXCEPTION — necessary wiring only

> 00A 冻结令仍然有效。未重建首页、侧栏、顶部切换、输入框、训练/记录页面或全局主题。

## Files changed

| File | Class | Change | Why necessary |
|---|---|---|---|
| `BojiClub/ClubCoachView.swift` | UI_INTEGRATION_ONLY | Added `ClubCoachTimelineRow/Builder`; `ForEach` now orders history then live; live bubble uses existing typography/bubble | IA-09 ordering; IA-02/04 live recovery |
| `BojiClub/ProfileView.swift` | UI_INTEGRATION_ONLY | Added one `Toggle("允许从我的记录中学习偏好并生成主动建议")` in the existing AI settings form | IA-08 independent active-learning control |
| `BojiClub/FoodComponents.swift` | UI_INTEGRATION_ONLY | Added caption rows for source, uncertainty flags, calorie range, “来源/份量待确认” label | IA-07 evidence chain visibility |
| `BojiClub/MealEditorView.swift` | UI_INTEGRATION_ONLY | Added one caption banner when any component requires review | IA-07 user confirmation |
| `BojiClub/Models.swift`, `FoodComponents.swift` | NON_UI model | Optional Codable fields for source/range/flags/review | payload compatibility |
| `BojiClub/AIRunStream.swift`, `AIService.swift`, `AccountService.swift`, `ClubAIShell.swift` | NON_UI | pending identity, stream, flags | protocol/state |

## Not changed
- `DesignTokens.swift`, `Design.swift`, `FlowDesign.swift`, `BojiComponents.swift`, `SharedComposer.swift`
- Top `v2-mode-picker`, sidebar, new-conversation button, Composer, training/records/club/membership layouts
- Colors, fonts, spacing, radii, animation, navigation hierarchy

## Evidence
- Before: `evidence/ui_baseline/shell_complete_01.png` (previous round)
- After: `evidence/shell_after_fix.png`
- Layout, typography, colors and control positions unchanged; only clock differs.
- 5 UI tests passed (shell/sidebar/mode switch/draft/keyboard).

## Rollback
- Remove the timeline builder and live row from `ClubCoachView`.
- Remove the proactive toggle section and `proactive_learning` field from `ProfileView`.
- Remove the source/uncertainty caption rows from `FoodComponents/MealEditorView`.
- Server flag `ai_streaming_v2=false` restores polling; no DB rollback required.

## Unverified
- Real live streamed bubble rendering/scroll (no signed-in test server/device).
