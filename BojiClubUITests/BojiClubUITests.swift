import XCTest

/// 信息架构已按 v3 原型重做为四个 Tab：主页 / 训练 / 记录 / 我的。
/// 自由对话已下线，AI 只保留四个功能入口（每日分析 / 每周复盘 / AI 食物识别 / AI 计划生成）。
/// 因此本文件只断言当前真实存在的外壳、入口与原生组件，不再断言已移除的对话链路。
final class BojiClubUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 启动与导航

    private func launch(tab: String? = nil, seed: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BOJI_PREVIEW_ACCOUNT"] = "complete"
        app.launchEnvironment["BOJI_PREVIEW_SKIP_GUIDE"] = "1"
        app.launchEnvironment["BOJI_UI_TEST_SEED"] = seed ? "1" : "0"
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20), "App should reach the four-tab shell")
        for title in ["主页", "训练", "记录", "我的"] {
            XCTAssertTrue(app.tabBars.buttons[title].exists, "Tab \(title) must exist")
        }
        XCTAssertTrue(app.tabBars.buttons["主页"].isSelected, "主页 must be the default tab")
        XCTAssertTrue(app.buttons["v2-sidebar-toggle"].waitForExistence(timeout: 8), "侧栏抽屉必须仍然可达")
        if let tab { selectTab(tab, in: app) }
        return app
    }

    private func selectTab(_ title: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Tab \(title) must exist")
        tab.tap()
        XCTAssertTrue(tab.isSelected, "Tab \(title) must become selected")
    }

    private func openSidebar(_ route: String, in app: XCUIApplication) {
        app.buttons["v2-sidebar-toggle"].tap()
        let entry = app.buttons["v2-sidebar-" + route]
        revealSidebarEntry(entry, in: app)
        entry.tap()
    }

    private func revealSidebarEntry(_ entry: XCUIElement, in app: XCUIApplication) {
        let panel = app.descendants(matching: .any)["v2-sidebar-panel"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 8), "The native sidebar must be presented before scrolling")
        let collection = panel.descendants(matching: .collectionView).firstMatch
        let table = panel.descendants(matching: .table).firstMatch
        let scroll = panel.descendants(matching: .scrollView).firstMatch
        let container = collection.exists ? collection : table.exists ? table : scroll.exists ? scroll : panel
        reveal(entry, in: app, container: container, description: "sidebar navigation item")
    }

    /// Lazy Lists can omit offscreen rows from AX. Check again after scrolling rather than
    /// requiring existence first. Stop as soon as UIKit reports a usable activation point.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, container: XCUIElement,
                        description: String, limit: Int = 14) {
        for _ in 0..<limit {
            if element.exists && element.isHittable { return }
            let start = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
            let end = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        print("REVEAL-FAILED " + description + "\n" + app.debugDescription)
        attachScreenshot("unreachable-" + description, app: app)
        XCTAssertTrue(element.exists && element.isHittable, description + " must remain reachable by natural scrolling")
    }

    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func startWorkout(in app: XCUIApplication) {
        selectTab("训练", in: app)
        let start = app.buttons["开始训练"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        for _ in 0..<5 where !start.isHittable { app.swipeUp() }
        start.tap()
        XCTAssertTrue(app.buttons["v2-workout-collapse"].waitForExistence(timeout: 8))
    }

    private func launchAudit(_ route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BOJI_PREVIEW_ACCOUNT"] = "complete"
        app.launchEnvironment["BOJI_PREVIEW_SKIP_GUIDE"] = "1"
        app.launchEnvironment["BOJI_UI_TEST_SEED"] = "1"
        app.launchEnvironment["BOJI_AUDIT_SCREEN"] = route
        app.launch()
        return app
    }

    // MARK: - 四 Tab 外壳

    func testFourTabsSwitchWorkspaces() {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["v2-ai-workspace"].firstMatch.waitForExistence(timeout: 8))
        selectTab("训练", in: app)
        XCTAssertTrue(app.buttons["plan-calendar-toggle"].waitForExistence(timeout: 8), "训练 Tab 必须显示计划日历")
        selectTab("记录", in: app)
        XCTAssertTrue(app.segmentedControls["records-category-picker"].waitForExistence(timeout: 8), "记录 Tab 必须显示记录分类")
        selectTab("我的", in: app)
        XCTAssertTrue(app.buttons["编辑头像与昵称"].waitForExistence(timeout: 8), "我的 Tab 必须显示账号资料")
        selectTab("主页", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["v2-ai-workspace"].firstMatch.waitForExistence(timeout: 8))
        attachScreenshot("four-tabs-home", app: app)
    }

    func testHomeShowsFourAIEntryCards() {
        let app = launch()
        let features = app.descendants(matching: .any)["v2-ai-features"].firstMatch
        XCTAssertTrue(features.waitForExistence(timeout: 8), "首页必须给出 AI 功能入口集合")
        let expected: [(String, String)] = [
            ("每日分析", "今天练了什么、吃得怎样、明天调什么"),
            ("每周复盘", "本周节奏回顾与下周安排"),
            ("AI 食物识别", "拍一张照片，自动拆出热量与蛋白"),
            ("AI 计划生成", "按目标生成一周训练安排")
        ]
        for (title, subtitle) in expected {
            let row = app.buttons[title].firstMatch
            for _ in 0..<6 where !row.exists { app.swipeUp() }
            XCTAssertTrue(row.exists, "AI 功能入口 \(title) 必须存在")
            XCTAssertTrue(row.label.contains(subtitle), "\(title) 必须保留说明文案，实际：\(row.label)")
        }
        attachScreenshot("home-ai-features", app: app)
    }

    func testHomeSummaryCardShowsConfirmedVolumeOnly() {
        let app = launch()
        let card = app.descendants(matching: .any)["v2-today-focus-card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8), "首页必须给出今日训练摘要大卡")
        XCTAssertTrue(app.staticTexts["今日训练完成度"].exists, "摘要卡必须说明环形进度的含义，而不是综合评分")
        XCTAssertTrue(app.staticTexts["日报还没生成"].exists || app.staticTexts["今日日报已生成"].exists,
                      "摘要卡必须给出日报状态")
        XCTAssertTrue(app.buttons["开始训练"].exists, "摘要卡必须保留开始训练主按钮")
        // 三格数据的标签也要在，缺数据时用占位而不是 0。
        for label in ["训练组", "摄入 kcal", "体重 kg"] {
            XCTAssertTrue(app.staticTexts[label].exists, "摘要卡必须包含 \(label)")
        }
        attachScreenshot("home-summary-card", app: app)
    }

    func testHomeDataEntryOpensRecordsDashboard() {
        let app = launch()
        let entry = app.buttons["v2-home-data"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 8), "首页顶部必须给出「看数据」入口")
        XCTAssertTrue(entry.label.contains("看数据"), "入口文案必须是看数据，实际：\(entry.label)")
        entry.tap()
        XCTAssertTrue(app.segmentedControls["records-category-picker"].waitForExistence(timeout: 8),
                      "「看数据」必须落到记录 Tab 的数据面板")
        XCTAssertTrue(app.staticTexts["多尺度趋势"].waitForExistence(timeout: 8), "数据面板必须显示趋势分析")
        attachScreenshot("entry-home-data", app: app)
    }

    func testDailyReportEntryOpensReportLibraryFilteredToDaily() {
        let app = launch()
        app.buttons["每日分析"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["AI 解读档案"].waitForExistence(timeout: 10), "每日分析必须打开解读档案")
        XCTAssertTrue(app.staticTexts["生成与更新报告"].waitForExistence(timeout: 5), "解读档案必须包含报告生成入口")
        let filter = app.buttons["筛选"].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5), "解读档案必须提供类型筛选")
        let observed = ((filter.value as? String) ?? "") + " " + filter.label
        XCTAssertTrue(observed.contains("日报"), "每日分析必须直接定位到日报，实际：\(observed)")
        attachScreenshot("entry-daily-report", app: app)
    }

    func testWeeklyReviewEntryOpensReportLibraryFilteredToWeekly() {
        let app = launch()
        app.buttons["每周复盘"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["AI 解读档案"].waitForExistence(timeout: 10), "每周复盘必须打开解读档案")
        let filter = app.buttons["筛选"].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5), "解读档案必须提供类型筛选")
        let observed = ((filter.value as? String) ?? "") + " " + filter.label
        XCTAssertTrue(observed.contains("周报"), "每周复盘必须直接定位到周报，实际：\(observed)")
        attachScreenshot("entry-weekly-review", app: app)
    }

    func testFoodRecognitionEntryOpensCameraCaptureMode() {
        let app = launch()
        app.buttons["AI 食物识别"].firstMatch.tap()
        let mode = app.segmentedControls["meal-entry-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10), "AI 食物识别必须打开饮食编辑器")
        XCTAssertTrue(mode.buttons["拍照"].isSelected, "AI 食物识别必须默认进入拍照模式")
        XCTAssertTrue(app.buttons["从相册选择餐食照片"].exists || app.buttons["拍摄这一餐"].exists,
                      "拍照模式必须提供拍摄或选图入口")
        attachScreenshot("entry-food-recognition", app: app)
    }

    func testPlanGenerationEntryStartsPlanIntakeCard() {
        let app = launch()
        app.buttons["AI 计划生成"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["一起安排训练"].waitForExistence(timeout: 10), "AI 计划生成必须打开计划卡")
        attachScreenshot("entry-plan-generation", app: app)
    }

    func testSidebarDrawerReachesSecondaryRoutes() {
        let app = launch()
        app.buttons["v2-sidebar-toggle"].tap()
        for route in ["today", "club", "tasks", "aimemory", "feedback", "profile", "settings"] {
            let entry = app.buttons["v2-sidebar-" + route]
            revealSidebarEntry(entry, in: app)
        }
        attachScreenshot("sidebar-routes", app: app)
        app.buttons["v2-sidebar-close"].tap()
        XCTAssertTrue(app.tabBars.buttons["主页"].waitForExistence(timeout: 8))
    }

    func testMiniWorkoutBarSurvivesTabSwitchesAndRelaunch() {
        let app = launch()
        startWorkout(in: app)
        app.buttons["v2-workout-collapse"].tap()
        let bar = app.descendants(matching: .any)["mini-workout-bar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 8))
        for title in ["记录", "我的", "主页"] {
            selectTab(title, in: app)
            XCTAssertTrue(bar.exists, "mini 训练条必须跨 Tab 保留（\(title)）")
        }
        app.terminate()
        app.launchEnvironment["BOJI_UI_TEST_SEED"] = "0"
        app.launch()
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Persisted active workout should restore the bottom accessory")
    }

    // MARK: - 训练与计划

    func testExerciseLibraryControlsReachableInSheet() {
        let app = launch(tab: "训练")
        let scroll = app.scrollViews.firstMatch
        if scroll.exists { scroll.swipeUp() }
        let libraryEntry = app.buttons["plan-open-library"]
        XCTAssertTrue(libraryEntry.waitForExistence(timeout: 10), "Library entry should exist")
        XCTAssertTrue(libraryEntry.isHittable, "Library entry should be reachable above the tab bar")
        libraryEntry.tap()
        // 弹层里的动作库是 List + .searchable；exercise-search 只属于从未被使用的 embedded 分支。
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 12) { print(app.debugDescription) }
        XCTAssertTrue(search.waitForExistence(timeout: 12), "Search must be reachable in the exercise sheet")
        XCTAssertTrue(search.isHittable, "Search must not be clipped out of the sheet")
        XCTAssertTrue(app.buttons["exercise-create-custom"].exists, "Personal exercise entry must be visible")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "exercise-library-controls"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.swipeUp()
        XCTAssertTrue(search.exists, "Sheet remains navigable after scrolling")
    }

    func testPlanCalendarExpandsAndOpensMovePreview() {
        let app = launch(tab: "训练")
        XCTAssertTrue(app.buttons["plan-calendar-toggle"].waitForExistence(timeout: 8))
        app.buttons["plan-calendar-toggle"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "已有训练安排")).firstMatch.waitForExistence(timeout: 5))
        let planned = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "已有训练安排")).firstMatch
        if planned.waitForExistence(timeout: 5) {
            planned.tap()
            XCTAssertTrue(app.buttons["调整安排"].waitForExistence(timeout: 5))
            app.buttons["调整安排"].tap()
            XCTAssertTrue(app.staticTexts["移动这一天的安排"].waitForExistence(timeout: 5))
            app.buttons["关闭"].firstMatch.tap()
        } else {
            XCTFail("Seeded future plan day was not visible in the month calendar")
        }
    }

    func testWorkoutCompletionShowsOnlyConfirmedVolume() {
        let app = launch()
        startWorkout(in: app)
        let weight = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "set-weight-")).firstMatch
        XCTAssertTrue(weight.waitForExistence(timeout: 8))
        weight.tap(); weight.typeText("12.5")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let amount = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "set-amount-")).firstMatch
        amount.tap(); app.typeText("8")
        attachScreenshot("build125-native-numeric-input", app: app)
        XCTAssertEqual(amount.value as? String, "8")
        XCTAssertEqual(weight.value as? String, "12.5")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "set-complete-")).firstMatch.tap()
        app.buttons["v2-workout-collapse"].tap()
        let activeBar = app.descendants(matching: .any)["mini-workout-bar"].firstMatch
        XCTAssertTrue(activeBar.waitForExistence(timeout: 5))
        attachScreenshot("build125-active-workout-timer", app: app)
        activeBar.tap()
        app.buttons["结束并保存本次训练"].tap()
        XCTAssertTrue(app.staticTexts["这一练，准备收官？"].waitForExistence(timeout: 5))
        app.buttons["结束并保存 1 组"].tap()
        XCTAssertTrue(app.navigationBars["训练完成"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["辛苦了，训练已完成"].exists)
        attachScreenshot("build125-completion", app: app)
        for _ in 0..<3 where !app.staticTexts["每个动作的完成情况"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["每个动作的完成情况"].exists)
        // 完成页只呈现已确认组：1 组已登记 / 本次安排 3 组。
        let perExercise = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 / 3 组")).firstMatch
        XCTAssertTrue(perExercise.exists, "每个动作的完成情况必须显示已确认组与安排组")
        XCTAssertTrue(app.staticTexts["本次安排 3 组"].exists)
        attachScreenshot("build125-actual-only-charts", app: app)
    }

    func testCompositionTrainingTableStartsInFirstScreen() {
        let app = launch()
        startWorkout(in: app)
        // 进行中的训练用 TrainingInlineSetRow125（Build 125 重做）：完成控件是
        // set-complete-<id>。TrainingSetRowView 的「完成第 N 组」已无调用点。
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "set-complete-")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable, "The first set should be reachable without scrolling past context cards")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "active-workout-first-screen"; shot.lifetime = .keepAlways; add(shot)
    }

    func testManagedPlanEditPreviewAndSave() {
        let app = launch(tab: "训练")
        app.buttons["v2-context-action"].tap()
        app.buttons["管理训练计划"].tap()
        // 「我的计划」先列出计划；edit-managed-plan 在计划详情页，必须先点进计划。
        let planRow = app.staticTexts["训练安排"].firstMatch
        XCTAssertTrue(planRow.waitForExistence(timeout: 8), "当前计划必须列出可编辑的安排")
        planRow.tap()
        let edit = app.buttons["edit-managed-plan"]
        XCTAssertTrue(edit.waitForExistence(timeout: 8)); edit.tap()
        XCTAssertTrue(app.navigationBars["编辑计划"].waitForExistence(timeout: 8))
        let add = app.buttons["添加一组"].firstMatch
        for _ in 0..<5 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.isHittable); add.tap()
        app.buttons["预览更改"].tap()
        XCTAssertTrue(app.navigationBars["核对计划更改"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "4组")).firstMatch.exists)
        attachScreenshot("build126-plan-edit-preview", app: app)
        app.buttons["确认保存"].tap()
        let rootBar = app.navigationBars["我的计划"]
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: rootBar)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
        XCTAssertFalse(app.navigationBars["核对计划更改"].exists)
        XCTAssertTrue(app.buttons["edit-managed-plan"].exists)
        attachScreenshot("build126-plan-saved", app: app)
        app.buttons["edit-managed-plan"].tap()
        XCTAssertTrue(app.navigationBars["编辑计划"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.textFields.count, 8, "Reopened plan must contain four actual saved target rows")
        attachScreenshot("build126-plan-reopened-four-sets", app: app)
    }

    func testCreationOffersManualAndAIWithoutSubmitting() {
        let app = launchAudit("plan-create")
        XCTAssertTrue(app.buttons["create-day"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["create-ai"].exists)
        app.buttons["create-day"].tap()
        XCTAssertTrue(app.buttons["manual-add-from-library"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["保存当天安排"].exists)
        XCTAssertFalse(app.textFields["这份计划的意图（可选，不改全局目标）"].exists)
        XCTAssertFalse(app.textFields["计划描述（可选）"].exists)
    }

    func testManualPickerAddsSeveralActionsTogether() {
        let app = launchAudit("manual-day")
        let add = app.buttons["manual-add-from-library"]
        XCTAssertTrue(add.waitForExistence(timeout: 15)); add.tap()
        let first = app.buttons["library-exercise-1748"]
        XCTAssertTrue(first.waitForExistence(timeout: 20)); first.tap()
        let second = app.buttons["library-exercise-1392"]
        XCTAssertTrue(second.waitForExistence(timeout: 10)); second.tap()
        let done = app.buttons["添加 2 个动作"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        XCTAssertTrue(app.buttons["保存当天安排"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["曲杠仰卧头后臂屈伸"].exists)
        XCTAssertTrue(app.staticTexts["腿举机单腿提踵"].exists)
    }

    func testUnstartedPlanCanBeDeletedFromMyPlans() {
        let app = launchAudit("training-plans")
        // audit 路由落在计划列表，先进入种子计划的详情，菜单项在详情页头部。
        let row = app.staticTexts["训练安排"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "种子计划必须出现在当前计划列表")
        row.tap()
        let menu = app.buttons["管理这份计划"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15)); menu.tap()
        let remove = app.buttons["删除未开始的计划"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap()
        let confirm = app.buttons["移除未开始安排"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.staticTexts["还没有训练计划"].waitForExistence(timeout: 10))
    }

    func testSingleDayLargeTextStaysWithinScreen() {
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT":"complete", "BOJI_PREVIEW_SKIP_GUIDE":"1", "BOJI_UI_TEST_SEED":"1", "BOJI_AUDIT_SCREEN":"manual-day", "BOJI_AUDIT_AX":"1"]
        app.launch()
        let title = app.staticTexts["安排这一天"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(title.frame.minX, 12)
        XCTAssertLessThanOrEqual(title.frame.maxX, app.frame.maxX - 12)
        XCTAssertTrue(app.buttons["保存当天安排"].isHittable)
        let add = app.buttons["manual-add-from-library"]
        for _ in 0..<8 { if add.exists && add.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(add.isHittable)
    }

    // MARK: - 记录、饮食与身体

    func testRecordsTrendScales() {
        let app = launch(tab: "记录")
        XCTAssertTrue(app.staticTexts["多尺度趋势"].waitForExistence(timeout: 8))
        // 5 个尺度走 menu picker（BojiChipRow 在 items>4 时用 menu），不是分段控件：
        // 选项在菜单展开后才存在，直接查 app.buttons["近 12 个月"] 永远查不到。
        let scale = app.buttons["筛选"].firstMatch
        XCTAssertTrue(scale.waitForExistence(timeout: 5), "趋势区必须提供尺度筛选")
        let before = ((scale.value as? String) ?? "") + " " + scale.label
        XCTAssertTrue(before.contains("近 3 个月"), "默认尺度应是近 3 个月，实际：\(before)")
        scale.tap()
        let option = app.buttons["近 12 个月"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "尺度菜单必须提供近 12 个月")
        option.tap()
        XCTAssertTrue(app.staticTexts["多尺度趋势"].waitForExistence(timeout: 5))
        let after = ((scale.value as? String) ?? "") + " " + scale.label
        XCTAssertTrue(after.contains("近 12 个月"), "切换后尺度应是近 12 个月，实际：\(after)")
    }

    func testCompositionStatisticsSections() {
        let app = launch(tab: "记录")
        let picker = app.segmentedControls["records-analysis-section"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.buttons["动作"].tap()
        XCTAssertTrue(app.staticTexts["动作表现与历史"].exists)
        picker.buttons["历史"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "逐日记录")).firstMatch.exists)
        picker.buttons["趋势"].tap()
        XCTAssertTrue(app.staticTexts["多尺度趋势"].exists)
    }

    func testRecordsCanSelectEveryCategory() {
        let app = launch(tab: "记录")
        let picker = app.segmentedControls["records-category-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        // 记录 Tab 的分类是训练 / 饮食 / 身体：AI 解读档案不在这个选择器里，
        // 它由首页四入口与侧栏「AI 解读档案」承担（App 内唯一的 AI 入口集合）。
        for title in ["身体", "训练", "饮食"] {
            let segment = picker.buttons[title]
            segment.tap()
            XCTAssertTrue(segment.isSelected, "Records must select " + title)
        }
    }

    func testCompositionNutritionDisclosure() {
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT": "complete", "BOJI_PREVIEW_SKIP_GUIDE": "1", "BOJI_UI_TEST_SEED": "1", "BOJI_AUDIT_SCREEN": "nutrition"]
        app.launch()
        XCTAssertTrue(app.staticTexts["已记录热量"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["记录饮食"].firstMatch.isHittable)
        let breakfast = app.descendants(matching: .any)["meal-group-早餐"].firstMatch
        XCTAssertTrue(breakfast.waitForExistence(timeout: 8))
        if !breakfast.isHittable { app.swipeUp() }
        breakfast.tap()
        XCTAssertTrue(app.buttons["删除燕麦、鸡蛋与无糖酸奶"].exists, "Expanding a meal group should reveal its editable food row")
    }

    func testCompositionLongMealName() {
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT": "complete", "BOJI_PREVIEW_SKIP_GUIDE": "1", "BOJI_UI_TEST_SEED": "1", "BOJI_AUDIT_SCREEN": "meal-nutrition"]
        app.launch()
        let name = app.descendants(matching: .any)["meal-name-field"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 12))
        name.tap()
        let longName = String(repeating: "少油香煎鸡胸肉配杂粮饭时蔬", count: 5)
        name.typeText(longName)
        XCTAssertTrue(app.buttons["保存"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "long-meal-name-keyboard"; shot.lifetime = .keepAlways; add(shot)
    }

    func testBodyOverviewHasMetricAndRangeControls() {
        let app = launchAudit("body-overview")
        XCTAssertTrue(app.staticTexts["变化趋势"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["选择身体指标"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["30天"].exists)
    }

    func testManualMealAndBodyHaveSingleNavigation() {
        let app = launch()
        app.buttons["记录饮食"].firstMatch.tap()
        let entryMode = app.segmentedControls["meal-entry-mode"]
        XCTAssertTrue(entryMode.waitForExistence(timeout: 10), "The actual meal editor must open")
        XCTAssertTrue(entryMode.buttons["手动"].isSelected, "The manual action must select manual entry directly")
        XCTAssertEqual(app.navigationBars.allElementsBoundByIndex.filter { $0.isHittable }.count, 1,
            "Only the presented editor navigation bar may receive input")
        XCTAssertFalse(app.buttons["v2-sidebar-toggle"].isHittable, "The presenting shell must be isolated behind the sheet")
        attachScreenshot("native-manual-meal-single-navigation", app: app)
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["主页"].waitForExistence(timeout: 8))

        selectTab("记录", in: app)
        app.buttons["v2-context-action"].tap()
        app.buttons["记录身体数据"].tap()
        XCTAssertTrue(app.navigationBars["身体记录"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.navigationBars.allElementsBoundByIndex.filter { $0.isHittable }.count, 1,
            "Only the body editor navigation bar may receive input")
        XCTAssertFalse(app.buttons["v2-sidebar-toggle"].isHittable)
        attachScreenshot("native-body-single-navigation", app: app)
        // 身体记录是独立弹层（未入栈，clubPushed132=false），关闭入口是 DismissButton 的「关闭」。
        let bodyNav = app.navigationBars["身体记录"]
        let closeBody = bodyNav.buttons["关闭"].firstMatch
        if closeBody.exists { closeBody.tap() } else { app.buttons["关闭"].firstMatch.tap() }
        XCTAssertTrue(app.tabBars.buttons["记录"].waitForExistence(timeout: 8))
    }

    func testFeedbackDraftPersistsAndPreviewCannotSend128() {
        let app = launch()
        openSidebar("feedback", in: app)
        let new = app.buttons["feedback-new"]
        XCTAssertTrue(new.waitForExistence(timeout: 8)); new.tap()
        let text = app.textViews["feedback-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 8)); text.tap(); text.typeText("反馈草稿128：长回复遮挡")
        app.buttons["稍后继续"].tap()
        XCTAssertTrue(new.waitForExistence(timeout: 5)); new.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue((text.value as? String ?? "").contains("反馈草稿128：长回复遮挡"))
        let submit = app.buttons["feedback-submit"]
        if !submit.isHittable { app.swipeUp() }
        XCTAssertTrue(submit.isEnabled); submit.tap()
        let message = app.staticTexts["feedback-error"]
        XCTAssertTrue(message.waitForExistence(timeout: 5)); XCTAssertTrue(message.label.contains("预览模式"))
        attachScreenshot("build128-feedback-compose", app: app)
    }

    // MARK: - 我的

    func testProfileTabShowsAccountSections() {
        let app = launch(tab: "我的")
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["编辑头像与昵称"].exists, "我的必须提供头像与昵称入口")
        for title in ["我的计划", "会员与订阅", "设置"] {
            XCTAssertTrue(app.buttons[title].exists, "我的必须保留 \(title)")
        }
        attachScreenshot("profile-tab", app: app)
    }

    func testProfileChangesKeepManualPlan() {
        let app = launchAudit("profile-editor")
        let stepper = app.steppers.firstMatch
        XCTAssertTrue(stepper.waitForExistence(timeout: 15))
        stepper.buttons.element(boundBy: 1).tap()
        app.navigationBars.buttons["保存"].tap()
        // 手动计划（currentPlanUsesAI == false）下确认按钮必须是「保存资料与目标」；
        // 只有 AI 计划才提供「保存并预览新计划」。预览账号写不了 V2 事实资料，
        // 所以这里断言的是「不提供 AI 重排入口」与「绝不进入制定计划页」这两条行为。
        let confirm = app.buttons["保存资料与目标"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "手动计划下保存按钮不能变成 AI 重排入口")
        XCTAssertFalse(app.buttons["保存并预览新计划"].exists, "手动计划不应出现 AI 重排入口")
        confirm.tap()
        XCTAssertFalse(app.navigationBars["制定计划"].waitForExistence(timeout: 3), "保存资料绝不能进入制定计划页")
    }

    // MARK: - 无障碍审计

    func testWorkspaceAccessibilityAudit() throws {
        let app = launch()
        XCTAssertTrue(app.tabBars.buttons["主页"].waitForExistence(timeout: 15))
        var tolerated: [String] = []
        var failures: [String] = []
        // handler 返回 false 时审计框架会在调用点直接记录失败并中断测试，
        // 明细来不及输出。因此这里一律 return true 先收集，最后统一断言。
        func audit(_ scope: String, _ issue: XCUIAccessibilityAuditIssue, requireHittable: Bool = false) -> Bool {
            let compact = issue.compactDescription
            let element = issue.element?.debugDescription.prefix(160) ?? "?"
            // 必须带元素明细：GitHub Actions 会重排/截断多行输出，
            // 只有把「问题 + 元素」打在同一行，才能在日志里定位到具体控件。
            print("AUDIT-DIAGNOSTIC [\(scope)] \(issue.detailedDescription) — \(element)")
            if scope == "sidebar", !compact.contains("nearly passed") {
                attachScreenshot("ax-sidebar-issue-\(failures.count)", app: app)
            }
            // 遮挡量测伪影：元素在 AX 树里但被不透明层（侧栏面板）盖住，不可命中，
            // 审计按遮挡层像素测量。仅打印；可命中元素的发现仍按硬失败处理。
            if requireHittable, let el = issue.element, !el.isHittable {
                print("AUDIT-OCCLUDED [\(scope)] \(compact) — \(element)")
                return true
            }
            if compact.contains("nearly passed") {
                tolerated.append("[\(scope)] \(compact) — \(element)")
            } else {
                failures.append("[\(scope)] \(compact) — \(element)")
            }
            return true
        }
        // 侧栏关闭时 app 级审计（无遮挡，全部元素真实渲染）。
        try app.performAccessibilityAudit { audit("workspace", $0) }
        app.buttons["v2-sidebar-toggle"].tap()
        XCTAssertTrue(app.buttons["v2-sidebar-tasks"].waitForExistence(timeout: 8))
        // 侧栏打开后：app 级审计会连被不透明面板遮挡的工作台元素一起测，按面板
        // 像素量出假对比度失败（全量回归实测）。用 isHittable 区分：被面板盖住的
        // 元素不可命中（其发现记为遮挡量测伪影，仅打印），可命中的发现仍是硬失败。
        try app.performAccessibilityAudit { audit("sidebar", $0, requireHittable: true) }
        if !tolerated.isEmpty {
            print("Accessibility tolerated (by design): \n" + tolerated.joined(separator: "\n"))
        }
        if !failures.isEmpty {
            print("AUDIT-DETAIL workspace/sidebar: \n" + failures.joined(separator: "\n"))
        }
        XCTAssertTrue(failures.isEmpty, "Accessibility audit hard failures:\n" + failures.joined(separator: "\n"))
    }

    func testActiveWorkoutAccessibilityAudit() throws {
        // 训练进行中收起为 mini 条后的工作台也要过审计（Phase 2 曾因 active workout
        // 残留暴露 mini 条对比度问题，此前审计从未覆盖该状态）。
        let app = launch()
        startWorkout(in: app)
        let collapse = app.buttons["v2-workout-collapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 10))
        collapse.tap()
        let miniBar = app.descendants(matching: .any)["mini-workout-bar"].firstMatch
        XCTAssertTrue(miniBar.waitForExistence(timeout: 8), "Collapsed workout must show the mini bar")
        selectTab("主页", in: app)

        // 折叠点击偶发把 App 切到后台（模拟器手势/灵动岛干扰）——审计前确保前台，
        // 否则对比度会按主屏幕壁纸像素测量，产生无意义失败。
        if app.state != .runningForeground {
            print("AUDIT-WARN app went background after collapse; reactivating")
            app.activate()
            _ = app.descendants(matching: .any)["v2-ai-workspace"].firstMatch.waitForExistence(timeout: 10)
        }

        var tolerated: [String] = []
        var failures: [String] = []
        // 同上：一律 return true 先收集，最后统一断言（false 会在调用点中断并吞掉明细）。
        func audit(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
            let compact = issue.compactDescription
            let element = issue.element?.debugDescription ?? "?"
            print("AUDIT-ISSUE active-workout: \(compact) — \(element.prefix(200))")
            if compact.contains("nearly passed") {
                tolerated.append("\(compact) — \(element)")
            } else {
                failures.append("\(compact) — \(element)")
            }
            return true
        }
        // fullScreenCover 收起后 iOS 26 模拟器的 AX 快照会滞后（元素帧停在旧位置，
        // 审计按背景像素测对比度产生假阳性）。重启 App：持久化的 active workout
        // 直接恢复同一状态，获得干净的 AX 树（同时覆盖训练跨启动恢复路径）。
        app.terminate()
        // SEED=1 会在每次启动时重置种子状态，这里要保留刚开始的 active workout，
        // 必须用 SEED=0 读取已持久化状态。
        app.launchEnvironment["BOJI_UI_TEST_SEED"] = "0"
        app.launch()
        let restoredBar = app.descendants(matching: .any)["mini-workout-bar"].firstMatch
        XCTAssertTrue(restoredBar.waitForExistence(timeout: 10), "Persisted workout should restore the mini bar after relaunch")
        // 启动过渡未完全结束时审计会按过渡帧测对比度（多处深字误报失败），等画面稳定。
        sleep(2)
        // 重启后 App 可能自动重开训练全屏页（设计行为）。审计目标是"工作台+mini 条"：
        // 被全屏封面遮挡的元素仍在 AX 树里但不渲染，审计会按空白像素测对比度
        // 产生成片假阳性（此前 0/1200 计数器假失败即此因），封面开着就先收起。
        let workspace = app.descendants(matching: .any)["v2-ai-workspace"].firstMatch
        // isHittable 才能区分"在 AX 树里"与"真的可见可点"：被封面遮挡的元素
        // 依然 exists，但不可命中。
        if !workspace.waitForExistence(timeout: 4) || !workspace.isHittable {
            let collapse2 = app.buttons["v2-workout-collapse"]
            XCTAssertTrue(collapse2.waitForExistence(timeout: 8), "Occluded workspace must have the workout cover to collapse")
            collapse2.tap()
        }
        XCTAssertTrue(workspace.waitForExistence(timeout: 8) && workspace.isHittable, "Workspace must be hittable after collapsing")

        // 注意：审计前不要调 app.screenshot()——iOS 26 模拟器上它会把 App 切后台，
        // 之后 performAccessibilityAudit 会按主屏幕壁纸像素测对比度，产生无意义失败。
        try app.performAccessibilityAudit { audit($0) }
        if !tolerated.isEmpty {
            print("Accessibility tolerated (by design): \n" + tolerated.joined(separator: "\n"))
        }

        // 清理：结束训练，不把 active workout 留给后续测试。UI 测试断言失败即中止
        //（continueAfterFailure=false），因此清理必须放在审计结果断言之前。
        restoredBar.tap()
        // 进行中的训练用 TrainingInlineSetRow125：完成控件是 set-complete-<id>，
        // 重量/次数为空时不会登记完成，结束训练按钮会因此保持禁用，所以先补一组真实数据。
        let firstSet = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "set-complete-")).firstMatch
        XCTAssertTrue(firstSet.waitForExistence(timeout: 10), "Reopening the workout must show the set table")
        let setKey = String(firstSet.identifier.dropFirst("set-complete-".count))
        let weight = app.textFields["set-weight-\(setKey)"]
        let amount = app.textFields["set-amount-\(setKey)"]
        XCTAssertTrue(weight.waitForExistence(timeout: 5), "Reopened set row must expose its numeric inputs")
        for _ in 0..<4 where !weight.isHittable { app.swipeUp() }
        weight.tap(); weight.typeText("20")
        amount.tap(); amount.typeText("10")
        firstSet.tap()
        let finish = app.buttons["结束并保存本次训练"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.tap()
        XCTAssertTrue(app.staticTexts["这一练，准备收官？"].waitForExistence(timeout: 5))
        app.buttons["结束并保存 1 组"].tap()
        XCTAssertTrue(app.navigationBars["训练完成"].waitForExistence(timeout: 8))

        XCTAssertTrue(failures.isEmpty, "Active-workout audit hard failures:\n" + failures.joined(separator: "\n"))
    }

    func testCompositionAccessibilityWorkoutAndNutrition() {
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT": "complete", "BOJI_PREVIEW_SKIP_GUIDE": "1", "BOJI_UI_TEST_SEED": "1", "BOJI_AUDIT_SCREEN": "workout", "BOJI_AUDIT_AX": "1"]
        app.launch()
        // AX3 下同样走 TrainingInlineSetRow125 的 set-complete-<id>。
        let firstSet = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "set-complete-")).firstMatch
        XCTAssertTrue(firstSet.waitForExistence(timeout: 15))
        let setKey = String(firstSet.identifier.dropFirst("set-complete-".count))
        let weight = app.textFields["set-weight-\(setKey)"]
        let amount = app.textFields["set-amount-\(setKey)"]
        XCTAssertTrue(weight.waitForExistence(timeout: 8), "AX3 set row must expose its numeric inputs")
        for _ in 0..<5 {
            if firstSet.isHittable && weight.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(firstSet.isHittable, "AX3 set completion must remain reachable after natural scrolling")
        weight.tap(); weight.typeText("20")
        amount.tap(); amount.typeText("10")
        let table = XCTAttachment(screenshot: app.screenshot())
        table.name = "small-ax3-workout-table"
        table.lifetime = .keepAlways
        add(table)
        firstSet.tap()
        XCTAssertTrue(app.buttons["撤销本组完成"].firstMatch.waitForExistence(timeout: 5), "Completing a set must expose the undo state")
        app.terminate()
        app.launchEnvironment["BOJI_AUDIT_SCREEN"] = "nutrition"
        app.launch()
        let record = app.buttons["记录饮食"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        XCTAssertTrue(record.isHittable, "AX3 primary meal action must clear the bottom safe area")
        // SwiftUI propagates the label identifier to its child rows; use the
        // semantic label to select the disclosure group itself.
        let breakfast = app.buttons["meal-group-早餐"].firstMatch
        reveal(breakfast, in: app, container: app.scrollViews.firstMatch, description: "ax3-breakfast-group")
        sleep(1)
        breakfast.tap()
        let food = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "删除")).firstMatch
        XCTAssertTrue(food.waitForExistence(timeout: 5), "Expanded meal actions must appear")
        reveal(food, in: app, container: app.scrollViews.firstMatch, description: "ax3-expanded-meal-actions")
        let meals = XCTAttachment(screenshot: app.screenshot())
        meals.name = "small-ax3-meal-disclosure"
        meals.lifetime = .keepAlways
        add(meals)
    }

    // MARK: - 性能基线

    func testShellLaunchPerformance() throws {
        // Phase 0-D 性能基线：四 Tab 壳冷启动耗时（XCTApplicationLaunchMetric）。
        // 基线值记录于 docs/v2/evidence/phase1/performance-baseline.md；
        // 后续阶段回归以该基线 ±20% 为关注阈值（不设硬断言，避免 CI 抖动误报）。
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT": "complete", "BOJI_PREVIEW_SKIP_GUIDE": "1",
                                 "BOJI_UI_TEST_SEED": "1"]
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
        }
    }

    func testNativeScrollBenchmark() {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "BOJI_PREVIEW_ACCOUNT": "complete",
            "BOJI_PREVIEW_SKIP_GUIDE": "1",
            "BOJI_UI_TEST_SEED": "1"
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["训练"].waitForExistence(timeout: 15))
        app.tabBars.buttons["训练"].tap()
        XCTAssertTrue(app.buttons["plan-calendar-toggle"].waitForExistence(timeout: 8))
        // Choose the visible training scroller before starting measurement.
        guard let scroll = app.scrollViews.allElementsBoundByIndex.first(where: {
            $0.frame.intersects(app.frame) && $0.isHittable
        }) else {
            XCTFail("The visible training scroll view must be available")
            return
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [
            XCTOSSignpostMetric.scrollingAndDecelerationMetric,
            XCTClockMetric(),
            XCTMemoryMetric(application: app),
            XCTCPUMetric(application: app)
        ], options: options) {
            scroll.swipeUp()
            scroll.swipeDown()
        }
    }

    // MARK: - 审计截图

    func testAuditScreenshots() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let denyCamera = springboard.alerts.buttons["不允许"].firstMatch
        if denyCamera.exists { denyCamera.tap() }
        for _ in 0..<25 {
            let cancel = springboard.alerts.buttons["取消"].firstMatch
            if !cancel.exists { break }
            cancel.tap()
        }
        XCTAssertFalse(springboard.alerts.buttons["打开"].firstMatch.exists, "External-link alert must be dismissed before collecting layout evidence")
        let routes = ProcessInfo.processInfo.environment["BOJI_AUDIT_ROUTES"]?.components(separatedBy: ",") ?? ["home", "plans", "workout", "nutrition", "ai", "club", "records", "profile", "body"]
        for route in routes {
            let app = XCUIApplication()
            app.launchEnvironment["BOJI_PREVIEW_ACCOUNT"] = "complete"
            app.launchEnvironment["BOJI_PREVIEW_SKIP_GUIDE"] = "1"
            app.launchEnvironment["BOJI_UI_TEST_SEED"] = "1"
            app.launchEnvironment["BOJI_AUDIT_SCREEN"] = route
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "audit-" + route
            shot.lifetime = .keepAlways
            add(shot)
            print("AUDIT_SCREEN " + route + " " + app.debugDescription.prefix(160))
            app.terminate()
        }
    }

    func testPrepareAuditSession() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let denyCamera = springboard.alerts.buttons["不允许"].firstMatch
        if denyCamera.exists { denyCamera.tap() }
        for _ in 0..<25 {
            let cancel = springboard.alerts.buttons["取消"].firstMatch
            if !cancel.exists { break }
            cancel.tap()
        }
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT": "complete", "BOJI_PREVIEW_SKIP_GUIDE": "1", "BOJI_UI_TEST_SEED": "1", "BOJI_AUDIT_SCREEN": "home"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["主页"].waitForExistence(timeout: 20))
        XCTAssertFalse(springboard.alerts.buttons["打开"].firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "audit-ready-home"; shot.lifetime = .keepAlways; add(shot)
    }
}

/// 全新用户（BOJI_PREVIEW_ACCOUNT=new）从首页「安排训练」进入计划生成卡，
/// 走完资料问答并到达「生成训练计划」。
final class Build135NaturalWelcomeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testNewUserCanEnterAndCollectPlanFromHome() {
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT": "new", "BOJI_PREVIEW_SKIP_GUIDE": "1"]
        app.launch()
        // 自由对话已下线：新用户落在首页工作台，不再有「我是 Club AI」对话开场。
        // 判据用新用户专属的「补充资料」：今天是否已有安排取决于本机持久化记录
        // （UI 测试共用同一模拟器），不该作为「新用户落在首页」的稳定判据。
        XCTAssertTrue(app.buttons["补充资料"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["安排训练"].exists)
        XCTAssertFalse(app.staticTexts["先认识你"].exists)
        app.buttons["补充资料"].tap()
        XCTAssertTrue(app.textFields["profile-input-profile_weight_kg"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["同时记为一次称重"].exists)
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(app.buttons["安排训练"].waitForExistence(timeout: 10))
        app.buttons["安排训练"].tap()
        XCTAssertTrue(app.staticTexts["你想通过训练达到什么目标？"].waitForExistence(timeout: 10))
        let goal = app.buttons["增肌塑形"]
        XCTAssertTrue(goal.waitForExistence(timeout: 5)); goal.tap()
        XCTAssertTrue(app.staticTexts["你之前有训练经验吗？"].waitForExistence(timeout: 10))
        app.buttons["新手"].tap()
        XCTAssertTrue(app.staticTexts["你通常在哪里训练？"].waitForExistence(timeout: 10))
        app.buttons["健身房"].tap()
        XCTAssertTrue(app.staticTexts["每周哪几天方便训练？"].waitForExistence(timeout: 10))
        app.buttons["周一"].tap(); app.buttons["周三"].tap(); app.buttons["周五"].tap(); app.buttons["继续"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["每次大约能练多久？"].waitForExistence(timeout: 10))
        let minutes = app.textFields["每次时长"]; XCTAssertTrue(minutes.waitForExistence(timeout: 5)); minutes.tap(); minutes.typeText("45")
        app.buttons["继续"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["你已满 18 岁吗？"].waitForExistence(timeout: 10))
        app.buttons["18 岁及以上"].tap()
        XCTAssertTrue(app.buttons["生成训练计划"].waitForExistence(timeout: 10))
    }

    // MARK: - 临时诊断：导出真实 AX 树，确认入口 Button 的 identifier / label

    func testZZDiagnoseAccessibilityTree() {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["v2-ai-workspace"].firstMatch.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 3)
        dumpAX(app, scope: "home")
        for _ in 0..<4 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 2)
        dumpAX(app, scope: "home-scrolled")
        let records = launch(tab: "记录")
        XCTAssertTrue(records.staticTexts["多尺度趋势"].waitForExistence(timeout: 8))
        dumpAX(records, scope: "records")
        // 新用户启动是另一条路径（onboardingCompleted == false），单独导出。
        let newApp = XCUIApplication()
        newApp.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT": "new", "BOJI_PREVIEW_SKIP_GUIDE": "1"]
        newApp.launch()
        Thread.sleep(forTimeInterval: 3)
        dumpAX(newApp, scope: "new-user")
    }

    private func dumpAX(_ app: XCUIApplication, scope: String) {
        let buttons = app.buttons.allElementsBoundByIndex
        print("AXDUMP[\(scope)] buttons=\(buttons.count)")
        for b in buttons {
            print("AXDUMP[\(scope)] BUTTON id=[\(b.identifier)] label=[\(b.label)] value=[\(String(describing: b.value))] frame=\(b.frame) hittable=\(b.isHittable)")
        }
        let texts = app.staticTexts.allElementsBoundByIndex
        print("AXDUMP[\(scope)] staticTexts=\(texts.count)")
        for t in texts.prefix(60) {
            print("AXDUMP[\(scope)] TEXT id=[\(t.identifier)] label=[\(t.label)] frame=\(t.frame) hittable=\(t.isHittable)")
        }
        print("AXDUMP[\(scope)] match-每日分析=\(app.buttons["每日分析"].allElementsBoundByIndex.count)")
        print("AXDUMP[\(scope)] match-每周复盘=\(app.buttons["每周复盘"].allElementsBoundByIndex.count)")
        print("AXDUMP[\(scope)] match-v2-ai-features=\(app.buttons["v2-ai-features"].allElementsBoundByIndex.count)")
        print("AXDUMP[\(scope)] match-ai功能-text=\(app.staticTexts["AI 功能"].allElementsBoundByIndex.count)")
        print("AXDUMP[\(scope)] match-筛选=\(app.buttons["筛选"].allElementsBoundByIndex.count)")
        print("AXDUMP[\(scope)] match-补充资料=\(app.buttons["补充资料"].allElementsBoundByIndex.count)")
        print("AXDUMP[\(scope)] match-今天还没有安排=\(app.staticTexts["今天还没有安排"].allElementsBoundByIndex.count)")
    }
}
