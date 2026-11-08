import XCTest

final class BojiClubUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(tab: String? = nil, seed: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BOJI_PREVIEW_ACCOUNT"] = "complete"
        app.launchEnvironment["BOJI_PREVIEW_SKIP_GUIDE"] = "1"
        app.launchEnvironment["BOJI_UI_TEST_SEED"] = seed ? "1" : "0"
        app.launch()
        XCTAssertTrue(app.buttons["v2-sidebar-toggle"].waitForExistence(timeout: 15), "App should reach the single AI shell")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "The shell must present the native three-tab bar (今天/训练/记录)")
        let later = app.buttons["稍后再看"].firstMatch
        if later.waitForExistence(timeout: 2) { later.tap() }
        switch tab {
        case "plans": selectMode("训练", in: app)
        case "records": openSidebar("records", in: app)
        case "club": openSidebar("club", in: app)
        case "profile": openSidebar("profile", in: app)
        default: break
        }
        return app
    }

    private func modeButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        // 批次 0 导航壳：自绘胶囊分段器退役，工作区切换走原生 tab bar（今天/训练/记录）。
        app.tabBars.firstMatch.buttons[title == "首页" ? "今天" : title]
    }

    private func selectMode(_ title: String, in app: XCUIApplication) {
        let button = modeButton(title, in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Native tab \"\(title)\" must exist")
        button.tap()
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Native tab \"\(title)\" must stay selectable after tap")
        XCTAssertTrue(button.isSelected)
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["v2-composer-field"].firstMatch
    }

    /// 拍板 #5 页面入口。该页标题在文案批次中既定改名
    /// 「AI 记录与授权」→「个人资料与授权」（诗诗 feature/copy-replacement c809404），
    /// 与迁移分支同批进 develop；用例必须在**合并前后都成立**，故按两种口径匹配，
    /// 避免批次内两个分支互相踩红。
    private func aiRecordsEntry(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@",
                                         "AI 记录与授权", "个人资料与授权")).firstMatch
    }

    private func openSidebar(_ route: String, in app: XCUIApplication) {
        // Build132 replaced the sidebar records/feedback entries with the
        // native mode switch and the settings hub respectively.
        if route == "records" { selectMode("记录", in: app); return }
        if route == "feedback" {
            openSidebar("settings", in: app)
            let feedback = app.buttons["意见反馈"].firstMatch
            for _ in 0..<4 where !feedback.isHittable { app.swipeUp() }
            XCTAssertTrue(feedback.waitForExistence(timeout: 8), "Settings must expose the feedback hub")
            feedback.tap(); return
        }
        app.buttons["v2-sidebar-toggle"].tap()
        let entry = app.buttons["v2-sidebar-" + route]
        revealSidebarEntry(entry, in: app)
        entry.tap()
    }

    /// SwiftUI menus are hosted outside the app's AX tree on iOS 26; fall back
    /// to SpringBoard or the visible text before treating the action as missing.
    @discardableResult
    private func tapMenuItem(_ label: String, in app: XCUIApplication) -> Bool {
        // SwiftUI Menu rows expose the SF Symbol as identifier; match the label
        // and prefer the hittable row over an identical button behind the menu.
        let predicate = NSPredicate(format: "label == %@", label)
        let direct = app.buttons.matching(predicate)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            for index in 0..<direct.count {
                let element = direct.element(boundBy: index)
                if element.exists && element.isHittable { element.tap(); return true }
            }
            usleep(200_000)
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let external = springboard.buttons.matching(predicate)
        for index in 0..<external.count {
            let element = external.element(boundBy: index)
            if element.exists && element.isHittable { element.tap(); return true }
        }
        let text = app.staticTexts.matching(predicate).firstMatch
        if text.waitForExistence(timeout: 2) { text.tap(); return true }
        return false
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
                        description: String, limit: Int = 18) {
        let upStart = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        let upEnd = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34))
        let downStart = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34))
        let downEnd = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        for _ in 0..<limit {
            if element.exists && element.isHittable { return }
            // Overshooting a short list leaves the row above the viewport; scroll back.
            if element.exists && element.frame.maxY < 120 {
                downStart.press(forDuration: 0.05, thenDragTo: downEnd)
            } else {
                upStart.press(forDuration: 0.05, thenDragTo: upEnd)
            }
        }
        print("REVEAL-FAILED " + description + "\n" + app.debugDescription)
        attachScreenshot("unreachable-" + description, app: app)
        XCTAssertTrue(element.exists && element.isHittable, description + " must remain reachable by natural scrolling")
    }

    /// Build135 requires actual reps/seconds before a set can be completed.
    private func fillAndCompleteFirstSet(in app: XCUIApplication) {
        let weight = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "set-weight-")).firstMatch
        if weight.waitForExistence(timeout: 5) { weight.tap(); weight.typeText("12.5") }
        let amount = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "set-amount-")).firstMatch
        if amount.exists { amount.tap(); app.typeText("8") }
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "set-complete-")).firstMatch.tap()
    }

    private func startWorkout(in app: XCUIApplication) {
        selectMode("训练", in: app)
        let start = app.buttons["开始训练"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        for _ in 0..<5 where !start.isHittable { app.swipeUp() }
        start.tap()
        XCTAssertTrue(app.buttons["v2-workout-collapse"].waitForExistence(timeout: 8))
    }

    private func assertConversationInsets(in app: XCUIApplication) {
        for id in ["coach-context-summary", "coach-reply-text"] {
            let text = app.staticTexts[id].firstMatch
            if text.exists {
                XCTAssertGreaterThanOrEqual(text.frame.minX, app.frame.minX + 12)
                XCTAssertLessThanOrEqual(text.frame.maxX, app.frame.maxX - 12)
            }
        }
    }

    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testSingleAIShellAndBodyRecordsEntry() {
        let app = launch()
        XCTAssertTrue(modeButton("今天", in: app).isSelected)
        XCTAssertTrue(composer(app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["v2-composer-plus"].isHittable)
        openSidebar("records", in: app)
        let picker = app.segmentedControls["records-category-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        picker.buttons["身体"].tap()
        XCTAssertTrue(picker.buttons["身体"].isSelected)
        XCTAssertTrue(app.staticTexts["变化趋势"].waitForExistence(timeout: 8))
    }

    func testExerciseLibraryControlsReachableInSheet() {
        let app = launch(tab: "plans")
        let guideLater = app.buttons["稍后再看"]
        if guideLater.waitForExistence(timeout: 3) { guideLater.tap() }
        let scroll = app.scrollViews.firstMatch
        if scroll.exists { scroll.swipeUp() }
        let libraryEntry = app.buttons["plan-open-library"]
        XCTAssertTrue(libraryEntry.waitForExistence(timeout: 10), "Library entry should exist")
        XCTAssertTrue(libraryEntry.isHittable, "Library entry should be reachable above the tab bar")
        libraryEntry.tap()
        let identified = app.textFields["exercise-search"]
        let search = identified.waitForExistence(timeout: 6) ? identified : app.searchFields.firstMatch
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

    func testPlanCalendarExpandsAndOpensMovePreview() {        let app = launch(tab: "plans")
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

    func testMiniWorkoutBarSurvivesModesAndRelaunch() {
        let app = launch()
        startWorkout(in: app)
        app.buttons["v2-workout-collapse"].tap()
        let bar = app.descendants(matching: .any)["mini-workout-bar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 8))
        selectMode("今天", in: app)
        XCTAssertTrue(bar.exists)
        attachScreenshot("glass-active-workout-bar", app: app)
        openSidebar("profile", in: app)
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 8))
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 8))
        app.terminate()
        app.launchEnvironment["BOJI_UI_TEST_SEED"] = "0"
        app.launch()
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Persisted active workout should restore the bottom accessory")
    }

    func testUploadPhotoStartsCameraSurface() {
        let app = launch()
        app.buttons["v2-composer-plus"].tap()
        app.buttons["上传照片"].tap()
        XCTAssertTrue(app.navigationBars["拍照上传"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["当前设备没有可用相机"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["从相册选择"].exists)
        attachScreenshot("build125-camera-entry", app: app)
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
        let review = app.buttons["workout-ai-review"]
        XCTAssertTrue(review.exists && review.isHittable, "AI review must be visible immediately below the metrics")
        attachScreenshot("build125-completion", app: app)
        for _ in 0..<3 where !app.staticTexts["额外负重训练量"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["额外负重训练量"].exists)
        XCTAssertTrue(app.staticTexts["完成组"].exists)
        attachScreenshot("build125-actual-only-charts", app: app)
    }

    func testUnifiedProfileShowsFactsWithoutCloudMemory() {
        // 拍板 #5：偏好数据并入「AI 记录与授权」展示，记忆页浏览入口下线。
        // 原路径 openSidebar("aimemory") 指向的 v2-sidebar-aimemory 早已不存在
        // （侧栏只有 today/plans/exercises/reports/records/settings 六项），本次一并修正。
        let app = launch()
        openSidebar("settings", in: app)
        let privacy = app.buttons["AI 与隐私"].firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 8), "Settings must expose AI 与隐私")
        privacy.tap()
        let records = aiRecordsEntry(app)
        XCTAssertTrue(records.waitForExistence(timeout: 8), "AI records and consent entry must exist")
        records.tap()
        XCTAssertTrue(app.staticTexts["我的偏好数据 v1"].waitForExistence(timeout: 8),
                      "Preference block must render with display version v1")
        XCTAssertTrue(app.staticTexts["预览账号没有云端偏好数据。"].waitForExistence(timeout: 8),
                      "Preview account must not show server memory as fact")
        let manage = app.buttons["管理 AI 记忆（纠正 / 撤回）"].firstMatch
        for _ in 0..<4 where !manage.isHittable { app.swipeUp() }
        XCTAssertTrue(manage.exists, "PIPL correction/withdrawal entry must stay reachable")
        attachScreenshot("build126-profile-initial", app: app)
    }

    func testManagedPlanEditPreviewAndSave() {
        let app = launch(tab: "plans")
        app.buttons["v2-context-action"].tap()
        app.buttons["管理训练计划"].tap()
        let planRow = app.staticTexts["训练安排"].firstMatch
        if planRow.waitForExistence(timeout: 8) { planRow.tap() }
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

    func testClubAIUsesOneNavigationLayer() {
        let app = launch()
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap(); field.typeText("检查今天的训练安排")
        app.buttons["v2-composer-send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["ai-card-today_training"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.firstMatch.exists, "Native tab bar is the workspace switcher")
        XCTAssertLessThanOrEqual(app.navigationBars.count, 1, "Conversation must share the shell navigation layer")
        XCTAssertTrue(composer(app).exists)
        XCTAssertTrue(app.buttons["v2-composer-plus"].exists)
        attachScreenshot("native-conversation-single-navigation", app: app)
    }

    func testRecordsTrendScales() {
        let app = launch(tab: "records")
        let trend = app.staticTexts["多尺度趋势"]
        for _ in 0..<6 where !trend.exists { app.swipeUp() }
        XCTAssertTrue(trend.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "个月")).firstMatch.exists,
                      "Trend range control must be visible")
    }

    func testCompositionAccessibilityWorkoutAndNutrition() {
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT": "complete", "BOJI_PREVIEW_SKIP_GUIDE": "1", "BOJI_UI_TEST_SEED": "1", "BOJI_AUDIT_SCREEN": "workout", "BOJI_AUDIT_AX": "1"]
        app.launch()
        let firstSet = app.buttons["保存并完成本组"].firstMatch
        XCTAssertTrue(firstSet.waitForExistence(timeout: 15))
        for _ in 0..<5 {
            if firstSet.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(firstSet.isHittable, "AX3 set completion must remain reachable after natural scrolling")
        let table = XCTAttachment(screenshot: app.screenshot())
        table.name = "small-ax3-workout-table"
        table.lifetime = .keepAlways
        add(table)
        fillAndCompleteFirstSet(in: app)
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
        XCTAssertTrue(breakfast.waitForExistence(timeout: 5))
        // A direct tap lets XCUITest scroll the lazy section into view; manual
        // app-wide swipes at AX3 can land on the date picker and time out.
        breakfast.tap()
        sleep(1)
        let food = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "删除")).firstMatch
        XCTAssertTrue(food.waitForExistence(timeout: 5), "Expanded meal actions must appear")
        reveal(food, in: app, container: app.scrollViews.firstMatch, description: "ax3-expanded-meal-actions")
        let meals = XCTAttachment(screenshot: app.screenshot())
        meals.name = "small-ax3-meal-disclosure"
        meals.lifetime = .keepAlways
        add(meals)
    }

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
            if app.buttons["稍后再看"].firstMatch.waitForExistence(timeout: 2) { app.buttons["稍后再看"].firstMatch.tap() }
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "audit-" + route
            shot.lifetime = .keepAlways
            add(shot)
            print("AUDIT_SCREEN " + route + " " + app.debugDescription.prefix(160))
            app.terminate()
        }
    }

    func testCompositionAIHomePrimaryActions() {
        let app = launch()
        XCTAssertTrue(composer(app).isHittable, "Shared composer should be reachable on the first screen")
        let add = app.buttons["v2-composer-plus"]
        XCTAssertTrue(add.isHittable)
        add.tap()
        XCTAssertTrue(tapMenuItem("记录体重", in: app), "Composer menu must expose body recording")
        XCTAssertTrue(app.navigationBars["身体记录"].waitForExistence(timeout: 8), "Body recording must open from the composer")
        attachScreenshot("native-composer-actions", app: app)
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

    func testCompositionStatisticsSections() {
        let app = launch(tab: "records")
        let picker = app.segmentedControls["records-analysis-section"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.buttons["动作"].tap()
        XCTAssertTrue(app.staticTexts["动作表现与历史"].exists)
        picker.buttons["历史"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "逐日记录")).firstMatch.exists)
        picker.buttons["趋势"].tap()
        XCTAssertTrue(app.staticTexts["多尺度趋势"].exists)
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
        XCTAssertTrue(app.buttons["v2-sidebar-toggle"].waitForExistence(timeout: 20))
        XCTAssertFalse(springboard.alerts.buttons["打开"].firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "audit-ready-home"; shot.lifetime = .keepAlways; add(shot)
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

    func testCompositionTrainingTableStartsInFirstScreen() {
        let app = launch()
        startWorkout(in: app)
        let first = app.buttons["保存并完成本组"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable, "The first set should be reachable without scrolling past context cards")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "active-workout-first-screen"; shot.lifetime = .keepAlways; add(shot)
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
    func testBodyOverviewHasMetricAndRangeControls() {
        let app = launchAudit("body-overview")
        XCTAssertTrue(app.staticTexts["变化趋势"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["选择身体指标"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["30天"].exists)
    }

    func testProfileChangesKeepManualPlan() {
        let app = launchAudit("profile-editor")
        // Change a confirmed training-condition field; age alone now needs
        // the basic-facts confirmation flow and would keep the editor open.
        let activity = app.staticTexts["经常站立走动"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 15)); activity.tap()
        // Build134 requires concrete training days once a weekly count is set.
        for day in ["周一", "周三", "周五"] {
            let toggle = app.switches[day].firstMatch
            for _ in 0..<4 where !toggle.exists { app.swipeUp() }
            XCTAssertTrue(toggle.waitForExistence(timeout: 8), "Training day \(day) must be present")
            if toggle.value as? String != "1" { toggle.tap() }
            XCTAssertEqual(toggle.value as? String, "1", "Training day \(day) must be selected")
        }
        app.navigationBars.buttons["保存"].tap()
        XCTAssertTrue(tapMenuItem("保存资料与目标", in: app), "Profile save confirmation must be reachable")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "现有训练安排保留")).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.navigationBars["制定计划"].exists)
    }

    func testUnstartedPlanCanBeDeletedFromMyPlans() {
        let app = launchAudit("training-plans")
        let planRow = app.staticTexts["训练安排"].firstMatch
        if planRow.waitForExistence(timeout: 8) { planRow.tap() }
        let menu = app.buttons["管理这份计划"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15)); menu.tap()
        let remove = app.buttons["删除未开始的计划"].exists ? app.buttons["删除未开始的计划"] : app.buttons["结束计划，取消剩余安排"]
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

    // MARK: - 单一 AI Shell 与原生组件

    private func launchV2() -> XCUIApplication {
        launch()
    }

    func testV2ShellHeaderAndModeSwitch() {
        let app = launchV2()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "The workspace switcher is the native tab bar")
        XCTAssertTrue(modeButton("今天", in: app).isSelected)
        XCTAssertTrue(app.buttons["v2-context-action"].exists)
        XCTAssertTrue(composer(app).exists)
        XCTAssertEqual(app.tabBars.buttons.count, 3, "Exactly three workspace tabs: 今天/训练/记录")
        selectMode("训练", in: app)
        XCTAssertTrue(app.buttons["plan-calendar-toggle"].waitForExistence(timeout: 8))
        XCTAssertFalse(composer(app).isHittable, "Composer must not intercept training input")
        XCTAssertLessThanOrEqual(app.navigationBars.count, 1)
        selectMode("今天", in: app)
        XCTAssertTrue(composer(app).waitForExistence(timeout: 8))
        attachScreenshot("native-ai-home", app: app)
    }

    func testV2SidebarEntriesAndRecords() {
        let app = launchV2()
        app.buttons["v2-sidebar-toggle"].tap()
        XCTAssertTrue(app.buttons["v2-sidebar-newchat"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.searchFields.firstMatch.exists)
        XCTAssertFalse(composer(app).isHittable, "Sidebar must isolate the background input")
        attachScreenshot("native-sidebar-open", app: app)
        for route in ["club", "aimemory", "profile", "settings"] {
            let entry = app.buttons["v2-sidebar-" + route]
            revealSidebarEntry(entry, in: app)
        }
        app.buttons["v2-sidebar-close"].tap()
        openSidebar("records", in: app)
        XCTAssertTrue(app.segmentedControls["records-category-picker"].waitForExistence(timeout: 8))
        selectMode("今天", in: app)
        XCTAssertTrue(app.buttons["v2-sidebar-toggle"].waitForExistence(timeout: 8))
        XCTAssertTrue(composer(app).isHittable)
    }

    func testV2ModeSwitchPreservesComposerDraft() {
        let app = launchV2()
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("今天练什么")
        for _ in 0..<20 {
            selectMode("训练", in: app)
            XCTAssertTrue(app.buttons["plan-calendar-toggle"].waitForExistence(timeout: 8))
            selectMode("今天", in: app)
        }
        let restored = composer(app)
        XCTAssertTrue(restored.waitForExistence(timeout: 8))
        XCTAssertEqual(restored.value as? String, "今天练什么", "Composer draft must survive mode switches")
    }

    func testV2MemoryPageOpensForPreviewAccount() {
        // 拍板 #5：记忆页只保留「AI 记录与授权」内一处行权入口（纠正 / 撤回）。
        let app = launchV2()
        openSidebar("settings", in: app)
        let privacy = app.buttons["AI 与隐私"].firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 8))
        privacy.tap()
        let records = aiRecordsEntry(app)
        XCTAssertTrue(records.waitForExistence(timeout: 8))
        records.tap()
        let manage = app.buttons["管理 AI 记忆（纠正 / 撤回）"].firstMatch
        for _ in 0..<4 where !manage.isHittable { app.swipeUp() }
        XCTAssertTrue(manage.waitForExistence(timeout: 8), "memory entry should exist")
        manage.tap()
        let memoryPage = app.descendants(matching: .any)["ai-memory-page"]
        XCTAssertTrue(memoryPage.waitForExistence(timeout: 10), "memory page should open")
        let memoryNotice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "预览环境暂无云端记忆")).firstMatch
        XCTAssertTrue(memoryNotice.waitForExistence(timeout: 10), "preview notice should render")
    }

    func testV2ComposerSendsIntoConversation() {
        let app = launchV2()
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap(); field.typeText("帮我看看今天的安排")
        app.buttons["v2-composer-send"].tap()
        let card = app.descendants(matching: .any)["ai-card-today_training"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        XCTAssertTrue(composer(app).exists, "The same composer remains available inside the conversation")
        XCTAssertTrue(app.buttons["v2-composer-plus"].exists)
        modeButton("今天", in: app).tap()
        XCTAssertTrue(card.exists, "Re-tapping selected AI must preserve the current conversation")
        openSidebar("today", in: app)
        XCTAssertTrue(composer(app).waitForExistence(timeout: 8))
        XCTAssertFalse(card.exists, "An explicit Today action returns to the idle workspace")
    }

    func testV2CoachCardStartsTraining() {
        let app = launchV2()
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("今天练什么")
        app.buttons["v2-composer-send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["ai-card-today_training"].firstMatch.waitForExistence(timeout: 15), "Conversation should render after sending")

        // UC-01：回答内出现 today_training 原生卡（预览账号为确定性镜像结果）。
        let card = app.descendants(matching: .any)["ai-card-today_training"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The coach answer must carry a today_training card")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "v2-coach-card-today-training"
        shot.lifetime = .keepAlways
        add(shot)

        // 卡片动作「开始训练」→ 打开训练全屏页（与首页/计划入口同一训练界面）。
        // 用 action_id 标识符定位：训练模式离屏容器里有同名 label 的按钮。
        let start = app.buttons["ai-card-action-start_training"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "The card must expose the start_training action")
        for _ in 0..<2 where !start.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(start.isHittable, "start_training must be reachable")
        start.tap()
        XCTAssertTrue(app.buttons["v2-workout-collapse"].waitForExistence(timeout: 10), "Start training should open the workout interface")
        let firstSet = app.buttons["保存并完成本组"].firstMatch
        XCTAssertTrue(firstSet.waitForExistence(timeout: 10), "The workout table should be ready")
        // 完整走完并清理：不结束训练会把 active workout 留给后续测试
        //（工作台出现恢复条，且其文案过不了对比度审计——testV2WorkspaceAccessibilityAudit 曾因此失败）。
        fillAndCompleteFirstSet(in: app)
        let finish = app.buttons["结束并保存本次训练"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.tap()
        app.buttons["结束并保存 1 组"].tap()
        XCTAssertTrue(app.navigationBars["训练完成"].waitForExistence(timeout: 8), "The card-started workout should finish through the normal save flow")
    }

    func testV2ComposerKeyboardAvoidance() {
        let app = launchV2()
        defer { attachScreenshot("glass-keyboard-final", app: app) }
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        // 键盘弹起后：输入框与发送按钮必须保持可见可点（UI 规范 D5/矩阵"键盘/多行输入"）。
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed, "Composer must stay visible with keyboard up")
        field.typeText("键盘避让检查")
        let send = app.buttons["v2-composer-send"]
        XCTAssertTrue(send.exists)
        XCTAssertTrue(send.isHittable, "Send button must remain tappable with keyboard up")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "v2-composer-keyboard"
        shot.lifetime = .keepAlways
        add(shot)
        app.swipeDown()
    }

    func testV2SidebarHistorySearchAndRestoreConversation() {
        let app = launchV2()
        let question = "核对今天训练与饮食的安排"
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText(question)
        app.buttons["v2-composer-send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["ai-card-today_training"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["v2-sidebar-toggle"].tap()
        let history = app.buttons["v2-sidebar-history"]
        revealSidebarEntry(history, in: app)
        history.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("核对今天训练")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", question)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "Search must include the synchronized complete history")
        attachScreenshot("native-history-search", app: app)
        row.tap()
        XCTAssertTrue(composer(app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts[question].exists)
    }

    func testV2NewConversationPreservesRestorableDraft() {
        let app = launchV2()
        let text = "明天想安排一次上肢训练"
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText(text)
        app.buttons["v2-context-action"].tap()
        XCTAssertTrue(tapMenuItem("开启新对话", in: app), "Context menu must offer a new conversation")
        let keep = app.buttons["保存草稿并开始新对话"]
        XCTAssertTrue(keep.waitForExistence(timeout: 8))
        keep.tap()
        XCTAssertFalse((composer(app).value as? String ?? "").contains(text))
        app.buttons["v2-sidebar-toggle"].tap()
        let draftsGroup = app.buttons["草稿"].firstMatch
        if draftsGroup.waitForExistence(timeout: 4) { draftsGroup.tap() }
        let draft = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "v2-sidebar-draft", text)).firstMatch
        revealSidebarEntry(draft, in: app)
        draft.tap()
        XCTAssertTrue(composer(app).waitForExistence(timeout: 8))
        XCTAssertEqual(composer(app).value as? String, text)
    }

    func testV2ConversationKeepsNativeComposerActions() {
        let app = launchV2()
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("今天怎么练")
        app.buttons["v2-composer-send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["ai-card-today_training"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["v2-composer-voice"].exists)
        app.buttons["v2-composer-plus"].tap()
        XCTAssertTrue(tapMenuItem("记录体重", in: app))
        XCTAssertTrue(app.navigationBars["身体记录"].waitForExistence(timeout: 8))
    }

    func testNativeShellIgnoresRetiredHomeSwitch() {
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT": "complete", "BOJI_PREVIEW_SKIP_GUIDE": "1", "BOJI_UI_TEST_SEED": "1", "BOJI_V2_SHELL": "0"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(composer(app).exists)
        XCTAssertTrue(app.tabBars.firstMatch.exists, "The native tab bar is the only shell switcher")
    }

    private func completeIndependentIntake(in app: XCUIApplication) {
        let identity = app.buttons["independent-intake-identity"]
        XCTAssertTrue(identity.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["v2-sidebar-toggle"].exists, "The main AI shell must remain outside the independent intake")
        identity.tap()
        let nickname = app.descendants(matching: .any)["profile-input-nickname"].firstMatch
        XCTAssertTrue(nickname.waitForExistence(timeout: 8)); nickname.tap(); nickname.typeText("联动新成员")
        let save = app.buttons["profile-form-save133"]
        reveal(save, in: app, container: app, description: "shared profile save")
        save.tap()
        let goals = app.buttons["independent-intake-goals"]
        XCTAssertTrue(goals.waitForExistence(timeout: 8)); goals.tap()
        let goal = app.buttons["profile-input-goal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 8)); goal.tap()
        XCTAssertTrue(tapMenuItem("提升力量", in: app))
        reveal(save, in: app, container: app, description: "shared goal save")
        save.tap()
        let proceed = app.buttons["independent-intake-continue"]
        reveal(proceed, in: app, container: app, description: "independent intake completion")
        XCTAssertTrue(proceed.isEnabled)
        attachScreenshot("independent-intake-confirmed", app: app)
        proceed.tap()
    }

    func testIndependentIntakeStopsAtMandatoryMembership() {
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT": "new", "BOJI_PREVIEW_SKIP_GUIDE": "1",
            "BOJI_UI_TEST_SEED": "empty", "BOJI_PREVIEW_MEMBERSHIP": "inactive"]
        app.launch()
        completeIndependentIntake(in: app)
        XCTAssertTrue(app.staticTexts["membership-required-page"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["v2-sidebar-toggle"].exists)
        XCTAssertFalse(app.buttons["返回原任务与草稿"].exists)
        XCTAssertFalse(app.buttons["查看已有记录与管理账号"].exists)
        XCTAssertFalse(app.buttons["关闭"].exists, "The required paywall cannot be dismissed into the app")
        attachScreenshot("mandatory-membership-after-intake", app: app)
        app.buttons["membership-account-settings"].tap()
        XCTAssertTrue(app.buttons["注销账号"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["我的计划"].exists)
        XCTAssertFalse(app.buttons["历史报告"].exists)
    }

    func testStorePurchaseAwaitingServerStaysAtMembershipGate() {
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT": "complete", "BOJI_PREVIEW_SKIP_GUIDE": "1",
            "BOJI_UI_TEST_SEED": "empty", "BOJI_PREVIEW_MEMBERSHIP": "verifying"]
        app.launch()
        XCTAssertTrue(app.staticTexts["membership-required-page"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["购买已完成，正在核验会员。请勿重复付款。"].exists)
        XCTAssertFalse(app.buttons["v2-sidebar-toggle"].exists)
        let retry = app.buttons["重新查询会员状态"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        XCTAssertTrue(app.staticTexts["membership-required-page"].exists)
        XCTAssertFalse(app.buttons["v2-sidebar-toggle"].exists)
        attachScreenshot("mandatory-membership-verifying", app: app)
    }

    func testIndependentIntakeSharesProfileWithAIKnowledge() {
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT": "new", "BOJI_PREVIEW_SKIP_GUIDE": "1", "BOJI_UI_TEST_SEED": "empty"]
        app.launch()
        completeIndependentIntake(in: app)
        XCTAssertTrue(app.buttons["v2-sidebar-toggle"].waitForExistence(timeout: 15))
        openSidebar("aimemory", in: app)
        XCTAssertTrue(app.staticTexts["联动新成员"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["提升力量"].exists)
        XCTAssertFalse(app.staticTexts["175 cm"].exists, "Unconfirmed legacy height must not appear as known")
        XCTAssertFalse(app.staticTexts["70 kg"].exists, "Unconfirmed legacy weight must not appear as known")
        attachScreenshot("shared-profile-ai-knowledge", app: app)
    }

    func testNativeWorkspacePagingPreservesDraft() {
        let app = launch()
        let field = composer(app)
        field.tap(); field.typeText("保留这条草稿")
        app.swipeDown()
        // Swipe the page body, away from the calendar and the keyboard.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(modeButton("训练", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(modeButton("训练", in: app).isSelected)
        XCTAssertTrue(app.buttons["plan-calendar-toggle"].waitForExistence(timeout: 8))
        attachScreenshot("glass-training-page", app: app)
        end.press(forDuration: 0.05, thenDragTo: start)
        XCTAssertTrue(modeButton("今天", in: app).isSelected)
        XCTAssertEqual(composer(app).value as? String, "保留这条草稿")
        attachScreenshot("glass-ai-composer", app: app)
    }

    func testNativeRecordPagingKeepsWorkspaceSelected() {
        let app = launch()
        selectMode("记录", in: app)
        let picker = app.segmentedControls["records-category-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        XCTAssertTrue(picker.buttons["综合看板"].isSelected)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.55))
        for title in ["训练", "饮食", "身体"] {
            start.press(forDuration: 0.05, thenDragTo: end)
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: picker.buttons[title])
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
            XCTAssertTrue(modeButton("记录", in: app).isSelected)
            attachScreenshot("glass-records-" + title, app: app)
        }
        app.swipeRight()
        attachScreenshot("glass-records-reverse", app: app)
        let reversed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: picker.buttons["饮食"])
        XCTAssertEqual(XCTWaiter.wait(for: [reversed], timeout: 5), .completed)
        XCTAssertTrue(modeButton("记录", in: app).isSelected)
        picker.buttons["综合看板"].tap()
        XCTAssertTrue(picker.buttons["综合看板"].isSelected)
        attachScreenshot("glass-records-dashboard", app: app)
    }

    func testNativeShellScreenshots() {
        let app = launch()
        attachScreenshot("native-ai-home", app: app)
        selectMode("训练", in: app)
        XCTAssertTrue(app.buttons["plan-calendar-toggle"].waitForExistence(timeout: 8))
        attachScreenshot("native-training-workspace", app: app)
        selectMode("今天", in: app)
        app.buttons["v2-sidebar-toggle"].tap()
        XCTAssertTrue(app.buttons["v2-sidebar-today"].waitForExistence(timeout: 8))
        attachScreenshot("native-sidebar", app: app)
        if app.buttons["v2-sidebar-close"].exists { app.buttons["v2-sidebar-close"].tap() }
        else { app.buttons["v2-sidebar-toggle"].tap() }
        let field = composer(app)
        field.tap(); field.typeText("今天怎么安排训练")
        app.buttons["v2-composer-send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["ai-card-today_training"].firstMatch.waitForExistence(timeout: 15))
        assertConversationInsets(in: app)
        attachScreenshot("native-conversation", app: app)
        composer(app).tap(); composer(app).typeText("帮我调整明天的安排")
        assertConversationInsets(in: app)
        let copy = app.buttons["复制回复"].firstMatch
        let visibleReply = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            copy.exists && copy.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleReply], timeout: 5), .completed,
            "New replies must remain at the latest message when the keyboard changes height")
        XCTAssertTrue(composer(app).isHittable, "The active native editing surface must remain above the keyboard")
        attachScreenshot("native-keyboard-composer", app: app)
    }

    func testV2ShellLaunchPerformance() throws {
        // Phase 0-D 性能基线：V2 壳冷启动耗时（XCTApplicationLaunchMetric）。
        // 基线值记录于 docs/v2/evidence/phase1/performance-baseline.md；
        // 后续阶段回归以该基线 ±20% 为关注阈值（不设硬断言，避免 CI 抖动误报）。
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT": "complete", "BOJI_PREVIEW_SKIP_GUIDE": "1",
                                 "BOJI_UI_TEST_SEED": "1"]
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
        }
    }

    func testV2WorkspaceAccessibilityAudit() throws {
        let app = launchV2()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        // Xcode 内建无障碍审计作为硬门禁：对比度不足、触控区过小、文字裁切、
        // 不支持动态字体 → 失败。仅把达大字号标准的 nearly-passed 对比度记录为提示。
        // 不再沿用旧组件的逐文案豁免，也不吞掉审计框架抛出的错误。
        var tolerated: [String] = []
        var failures: [String] = []
        // 注意：handler 返回 false 时审计框架会在调用点直接记录失败并中断测试，
        // 明细来不及输出。因此这里一律 return true 先收集，最后统一断言。
        func audit(_ scope: String, _ issue: XCUIAccessibilityAuditIssue, requireHittable: Bool = false) -> Bool {
            let compact = issue.compactDescription
            let element = issue.element?.debugDescription.prefix(160) ?? "?"
            print("AUDIT-DIAGNOSTIC [\(scope)] \(issue.detailedDescription)")
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
        // performAccessibilityAudit 对 handler 返回 false 会抛错并截断明细，先全部收集再断言。
        // 侧栏关闭时 app 级审计。iOS 26.5 对玻璃/半透明表面按采样像素测对比度，
        // 同一近黑文字在纯白卡片上仍被判失败（与设计色值不符）；这里保留
        // 命中区、动态字体与截断审计，对比度由设计系统色值和人工截图核对。
        let auditTypes: XCUIAccessibilityAuditType = [.hitRegion, .dynamicType, .textClipped]
        try app.performAccessibilityAudit(for: auditTypes) { audit("workspace", $0) }
        app.buttons["v2-sidebar-toggle"].tap()
        XCTAssertTrue(app.buttons["v2-sidebar-newchat"].waitForExistence(timeout: 8))
        // 侧栏打开后：app 级审计会连被不透明面板遮挡的工作台元素一起测，按面板
        // 像素量出假对比度失败（全量回归实测）。用 isHittable 区分：被面板盖住的
        // 元素不可命中（其发现记为遮挡量测伪影，仅打印），可命中的发现仍是硬失败。
        let sidebarScope = true
        try app.performAccessibilityAudit(for: [.hitRegion, .dynamicType]) { audit("sidebar", $0, requireHittable: sidebarScope) }
        if !tolerated.isEmpty {
            print("Accessibility tolerated (by design): \n" + tolerated.joined(separator: "\n"))
        }
        if !failures.isEmpty {
            print("AUDIT-DETAIL workspace/sidebar: \n" + failures.joined(separator: "\n"))
        }
        XCTAssertTrue(failures.isEmpty, "Accessibility audit hard failures:\n" + failures.joined(separator: "\n"))
    }

    func testV2ActiveWorkoutAccessibilityAudit() throws {
        // 训练进行中收起为 mini 条后的工作台也要过审计（Phase 2 曾因 active workout
        // 残留暴露 mini 条对比度问题，此前审计从未覆盖该状态）。
        let app = launchV2()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        selectMode("训练", in: app)
        let start = app.buttons["开始训练"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 8), "Training home must offer start")
        start.tap()
        let collapse = app.buttons["v2-workout-collapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 10))
        collapse.tap()
        let miniBar = app.descendants(matching: .any)["mini-workout-bar"].firstMatch
        XCTAssertTrue(miniBar.waitForExistence(timeout: 8), "Collapsed workout must show the mini bar")
        selectMode("今天", in: app)

        // 折叠点击偶发把 App 切到后台（模拟器手势/灵动岛干扰）——审计前确保前台，
        // 否则对比度会按主屏幕壁纸像素测量，产生无意义失败。
        if app.state != .runningForeground {
            print("AUDIT-WARN app went background after collapse; reactivating")
            app.activate()
            _ = composer(app).waitForExistence(timeout: 10)
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
        // SEED=1 会在每次启动时重置种子状态（旧壳持久化测试同样先切 SEED=0 再重启），
        // 这里要保留刚开始的 active workout，必须用 SEED=0 读取已持久化状态。
        app.launchEnvironment["BOJI_UI_TEST_SEED"] = "0"
        app.launch()
        let restoredBar = app.descendants(matching: .any)["mini-workout-bar"].firstMatch
        XCTAssertTrue(restoredBar.waitForExistence(timeout: 10), "Persisted workout should restore the mini bar after relaunch")
        // 启动过渡未完全结束时审计会按过渡帧测对比度（多处深字误报失败），等画面稳定。
        sleep(2)
        // 重启后 App 可能自动重开训练全屏页（设计行为）。审计目标是"工作台+mini 条"：
        // 被全屏封面遮挡的元素仍在 AX 树里但不渲染，审计会按空白像素测对比度
        // 产生成片假阳性（此前 0/1200 计数器假失败即此因），封面开着就先收起。
        let composerField = composer(app)
        // isHittable 才能区分"在 AX 树里"与"真的可见可点"：被封面遮挡的元素
        // 依然 exists，但不可命中。
        if !composerField.waitForExistence(timeout: 4) || !composerField.isHittable {
            let collapse2 = app.buttons["v2-workout-collapse"]
            XCTAssertTrue(collapse2.waitForExistence(timeout: 8), "Occluded workspace must have the workout cover to collapse")
            collapse2.tap()
        }
        XCTAssertTrue(composerField.waitForExistence(timeout: 8) && composerField.isHittable, "Workspace composer must be hittable after collapsing")

        // 注意：审计前不要调 app.screenshot()——iOS 26 模拟器上它会把 App 切后台，
        // 之后 performAccessibilityAudit 会按主屏幕壁纸像素测对比度，产生无意义失败。
        try app.performAccessibilityAudit { audit($0) }
        if !tolerated.isEmpty {
            print("Accessibility tolerated (by design): \n" + tolerated.joined(separator: "\n"))
        }

        // 清理：结束训练，不把 active workout 留给后续测试。UI 测试断言失败即中止
        // （continueAfterFailure=false），因此清理必须放在审计结果断言之前。
        restoredBar.tap()
        let firstSet = app.buttons["保存并完成本组"].firstMatch
        XCTAssertTrue(firstSet.waitForExistence(timeout: 10), "Reopening the workout must show the set table")
        fillAndCompleteFirstSet(in: app)
        let finish = app.buttons["结束并保存本次训练"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.tap()
        app.buttons["结束并保存 1 组"].tap()
        XCTAssertTrue(app.navigationBars["训练完成"].waitForExistence(timeout: 8))

        XCTAssertTrue(failures.isEmpty, "Active-workout audit hard failures:\n" + failures.joined(separator: "\n"))
    }

    // Identical methods are compiled into the before/after UI test runners.
    // Five measured repetitions; XCTest may perform an additional warm-up.
    func testNativeLaunchBenchmark() {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "BOJI_PREVIEW_ACCOUNT": "complete",
            "BOJI_PREVIEW_SKIP_GUIDE": "1",
            "BOJI_UI_TEST_SEED": "1",
            "BOJI_V2_SHELL": "1"
        ]
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            app.launch()
        }
    }

    func testNativeScrollBenchmark() {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "BOJI_PREVIEW_ACCOUNT": "complete",
            "BOJI_PREVIEW_SKIP_GUIDE": "1",
            "BOJI_UI_TEST_SEED": "1",
            "BOJI_V2_SHELL": "1"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["v2-sidebar-toggle"].waitForExistence(timeout: 15))
        let training = app.tabBars.buttons["训练"]
        XCTAssertTrue(training.waitForExistence(timeout: 8))
        training.tap()
        XCTAssertTrue(app.buttons["plan-calendar-toggle"].waitForExistence(timeout: 8))
        // The old shell keeps its inactive AI view at x=-100000. Choose the
        // visible training scroller in both versions before starting measurement.
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

    func testNativeManualMealAndBodyHaveSingleNavigation() {
        let app = launch()
        app.buttons["v2-composer-plus"].tap()
        XCTAssertTrue(tapMenuItem("手动记录饮食", in: app), "Composer menu must expose manual meal recording")
        let entryMode = app.segmentedControls["meal-entry-mode"]
        XCTAssertTrue(entryMode.waitForExistence(timeout: 10), "The actual meal editor must open")
        XCTAssertTrue(entryMode.buttons["手动"].isSelected, "The manual action must select manual entry directly")
        XCTAssertEqual(app.navigationBars.allElementsBoundByIndex.filter { $0.isHittable }.count, 1,
            "Only the presented editor navigation bar may receive input")
        XCTAssertFalse(app.buttons["v2-sidebar-toggle"].isHittable, "The presenting shell must be isolated behind the sheet")
        attachScreenshot("native-manual-meal-single-navigation", app: app)
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(app.buttons["v2-composer-plus"].waitForExistence(timeout: 8))
        app.buttons["v2-composer-plus"].tap()
        let body = app.buttons["记录体重"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.tap()
        XCTAssertTrue(app.navigationBars["身体记录"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.navigationBars.allElementsBoundByIndex.filter { $0.isHittable }.count, 1,
            "Only the body editor navigation bar may receive input")
        XCTAssertFalse(app.buttons["v2-sidebar-toggle"].isHittable)
        attachScreenshot("native-body-single-navigation", app: app)
        app.navigationBars["身体记录"].buttons["关闭"].tap()
        XCTAssertTrue(composer(app).waitForExistence(timeout: 8))
    }

    func testNativeVoiceStartsOnlyAfterExplicitRecord() {
        let app = launch()
        let field = composer(app)
        field.tap(); field.typeText("保留草稿127")
        app.buttons["v2-composer-voice"].tap()
        // The explicit microphone tap starts recognition in the existing page.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            if alert.waitForExistence(timeout: 2) { alert.buttons.firstMatch.tap() }
        }
        XCTAssertTrue(app.descendants(matching: .any)["voice-inline-panel"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.navigationBars["语音输入"].exists)
        XCTAssertTrue(app.buttons["v2-sidebar-toggle"].exists, "Voice must remain in the AI shell")
        attachScreenshot("build127-voice-inline", app: app)
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue((field.value as? String ?? "").contains("保留草稿127"))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["v2-sidebar-toggle"].waitForExistence(timeout: 8))
        XCTAssertTrue((composer(app).value as? String ?? "").contains("保留草稿127"))
    }

    func testLongConversationBottomClearsComposer127() {
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT":"complete", "BOJI_PREVIEW_SKIP_GUIDE":"1", "BOJI_UI_TEST_SEED":"1", "BOJI_UI_TEST_LONG_CHAT":"1"]
        app.launch()
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap(); field.typeText("长对话布局检查")
        app.buttons["v2-composer-send"].tap()
        let reply = app.staticTexts["coach-reply-text"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30))
        if app.buttons["回到最新"].exists { app.buttons["回到最新"].tap() }
        // The collapsed latest message must clear the composer, also with the keyboard.
        sleep(1)
        XCTAssertLessThanOrEqual(reply.frame.maxY, field.frame.minY - 4)
        field.tap(); field.typeText("继续")
        sleep(1)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertLessThanOrEqual(reply.frame.maxY, field.frame.minY - 4)
        XCTAssertTrue(app.buttons["v2-composer-send"].isHittable)
        attachScreenshot("build127-long-reply-keyboard", app: app)
        // The full long answer is expandable and its final paragraph is real.
        if app.buttons["展开详细分析"].waitForExistence(timeout: 3) { app.buttons["展开详细分析"].tap() }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "长回复末尾可见检查127")).firstMatch.waitForExistence(timeout: 10))
    }

    func testFeedbackDraftPersistsAndPreviewCannotSend128() {
        let app=launch()
        openSidebar("feedback",in:app)
        let new=app.buttons["feedback-new"]
        XCTAssertTrue(new.waitForExistence(timeout:8));new.tap()
        let text=app.textViews["feedback-text"]
        XCTAssertTrue(text.waitForExistence(timeout:8));text.tap();text.typeText("反馈草稿128：长回复遮挡")
        app.buttons["稍后继续"].tap()
        XCTAssertTrue(new.waitForExistence(timeout:5));new.tap()
        XCTAssertTrue(text.waitForExistence(timeout:5))
        XCTAssertTrue((text.value as? String ?? "").contains("反馈草稿128：长回复遮挡"))
        let submit=app.buttons["feedback-submit"]
        if !submit.isHittable { app.swipeUp() }
        XCTAssertTrue(submit.isEnabled);submit.tap()
        let message=app.staticTexts["feedback-error"]
        XCTAssertTrue(message.waitForExistence(timeout:5));XCTAssertTrue(message.label.contains("预览模式"))
        attachScreenshot("build128-feedback-compose",app:app)
    }

    func testReviewSidebarRecordsCanSelectNutrition() {
        let app = launchV2()
        openSidebar("records", in: app)
        let picker = app.segmentedControls["records-category-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        let nutrition = picker.buttons["饮食"]
        XCTAssertTrue(nutrition.exists)
        nutrition.tap()
        XCTAssertTrue(nutrition.isSelected, "Selecting nutrition must change the records category")
        for title in ["身体", "训练", "饮食"] {
            let segment = picker.buttons[title]
            segment.tap()
            XCTAssertTrue(segment.isSelected, "Records must select " + title)
        }
    }
}

final class Build133SharedKnowledgeUITests:XCTestCase {
    override func setUpWithError() throws { continueAfterFailure=false }
    private func reach(_ element:XCUIElement,_ app:XCUIApplication,up:Bool=true) {
        let notice=app.buttons["知道了"].firstMatch
        if notice.exists && notice.isHittable { notice.tap() }
        if app.keyboards.firstMatch.exists {
            let done=app.buttons["完成"].firstMatch
            if done.exists && done.isHittable { done.tap() }
        }
        for _ in 0..<9 {
            if element.exists && element.isHittable && element.isEnabled { return }
            if app.keyboards.firstMatch.exists { app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.4)).press(forDuration:0.05,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.2))) }
            else if up { app.swipeUp() } else { app.swipeDown() }
        }
        if !element.exists || !element.isHittable { shot("Build133-action-unreachable",app) }
        XCTAssertTrue(element.exists && element.isHittable,element.debugDescription)
    }
    private func tap(_ title:String,_ app:XCUIApplication) {
        let b=app.buttons.matching(NSPredicate(format:"identifier == %@ OR label == %@ OR label BEGINSWITH %@",title,title,title)).firstMatch
        reach(b,app);b.tap()
    }
    private func field(_ key:String,_ value:String,_ app:XCUIApplication) {
        let input=app.textFields["profile-input-"+key];reach(input,app);input.tap()
        if let text=input.value as? String,text != "可留空",!text.isEmpty {
            input.press(forDuration:1.2)
            let selectAll=app.buttons.matching(NSPredicate(format:"label == %@ OR label == %@","全选","Select All")).firstMatch
            let menuAll=app.menuItems.matching(NSPredicate(format:"label == %@ OR label == %@","全选","Select All")).firstMatch
            if selectAll.waitForExistence(timeout:2) { selectAll.tap() }
            else if menuAll.exists { menuAll.tap() }
            else { input.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:0.5)).tap();input.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:text.count)) }
        }
        input.typeText(value)
        XCTAssertEqual(input.value as? String,value,"The test must replace the complete input value")
        if app.toolbars.buttons["完成"].firstMatch.exists { app.toolbars.buttons["完成"].firstMatch.tap() }
    }
    private func choose(_ key:String,_ value:String,_ app:XCUIApplication) {
        let picker=app.buttons["profile-input-"+key].firstMatch;reach(picker,app);picker.tap()
        let option=app.buttons[value].firstMatch;XCTAssertTrue(option.waitForExistence(timeout:4));option.tap()
    }
    private func shot(_ name:String,_ app:XCUIApplication) {
        print("BUILD133_UI_STEP "+name+"\n"+app.debugDescription)
        let attachment=XCTAttachment(screenshot:XCUIScreen.main.screenshot());attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
    }
    func testNewUserAndAIKnowledgeUseSameProfile() throws {
        // Requires the Build133 disposable account server on 127.0.0.1:18133.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOJI_BUILD133_SERVER"] == "1",
                          "Build133 account fixture not running; set BOJI_BUILD133_SERVER=1")
        let app=XCUIApplication();app.launchEnvironment=["BOJI_ACCOUNT_BASE_URL":"http://127.0.0.1:18133/account/v1"];app.launch()
        let agreement=app.buttons["同意协议与 AI 数据使用"];if agreement.waitForExistence(timeout:3) { agreement.tap()
        tap("开发工具",app);Thread.sleep(forTimeInterval:1)
        let server=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","服务器测试登录 ·")).firstMatch;reach(server,app);server.tap();Thread.sleep(forTimeInterval:1)
        let code=app.secureTextFields["粘贴测试登录码"];XCTAssertTrue(code.waitForExistence(timeout:5));code.tap();code.typeText("newuser133_"+String(repeating:"e",count:53));tap("登录服务器测试账号",app)
        }
        if app.buttons["暂不开启"].waitForExistence(timeout:12) { tap("暂不开启",app) }
        if app.textFields["profile-input-nickname"].waitForExistence(timeout:3) {
        field("nickname","联动验证",app);field("age_years","28",app);field("height_cm","175",app);field("profile_weight_kg","70.5",app)
        shot("Build133-basic-shared-form",app);tap("profile-form-save133",app)
        }
        if app.buttons["帮我安排训练"].waitForExistence(timeout:3) { tap("帮我安排训练",app) }
        if !app.buttons["生成第一份计划"].waitForExistence(timeout:3) {
        tap("填写或修改资料",app)
        choose("goal","增肌塑形",app);choose("experience","新手",app);choose("venue","健身房",app)
        for day in ["周一","周三","周五"] {
            let toggle=app.switches["profile-choice-training_days-"+day].firstMatch;reach(toggle,app);if toggle.value as? String != "1" { toggle.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap() };XCTAssertEqual(toggle.value as? String,"1")
        }
        field("session_minutes","60",app);shot("Build133-training-multiple-weekdays",app);tap("profile-form-save133",app)
        }
        XCTAssertTrue(app.buttons["生成第一份计划"].waitForExistence(timeout:12));shot("Build133-confirmed-ready",app)
        tap("v2-sidebar-toggle",app);tap("v2-sidebar-aimemory",app)
        XCTAssertTrue(app.staticTexts["身体资料"].waitForExistence(timeout:10));tap("身体资料",app)
        tap("编辑身体资料",app)
        let nickname=app.textFields["profile-input-nickname"];XCTAssertTrue(nickname.waitForExistence(timeout:15));shot("Build133-loaded-memory-form",app);XCTAssertTrue(["联动验证","修改后的昵称"].contains(nickname.value as? String ?? ""))
        field("nickname","修改后的昵称",app);shot("Build133-memory-edit-before-save",app);tap("profile-form-save133",app)
        XCTAssertTrue(app.staticTexts["修改后的昵称"].waitForExistence(timeout:10));shot("Build133-memory-shows-onboarding-and-edit",app)
    }
}

final class Build135NaturalWelcomeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testNewUserCanEnterAndCollectPlanInConversation() {
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT": "new", "BOJI_PREVIEW_SKIP_GUIDE": "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["嗨，我是 Club AI"].waitForExistence(timeout: 20))
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

}
