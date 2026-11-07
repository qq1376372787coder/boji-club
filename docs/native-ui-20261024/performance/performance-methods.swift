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
