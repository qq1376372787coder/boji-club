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
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The retired five-tab shell must not be reachable")
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
        app.segmentedControls["v2-mode-picker"].buttons[title]
    }

    private func selectMode(_ title: String, in app: XCUIApplication) {
        let picker = app.segmentedControls["v2-mode-picker"]
        if picker.exists {
            let button = picker.buttons[title]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap(); XCTAssertTrue(button.isSelected)
        } else {
            let menu = app.buttons["v2-mode-picker"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10), "Large text must use the native mode menu")
            menu.tap()
            let option = app.buttons[title].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
        }
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["v2-composer-field"].firstMatch
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
        XCTAssertTrue(modeButton("Club AI", in: app).isSelected)
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
        let search = app.textFields["exercise-search"]
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
        selectMode("Club AI", in: app)
        XCTAssertTrue(bar.exists)
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
        XCTAssertTrue(app.staticTexts["辛苦了，训练已收官"].exists)
        let review = app.buttons["workout-ai-review"]
        XCTAssertTrue(review.exists && review.isHittable, "AI review must be visible immediately below the metrics")
        attachScreenshot("build125-completion", app: app)
        for _ in 0..<3 where !app.staticTexts["各动作实记组数"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["各动作实记组数"].exists)
        XCTAssertTrue(app.staticTexts["完成 1 / 3 组"].exists)
        attachScreenshot("build125-actual-only-charts", app: app)
    }

    func testUnifiedProfileShowsFactsWithoutCloudMemory() {
        let app = launch()
        openSidebar("aimemory", in: app)
        XCTAssertTrue(app.staticTexts["我的身体资料"].waitForExistence(timeout: 8))
        attachScreenshot("build126-profile-initial", app: app)
        print("PROFILE126-AX " + app.debugDescription)
        let measurement = app.descendants(matching: .any)["profile-latest-measurement"].firstMatch
        for _ in 0..<4 where !measurement.isHittable { app.swipeUp() }
        XCTAssertTrue(measurement.isHittable)
        attachScreenshot("build126-profile-body", app: app)
        let habits = app.staticTexts["我填写的习惯与偏好"]
        for _ in 0..<8 where !habits.isHittable { app.swipeUp() }
        XCTAssertTrue(habits.isHittable)
        XCTAssertTrue(app.staticTexts["我的目标与训练条件"].exists)
        attachScreenshot("build126-profile-goals-habits", app: app)
    }

    func testManagedPlanEditPreviewAndSave() {
        let app = launch(tab: "plans")
        app.buttons["v2-context-action"].tap()
        app.buttons["管理训练计划"].tap()
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
        XCTAssertTrue(app.segmentedControls["v2-mode-picker"].exists)
        XCTAssertLessThanOrEqual(app.navigationBars.count, 1, "Conversation must share the shell navigation layer")
        XCTAssertTrue(composer(app).exists)
        XCTAssertTrue(app.buttons["v2-composer-plus"].exists)
        attachScreenshot("native-conversation-single-navigation", app: app)
    }

    func testRecordsTrendScales() {
        let app = launch(tab: "records")
        XCTAssertTrue(app.staticTexts["多尺度趋势"].waitForExistence(timeout: 8))
        app.buttons["近 12 个月"].tap()
        XCTAssertTrue(app.staticTexts["多尺度趋势"].exists)
    }

    func testCompositionAccessibilityWorkoutAndNutrition() {
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT": "complete", "BOJI_PREVIEW_SKIP_GUIDE": "1", "BOJI_UI_TEST_SEED": "1", "BOJI_AUDIT_SCREEN": "workout", "BOJI_AUDIT_AX": "1"]
        app.launch()
        let firstSet = app.buttons["完成第 1 组"].firstMatch
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
        firstSet.tap()
        XCTAssertTrue(app.buttons["第 1 组已完成，点击撤销完成"].firstMatch.waitForExistence(timeout: 5), "Completing a set must expose the undo state")
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
        XCTAssertTrue(app.buttons["记录体重"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["手动记录饮食"].exists)
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
        let first = app.buttons["完成第 1 组"].firstMatch
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
        let stepper = app.steppers.firstMatch
        XCTAssertTrue(stepper.waitForExistence(timeout: 15))
        stepper.buttons.element(boundBy: 1).tap()
        app.navigationBars.buttons["保存"].tap()
        let confirm = app.buttons["保存资料与目标"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.staticTexts["资料和营养目标已生效，现有训练安排保留。"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["制定计划"].exists)
    }

    func testUnstartedPlanCanBeDeletedFromMyPlans() {
        let app = launchAudit("training-plans")
        let menu = app.buttons["管理这份计划"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15)); menu.tap()
        let remove = app.buttons["删除计划"]
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
        let picker = app.segmentedControls["v2-mode-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "The mode control must be a native segmented picker")
        XCTAssertTrue(modeButton("Club AI", in: app).isSelected)
        XCTAssertTrue(app.buttons["v2-context-action"].exists)
        XCTAssertTrue(composer(app).exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        selectMode("训练", in: app)
        XCTAssertTrue(app.buttons["plan-calendar-toggle"].waitForExistence(timeout: 8))
        XCTAssertFalse(composer(app).isHittable, "Composer must not intercept training input")
        XCTAssertLessThanOrEqual(app.navigationBars.count, 1)
        selectMode("Club AI", in: app)
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
        for route in ["records", "club", "aimemory", "profile", "settings"] {
            let entry = app.buttons["v2-sidebar-" + route]
            revealSidebarEntry(entry, in: app)
        }
        app.buttons["v2-sidebar-close"].tap()
        openSidebar("records", in: app)
        XCTAssertTrue(app.segmentedControls["records-category-picker"].waitForExistence(timeout: 8))
        app.buttons["关闭"].firstMatch.tap()
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
            selectMode("Club AI", in: app)
        }
        let restored = composer(app)
        XCTAssertTrue(restored.waitForExistence(timeout: 8))
        XCTAssertEqual(restored.value as? String, "今天练什么", "Composer draft must survive mode switches")
    }

    func testV2MemoryPageOpensForPreviewAccount() {
        // Phase 4 §5.2：记忆页（预览账号 = 占位说明）。
        let app = launchV2()
        openSidebar("aimemory", in: app)
        let memoryPage = app.descendants(matching: .any)["ai-memory-page"]
        XCTAssertTrue(memoryPage.waitForExistence(timeout: 10), "memory page should open")
        let memoryNotice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "预览账号没有云端记忆")).firstMatch
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
        modeButton("Club AI", in: app).tap()
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
        let firstSet = app.buttons["完成第 1 组"].firstMatch
        XCTAssertTrue(firstSet.waitForExistence(timeout: 10), "The workout table should be ready")
        // 完整走完并清理：不结束训练会把 active workout 留给后续测试
        //（工作台出现恢复条，且其文案过不了对比度审计——testV2WorkspaceAccessibilityAudit 曾因此失败）。
        firstSet.tap()
        let finish = app.buttons["结束并保存本次训练"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.tap()
        app.buttons["结束并保存已完成的部分"].tap()
        XCTAssertTrue(app.navigationBars["训练完成"].waitForExistence(timeout: 8), "The card-started workout should finish through the normal save flow")
    }

    func testV2ComposerKeyboardAvoidance() {
        let app = launchV2()
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        // 键盘弹起后：输入框与发送按钮必须保持可见可点（UI 规范 D5/矩阵"键盘/多行输入"）。
        XCTAssertTrue(field.waitForExistence(timeout: 5) && field.isHittable, "Composer must stay visible with keyboard up")
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
        let keep = app.buttons["保存草稿并开始新对话"]
        XCTAssertTrue(keep.waitForExistence(timeout: 8))
        keep.tap()
        XCTAssertFalse((composer(app).value as? String ?? "").contains(text))
        app.buttons["v2-sidebar-toggle"].tap()
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
        XCTAssertTrue(app.buttons["记录体重"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["手动记录饮食"].exists)
        app.buttons["记录体重"].tap()
        XCTAssertTrue(app.navigationBars["身体记录"].waitForExistence(timeout: 8))
    }

    func testNativeShellIgnoresRetiredHomeSwitch() {
        let app = XCUIApplication()
        app.launchEnvironment = ["BOJI_PREVIEW_ACCOUNT": "complete", "BOJI_PREVIEW_SKIP_GUIDE": "1", "BOJI_UI_TEST_SEED": "1", "BOJI_V2_SHELL": "0"]
        app.launch()
        XCTAssertTrue(app.segmentedControls["v2-mode-picker"].waitForExistence(timeout: 15))
        XCTAssertTrue(composer(app).exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "A retired switch must never restore the legacy shell")
    }

    func testNativeShellScreenshots() {
        let app = launch()
        attachScreenshot("native-ai-home", app: app)
        selectMode("训练", in: app)
        XCTAssertTrue(app.buttons["plan-calendar-toggle"].waitForExistence(timeout: 8))
        attachScreenshot("native-training-workspace", app: app)
        selectMode("Club AI", in: app)
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
        XCTAssertTrue(app.segmentedControls["v2-mode-picker"].waitForExistence(timeout: 15))
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
        // 侧栏关闭时 app 级审计（无遮挡，全部元素真实渲染）。
        try app.performAccessibilityAudit { audit("workspace", $0) }
        app.buttons["v2-sidebar-toggle"].tap()
        XCTAssertTrue(app.buttons["v2-sidebar-newchat"].waitForExistence(timeout: 8))
        // 侧栏打开后：app 级审计会连被不透明面板遮挡的工作台元素一起测，按面板
        // 像素量出假对比度失败（全量回归实测）。用 isHittable 区分：被面板盖住的
        // 元素不可命中（其发现记为遮挡量测伪影，仅打印），可命中的发现仍是硬失败。
        let sidebarScope = true
        try app.performAccessibilityAudit { audit("sidebar", $0, requireHittable: sidebarScope) }
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
        XCTAssertTrue(app.segmentedControls["v2-mode-picker"].waitForExistence(timeout: 15))
        selectMode("训练", in: app)
        let start = app.buttons["开始训练"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 8), "Training home must offer start")
        start.tap()
        let collapse = app.buttons["v2-workout-collapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 10))
        collapse.tap()
        let miniBar = app.descendants(matching: .any)["mini-workout-bar"].firstMatch
        XCTAssertTrue(miniBar.waitForExistence(timeout: 8), "Collapsed workout must show the mini bar")
        selectMode("Club AI", in: app)

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
        let firstSet = app.buttons["完成第 1 组"].firstMatch
        XCTAssertTrue(firstSet.waitForExistence(timeout: 10), "Reopening the workout must show the set table")
        firstSet.tap()
        let finish = app.buttons["结束并保存本次训练"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.tap()
        app.buttons["结束并保存已完成的部分"].tap()
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
        let nativePicker = app.segmentedControls["v2-mode-picker"]
        if nativePicker.waitForExistence(timeout: 3) {
            nativePicker.buttons["训练"].tap()
        } else {
            let training = app.buttons["v2-mode-training"]
            XCTAssertTrue(training.waitForExistence(timeout: 8))
            training.tap()
        }
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
        let manual = app.buttons["手动记录饮食"]
        XCTAssertTrue(manual.waitForExistence(timeout: 5))
        manual.tap()
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
        app.navigationBars["身体记录"].buttons["完成"].tap()
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
        XCTAssertTrue(reply.waitForExistence(timeout: 12))
        XCTAssertTrue(reply.label.contains("长回复末尾可见检查127"))
        if app.buttons["回到最新"].exists { app.buttons["回到最新"].tap() }
        // Check the actual message frame against the actual composer, then repeat with keyboard.
        sleep(1)
        XCTAssertLessThanOrEqual(reply.frame.maxY, field.frame.minY - 4)
        field.tap(); field.typeText("继续")
        sleep(1)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertLessThanOrEqual(reply.frame.maxY, field.frame.minY - 4)
        XCTAssertTrue(app.buttons["v2-composer-send"].isHittable)
        attachScreenshot("build127-long-reply-keyboard", app: app)
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
        for title in ["身体", "报告", "训练", "饮食"] {
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
    func testNewUserAndAIKnowledgeUseSameProfile() {
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
