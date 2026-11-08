import XCTest

/// 性能基线用例：与 docs/native-ui-20261024/performance/ 里 2026-10-24 的旧基线同口径。
///
/// 编译进 BojiClubUITests，由 CI 在 SE3 模拟器上跑 xcodebuild test，
/// 结果导出成 xcresult + JSON 供测试验收做前后对比。
///
/// 注意：选择器依赖界面结构。当前批次正在把 mode picker 换成三 tab，
/// 若用例跑挂，说明选择器需要跟着新结构更新（业务断言不删，只改定位）。
final class BojiClubPerformanceTests: XCTestCase {

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "BOJI_PREVIEW_ACCOUNT": "complete",
            "BOJI_PREVIEW_SKIP_GUIDE": "1",
            "BOJI_UI_TEST_SEED": "1",
            "BOJI_V2_SHELL": "1"
        ]
        return app
    }

    /// 冷启动耗时：5 次测量，取系统给出的平均。
    func testLaunchBenchmark() {
        let app = launchApp()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            app.launch()
        }
    }

    /// 滚动性能：训练页可见滚动视图上下滑动，采集 signpost/时钟/内存/CPU 四项。
    func testScrollBenchmark() {
        let app = launchApp()
        app.launch()
        XCTAssertTrue(app.buttons["v2-sidebar-toggle"].waitForExistence(timeout: 15))

        // 新结构是三 tab 栏，旧结构是分段选择器；两者任一存在即可。
        let tab = app.tabBars.buttons["训练"]
        let picker = app.segmentedControls["v2-mode-picker"]
        if tab.waitForExistence(timeout: 5) {
            tab.tap()
        } else if picker.waitForExistence(timeout: 5) {
            picker.buttons["训练"].tap()
        } else {
            let legacy = app.buttons["v2-mode-training"]
            XCTAssertTrue(legacy.waitForExistence(timeout: 8), "训练入口不存在：新 tab 与旧选择器都没找到")
            legacy.tap()
        }

        XCTAssertTrue(app.buttons["plan-calendar-toggle"].waitForExistence(timeout: 8))

        guard let scroll = app.scrollViews.allElementsBoundByIndex.first(where: {
            $0.frame.intersects(app.frame) && $0.isHittable
        }) else {
            XCTFail("当前可见的滚动视图不存在，无法测量滚动性能")
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
}
