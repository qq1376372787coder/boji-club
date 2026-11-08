import XCTest

/// 自动截图巡检（全页面 × 亮色 / 暗色 / 大字号三套）。
///
/// 清单依据：`BUILD140-截图巡检清单.md`（测试验收，23 页 R01–R23 + 状态补充 R24–R26）
/// 与 `design-previews/视觉回归截图清单.md`（界面设计，7 条断言）。
///
/// 跑法（运维支付流水线 / 本地）：
///     xcodebuild test -scheme BojiClub -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
///       -only-testing:BojiClubUITests/VisualRegressionShots \
///       -resultBundlePath shots.xcresult
///
/// 单套补跑：环境变量 `BOJI_SHOT_SET=light|dark|ax`（默认三套全跑）。
/// 直接落盘：环境变量 `BOJI_SHOTS_DIR=/绝对路径` 时，同一张图同时写 PNG（按可读名），
/// 不依赖 xcresulttool 的 UUID 导出。attachment 名与文件名都按
/// `R{编号}-{页}-{状态}-{亮|暗|AX}`。
final class VisualRegressionShots: XCTestCase {

    // MARK: - 三套环境

    private enum ShotSet: String, CaseIterable, Hashable {
        case light, dark, ax

        /// 文件名后缀
        var fileTag: String {
            switch self {
            case .light: "亮"
            case .dark: "暗"
            case .ax: "AX"
            }
        }

        /// 启动参数：暗色走系统外观参数，大字号走系统内容字号参数
        var launchArguments: [String] {
            switch self {
            case .light: []
            case .dark: ["-AppleInterfaceStyle", "Dark"]
            case .ax: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
        }
    }

    // MARK: - 页面清单

    private struct Screen {
        let code: String
        let page: String
        let state: String
        /// BOJI_AUDIT_SCREEN 路由；空串 = 直接进主壳
        let route: String
        /// BOJI_UI_TEST_SEED：1 = 有数据；empty = 空态
        let seed: String
        /// 只在指定套里拍；nil = 三套都拍
        let only: Set<ShotSet>?
        /// 向上滚动次数（0 = 不滚）
        let scroll: Int
        /// 本屏唯一主操作的可见文案（有就断言同屏只有一个）
        let primary: String?
        /// 额外操作（唤起键盘等）
        let action: Action?

        enum Action: Equatable { case focusTextField }

        init(code: String, page: String, state: String, route: String, seed: String = "1",
             only: Set<ShotSet>? = nil, scroll: Int = 0, primary: String? = nil, action: Action? = nil) {
            self.code = code; self.page = page; self.state = state; self.route = route
            self.seed = seed; self.only = only; self.scroll = scroll; self.primary = primary
            self.action = action
        }
    }

    private var screens: [Screen] {
        [
            // —— 主壳：今天 ——
            Screen(code: "R01", page: "首页", state: "有数据", route: "home", primary: "开始练"),
            Screen(code: "R02", page: "首页", state: "空态", route: "home", seed: "empty"),
            Screen(code: "R03", page: "首页", state: "滚动后", route: "home", scroll: 1),
            Screen(code: "R04", page: "首页", state: "AX大字号", route: "home", only: [.ax]),
            // —— 训练 ——
            Screen(code: "R05", page: "训练中", state: "有已完成组", route: "workout"),
            Screen(code: "R06", page: "训练中", state: "键盘唤起", route: "workout", action: .focusTextField),
            Screen(code: "R07", page: "训练完成", state: "庆祝页", route: "completion"),
            // —— 记录 / 饮食 / 身体 ——
            Screen(code: "R08", page: "记录", state: "数值编辑面板", route: "set-editor"),
            Screen(code: "R09", page: "饮食", state: "列表加底栏", route: "nutrition", primary: "记一顿"),
            Screen(code: "R10", page: "身体", state: "首次无数据", route: "body", seed: "empty"),
            // —— 报告 ——
            Screen(code: "R11", page: "日报", state: "报告正文", route: "daily-report"),
            // —— 设置 / 自己 ——
            Screen(code: "R12", page: "设置", state: "分组列表", route: "profile"),
            Screen(code: "R13", page: "自己", state: "入口列表", route: "notifications"),
            // —— 引导 / 会员 ——
            Screen(code: "R14", page: "引导", state: "首屏", route: "walkthrough"),
            Screen(code: "R15", page: "会员", state: "价格列表", route: "membership-prices"),
            // —— 全局暗色基准（编号保留，只在暗色套出图）——
            Screen(code: "R16", page: "全局", state: "暗色首页", route: "home", only: [.dark]),
            // —— 补漏页 ——
            Screen(code: "R17", page: "计划", state: "计划中心", route: "plans"),
            Screen(code: "R18", page: "计划详情", state: "训练预览", route: "training-preview"),
            Screen(code: "R19", page: "动作库", state: "列表", route: "exercise-library"),
            Screen(code: "R20", page: "记录中心", state: "四类入口", route: "records"),
            Screen(code: "R21", page: "周报", state: "周报正文", route: "weekly-report"),
            Screen(code: "R22", page: "俱乐部", state: "成长季", route: "club"),
            Screen(code: "R23", page: "AI会话", state: "对话首屏", route: "ai"),
            // —— 状态补充：只跑亮色套（清单 §二 末尾）——
            Screen(code: "R24", page: "登录", state: "表单", route: "account-entry", only: [.light]),
            Screen(code: "R25", page: "错误", state: "样例", route: "meal-batch", only: [.light]),
            Screen(code: "R26", page: "弹层", state: "sheet", route: "plan-move", only: [.light])
        ]
    }

