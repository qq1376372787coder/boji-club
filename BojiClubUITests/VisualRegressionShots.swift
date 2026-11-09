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
        /// 向上滚动的精确像素量（0 = 不滚；用坐标拖拽实现，不用 swipe——手滑量不可控，R03 两帧才可比）。
        /// R03 两帧验 M6 视差随滚动递增；收缩玻璃条组件已删（甲-2 批，`63e0b27` 起），不是验收点。
        let scrollBy: CGFloat
        /// 本屏唯一主操作的可见文案（有就断言同屏只有一个）
        let primary: String?
        /// 本屏唯一主操作的无障碍标识（比文案稳，页面层登记过的才填）
        let primaryID: String?
        /// 健康注入模式（BOJI_UI_TEST_HEALTH）：nil = 默认样例；"empty" 全空；"heart-only" 只有心率
        let health: String?
        /// 额外操作（唤起键盘、打开状态分分项卡等）
        let action: Action?

        enum Action: Equatable { case focusTextField, openScoreSheet }

        init(code: String, page: String, state: String, route: String, seed: String = "1",
             only: Set<ShotSet>? = nil, scrollBy: CGFloat = 0, primary: String? = nil, primaryID: String? = nil,
             health: String? = nil, action: Action? = nil) {
            self.code = code; self.page = page; self.state = state; self.route = route
            self.seed = seed; self.only = only; self.scrollBy = scrollBy; self.primary = primary
            self.primaryID = primaryID; self.health = health; self.action = action
        }
    }

    private var screens: [Screen] {
        [
            // —— 主壳：今天 ——
            Screen(code: "R01", page: "首页", state: "有数据", route: "home", primaryID: "v2-home-primary"),
            Screen(code: "R02", page: "首页", state: "空态", route: "home", seed: "empty"),
            Screen(code: "R03", page: "首页", state: "滚动100", route: "home", scrollBy: 100),
            Screen(code: "R03", page: "首页", state: "滚动200", route: "home", scrollBy: 200),
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
            Screen(code: "R26", page: "弹层", state: "sheet", route: "plan-move", only: [.light]),
            // —— R27 状态分分项卡（测试验收 补拍，亮色两张）：三行两列 + 缺项「未同步」——
            Screen(code: "R27", page: "状态分", state: "有数据", route: "home", only: [.light], action: .openScoreSheet),
            Screen(code: "R27", page: "状态分", state: "缺一项", route: "home", only: [.light], health: "heart-only", action: .openScoreSheet),
            // —— R28 训练坞两形态（裁决-训练中底部坞 §五-6）：休息态/组内态各一张 ——
            Screen(code: "R28", page: "训练中", state: "休息计时（统一坞休息态）", route: "rest", only: [.light]),
            Screen(code: "R28b", page: "训练中", state: "组内（坞组内态）", route: "workout", only: [.light])
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
        if let health = screen.health { app.launchEnvironment["BOJI_UI_TEST_HEALTH"] = health }
        // 修复 AX 注入失效：系统字号参数已在 launchArguments（:34-40，挂载方式本来就对）。
        // 真凶是审计宿主的字号钳制——BojiComponentGalleryView.swift:235 把整棵视图树钉在 .large，
        // 只认环境开关 BOJI_AUDIT_AX=1（或路由文件尾缀 ax），测试从未设过 → AX 图与亮色像素全同。
        if set == .ax { app.launchEnvironment["BOJI_AUDIT_AX"] = "1" }
        // R28/R28b（裁决 §五-6）：训练坞两形态只在「开练中」会话渲染，接种子的活跃训练开关
        if screen.route == "workout" || screen.route == "rest" {
            app.launchEnvironment["BOJI_PREVIEW_ACTIVE_WORKOUT"] = "1"
        }
        app.launch()

        // 等首屏稳定（按 model）
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "\(screen.code) 启动失败")
        // 判定轮教训（run 42530140469 R01 0 命中）：runningForeground 只等进程态，不等 SwiftUI 首帧。
        // 首页是全 App 最重一屏（品牌视频 + 种子数据 + AI 刷新），查询早于首帧会取到空树假红/假绿。
        // 先等任一文字上屏（可访问性树就绪）再断言与截图；等不到后续断言照样红，不弱化。
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 10)

        if screen.action == .focusTextField {
            let field = app.textFields.firstMatch
            if field.waitForExistence(timeout: 8) { field.tap() }
        }
        if screen.action == .openScoreSheet {
            let opener = app.buttons.matching(identifier: "v2-home-score-detail").firstMatch
            if opener.waitForExistence(timeout: 8) { opener.tap() }
        }

        if screen.scrollBy > 0 {
            // 精确滚动量：坐标拖拽按像素换算（R03a=100pt / R03b=200pt，两帧才可比），
            // 不用 swipe——手滑量不可控，判不了「缩放随滚动递增」
            let height = Double(app.windows.firstMatch.frame.height)
            if height > 0 {
                let fraction = Double(screen.scrollBy) / height
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: max(0.05, 0.62 - fraction)))
                start.press(forDuration: 0.08, thenDragTo: end)
            }
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

        // 4) 每屏唯一主操作（有登记文案或标识的页面才判）
        // 计数前先等元素上屏（同上 R01 教训）：等不到超时后 count=0 断言照样红，判据不弱化。
        if let primary = screen.primary {
            let query = app.buttons.matching(NSPredicate(format: "label == %@", primary))
            _ = query.firstMatch.waitForExistence(timeout: 10)
            XCTAssertEqual(query.count, 1, "\(name) 主操作「\(primary)」应恰好 1 个，实际 \(query.count)")
        }
        if let primaryID = screen.primaryID {
            // 玻璃 buttonStyle 会把标识留在 label 层：按钮查不到时按同名可交互元素再查一次
            let buttons = app.buttons.matching(identifier: primaryID)
            let generic = app.descendants(matching: .any).matching(identifier: primaryID)
            if !buttons.firstMatch.waitForExistence(timeout: 10) {
                _ = generic.firstMatch.waitForExistence(timeout: 2)
            }
            let count = buttons.count > 0 ? buttons.count : generic.count
            if count != 1 {
                // run 42579267726 教训：R01 含时机修复仍 0 命中 = 真问题，不许再猜。
                // run 42584813783 教训：附件不进 job 日志流，导出一坏证据就丢。
                // 双通道：附件（随图包）+ 控制台打印（永远在 job 日志里）。
                let dump = "identifier=\(primaryID) count=\(count)\n" + app.debugDescription
                print("【可访问性树诊断】\(name)\n\(dump)")
                let diagnostic = XCTAttachment(string: dump)
                diagnostic.name = sanitizeFilename("\(name)-可访问性树诊断")
                diagnostic.lifetime = .keepAlways
                add(diagnostic)
            }
            XCTAssertEqual(count, 1, "\(name) 主操作（\(primaryID)）应恰好 1 个，实际 \(count)")
        }

        // 5) 主操作必须完整在屏内（不许被 tab 栏/底边裁掉）
        if let primary = screen.primary {
            let button = app.buttons.matching(NSPredicate(format: "label == %@", primary)).firstMatch
            if button.exists {
                let window = app.windows.firstMatch.frame
                XCTAssertTrue(window.contains(button.frame), "\(name) 主操作出屏：\(button.frame) vs \(window)")
            }
        }
        if let primaryID = screen.primaryID {
            let button = app.buttons.matching(identifier: primaryID).firstMatch
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
        let safe = sanitizeFilename(name)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = safe
        attachment.lifetime = .keepAlways
        add(attachment)

        if let dir = ProcessInfo.processInfo.environment["BOJI_SHOTS_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(safe).appendingPathExtension("png")
            try? screenshot.pngRepresentation.write(to: url)
        }
    }

    /// 附件/文件名清洗（run 42579267726 教训）：引号/冒号/星号等字符会让制品导出与上传失败，一律换掉。
    private func sanitizeFilename(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "\"':*?/\\<>|")
        return raw.components(separatedBy: forbidden).joined(separator: "_")
    }

    /// R03-④ 视差定量取证（Chief 定量法：位移比 0.3±0.1 / 缩放增量；「像素必须不同」是恒真命题已废）。
    /// 测量对象是**被变换的内层媒体**（v2-home-hero-media，HeroParallax 打在它身上），
    /// 外层容器高度恒定量不出视差。测量通道风险：offset/scaleEffect 可能不进 XCUIElement.frame——
    /// 首轮测量+双通道打印 + 方向性软断言（通道失灵恒等可过不假红），出数后钉死硬容差。
    func testHeroParallaxFramesAtScrollDepths() {
        let app = XCUIApplication()
        app.launchArguments = ShotSet.light.launchArguments
        app.launchEnvironment = [
            "BOJI_PREVIEW_ACCOUNT": "complete",
            "BOJI_PREVIEW_SKIP_GUIDE": "1",
            "BOJI_UI_TEST_SEED": "1",
            "BOJI_AUDIT_SCREEN": "home"
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "视差测量启动失败")
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 10)

        let media = app.descendants(matching: .any)["v2-home-hero-media"].firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 10), "视差测量锚 v2-home-hero-media 应在树上（审计上下文暴露）")

        func dragUp(_ points: CGFloat) {
            let height = Double(app.windows.firstMatch.frame.height)
            let fraction = Double(points) / height
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: max(0.05, 0.62 - fraction)))
            start.press(forDuration: 0.08, thenDragTo: end)
        }

        var frames: [(String, CGRect)] = [("0pt", media.frame)]
        dragUp(100); frames.append(("100pt", media.frame))
        dragUp(100); frames.append(("200pt", media.frame))

        let f0 = frames[0].1, f100 = frames[1].1, f200 = frames[2].1
        // 位移比：媒体随滚动的位移 ÷ 内容位移（M6 视差 0.3 倍速 → ≈0.3；同速滚动 → ≈1.0 = 视差死）
        let displacementRatio = Double((f0.minY - f200.minY) / 200)
        // 缩放增量：200pt 处高度 ÷ 0pt 处高度（规格 1→0.96 → ≈0.96；1.0 = 缩放死）
        let scaleRatio = Double(f200.height / max(1, f0.height))

        let report = """
        位移比(200pt) = \(displacementRatio) （目标 ≈0.3±0.1，≈1.0 即视差未生效）
        缩放增量(200pt/0pt) = \(scaleRatio) （目标 ≈0.96，≈1.0 即缩放未生效）
        frames:
        \(frames.map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
        """
        print("【R03-④ 视差定量】\n\(report)")
        let attachment = XCTAttachment(string: report)
        attachment.name = sanitizeFilename("R03-视差定量-位移比与缩放增量")
        attachment.lifetime = .keepAlways
        add(attachment)

        // 方向性软断言（通道失灵恒等可过）：位移比与缩放增量都不许朝反方向走
        XCTAssertLessThanOrEqual(displacementRatio, 1.01, "位移比不许超过同速滚动：\(report)")
        XCTAssertLessThanOrEqual(scaleRatio, 1.01, "缩放增量不许反向放大：\(report)")
        _ = f100 // 三档全量打印，中间档留给出数后的增量断言
    }
}