    // MARK: - 断言口径

    /// 18.8 禁词（用户可见串零命中）
    private static let bannedWords = [
        "编排", "校验", "阈值", "超量恢复", "购买窗口", "战备", "战术", "简报",
        "决策舱", "充能", "引擎", "闭环", "赋能", "出勤", "登记", "链路",
        "额外负重", "负荷总量", "暂未同步", "暂时未能完成操作", "繁琐"
    ]

    /// 报错原文兜底串（不许未操作就上屏）
    private static let rawErrorMarkers = [
        "暂时未能完成操作，请稍后重试",
        "读取未完成，保留上次记录",
        "The operation couldn’t be completed",
        "Error Domain="
    ]

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - 主入口

    func testCaptureAllScreens() {
        let requested = ProcessInfo.processInfo.environment["BOJI_SHOT_SET"]
            .flatMap { ShotSet(rawValue: $0.lowercased()) }
        let sets = requested.map { [$0] } ?? ShotSet.allCases

        for set in sets {
            for screen in screens where screen.only == nil || screen.only!.contains(set) {
                capture(screen, set: set)
            }
        }
    }

    // MARK: - 单屏：启动 → 到达 → 断言 → 截图

    private func capture(_ screen: Screen, set: ShotSet) {
        let app = XCUIApplication()
        app.launchArguments = set.launchArguments
        app.launchEnvironment = [
            "BOJI_PREVIEW_ACCOUNT": "complete",
            "BOJI_PREVIEW_SKIP_GUIDE": "1",
            "BOJI_UI_TEST_SEED": screen.seed
        ]
        if !screen.route.isEmpty { app.launchEnvironment["BOJI_AUDIT_SCREEN"] = screen.route }
        app.launch()

        // 等首屏稳定（按 model）
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "\(screen.code) 启动失败")

        if screen.action == .focusTextField {
            let field = app.textFields.firstMatch
            if field.waitForExistence(timeout: 8) { field.tap() }
        }

        for _ in 0..<screen.scroll {
            app.swipeUp(velocity: .slow)
        }

        let name = "\(screen.code)-\(screen.page)-\(screen.state)-\(set.fileTag)"
        assertScreen(screen, app: app, name: name)
        snapshot(name: name, app: app)
    }

    // MARK: - 7 条断言（界面设计稿 §三；红项优先于人眼）

    private func assertScreen(_ screen: Screen, app: XCUIApplication, name: String) {
        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label)

        // 1) 未操作时不该出现报错原文
        for marker in Self.rawErrorMarkers {
            XCTAssertFalse(labels.contains { $0.contains(marker) }, "\(name) 报错原文上屏：\(marker)")
        }

        // 2) 禁词（军事黑话 / 工程腔 / 广告腔）
        for banned in Self.bannedWords {
            XCTAssertFalse(labels.contains { $0.contains(banned) }, "\(name) 出现禁词：\(banned)")
        }

        // 3) 不许用省略号砍句子
        XCTAssertFalse(labels.contains { $0.contains("…了") || $0.hasSuffix("…") && $0.count < 4 },
                       "\(name) 疑似截断")

        // 4) 每屏唯一主操作（有登记文案的页面才判）
        if let primary = screen.primary {
            let count = app.buttons.matching(NSPredicate(format: "label == %@", primary)).count
            XCTAssertEqual(count, 1, "\(name) 主操作「\(primary)」应恰好 1 个，实际 \(count)")
        }

        // 5) 主操作必须完整在屏内（不许被 tab 栏/底边裁掉）
        if let primary = screen.primary {
            let button = app.buttons.matching(NSPredicate(format: "label == %@", primary)).firstMatch
            if button.exists {
                let window = app.windows.firstMatch.frame
                XCTAssertTrue(window.contains(button.frame), "\(name) 主操作出屏：\(button.frame) vs \(window)")
            }
        }

        // 6) 键盘上方「收起」只许 1 个（BUG-019 判据）
        if screen.action == .focusTextField {
            let hides = app.buttons.matching(NSPredicate(format: "label == %@", "收起")).count
            XCTAssertLessThanOrEqual(hides, 1, "\(name) 键盘上方「收起」重复：\(hides) 个")
        }

        // 7) 空态不许摆裸 0 / —（BUG-025 判据；R02/R10 才有数据口径）
        if screen.seed == "empty" {
            for bare in ["0", "—", "--"] {
                XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label == %@", bare)).firstMatch.exists,
                               "\(name) 空态出现裸值「\(bare)」")
            }
        }
    }

    // MARK: - 出图

    private func snapshot(name: String, app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        if let dir = ProcessInfo.processInfo.environment["BOJI_SHOTS_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name).appendingPathExtension("png")
            try? screenshot.pngRepresentation.write(to: url)
        }
    }
}
