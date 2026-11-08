import XCTest
@testable import BojiClub

/// 跨页数字对账（D1–D7）。
///
/// 依据：`docs/product/数据口径统一表-v1.md` §六。
/// 目的：把「同一天两个数」钉死——首页、日报、周报、趋势读同一个指标必须相等。
///
/// **状态（2026-11-09）**：苹果开发提交 `7a276b1` 已修下列 5 条。本文件断言的是**正确行为**，
/// 修完后应全绿；**任何一条仍红 = 修复不到位或回退**，由测试验收重跑确认后才关单。
///
/// 曾红、现已修（5 条）：
///   · `testD5_InvalidWeightIsMissingNotShown`      — 日报曾把非法体重（500kg）当数报出 → 改走 `measuredKilograms`
///   · `testD6_TrendSeesEveryRecordedMeasurement`   — 趋势页曾只认单条 bodyWeight → 改走 `BodyWeightReading.rows`
///   · `testUnsavedSessionVolumeIsNotCounted`       — 未保存场次曾被算进当日训练量（**会上屏**）→ 改走 `confirmedTraining.volume`
///   · `ReadinessScoreContractTests.testBreakdownComponentsSumToTotal` — 分项之和曾 ≠ 巨号总分（差 1）→ 总分改由已取整分项相加
///   · `testD3_MealWithoutNutritionIsMissingNotZero` — 曾报 0 kcal（更早修，转防回归）
///
/// **周报侧已接真调用**：`WeeklyMetricsCalculator.compute(state:start:end:)`（WeeklyReportView.swift:553），
/// D2 / D4 / D6 / D7 全部走它，不再是参考实现（Chief 定：参考实现一律不算过）。
///
/// 夹具期望值已由测试验收逐项核到源码：训练量 600 kg·次、摄入 1550 kcal、训练时长 30 分钟、体重 70.2 kg。
///
/// 跑法：
///     xcodebuild test -scheme BojiClub -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
///       -only-testing:BojiClubTests/CrossPageParityTests
///
/// 口径：整数化后允许 ±1；空值两边必须同为 nil（不许一边 0 一边「—」）。
final class CrossPageParityTests: XCTestCase {

    // MARK: - 断言工具

    /// 两个数字是否「同一个数」：整数化后允许 ±1；一边有值一边没值 = 失败。
    private func assertSameNumber(_ lhs: Double?, _ rhs: Double?,
                                  _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        switch (lhs, rhs) {
        case (nil, nil):
            return
        case let (l?, r?):
            XCTAssertEqual(Int(l.rounded()), Int(r.rounded()), "\(label)：\(l) ≠ \(r)", file: file, line: line)
        default:
            XCTFail("\(label)：一边有值一边没值（\(String(describing: lhs)) / \(String(describing: rhs))）",
                    file: file, line: line)
        }
    }

    /// 整数版（同上）。
    private func assertSameNumber(_ lhs: Int?, _ rhs: Int?,
                                  _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        switch (lhs, rhs) {
        case (nil, nil):
            return
        case let (l?, r?):
            XCTAssertEqual(l, r, "\(label)：\(l) ≠ \(r)", file: file, line: line)
        default:
            XCTFail("\(label)：一边有值一边没值（\(String(describing: lhs)) / \(String(describing: rhs))）",
                    file: file, line: line)
        }
    }

    // MARK: - 夹具

    /// 一天：3 组 × (20kg × 10 次) 已确认训练 + 三餐全有营养 + 一次称重。
    /// 训练量 = 3 × 20 × 10 = 600 kg·次；摄入 = 420 + 650 + 480 = 1550 kcal；训练时长 = 30 分钟。
    private func makeDay(today: Date) -> DayLog {
        let calendar = ClubDates.calendar
        let dayStart = calendar.startOfDay(for: today)
        let session = UUID()
        var day = DayLog()
        day.exercises = [Exercise(name: "哑铃卧推", muscle: "胸",
                                  sets: (0..<3).map { _ in TrainingSet(weight: 20, reps: 10, completed: true) },
                                  libraryID: "0025", workoutSessionID: session)]
        day.workoutSessions = [WorkoutSession(id: session,
                                              startedAt: dayStart.addingTimeInterval(3600),
                                              endedAt: dayStart.addingTimeInterval(5400),
                                              savedAt: dayStart.addingTimeInterval(5400))]
        day.workoutStartedAt = dayStart.addingTimeInterval(3600)
        day.workoutEndedAt = dayStart.addingTimeInterval(5400)
        day.workoutSavedAt = dayStart.addingTimeInterval(5400)
        day.meals = [
            Meal(name: "早餐", category: "早餐", calories: 420, protein: 26, carbs: 48, fat: 14),
            Meal(name: "午餐", category: "午餐", calories: 650, protein: 45, carbs: 72, fat: 19),
            Meal(name: "晚餐", category: "晚餐", calories: 480, protein: 36, carbs: 42, fat: 18)
        ]
        day.bodyWeight = BodyWeightEntry(kilograms: 70.2, updatedAt: dayStart.addingTimeInterval(28800),
                                         recordedAt: dayStart.addingTimeInterval(28800))
        return day
    }

    private func makeState(days: [String: DayLog]) -> SavedState {
        var state = SavedState()
        for (key, day) in days { state.days[key] = day }
        return state
    }

    /// 今天页显示的摄入热量（**真调用**，不是复刻）。
    ///
    /// 口径表 §二裁定：空值不是 0 —— 无已知营养餐时读出层一律显示「—」。
    /// 这里直接用 `DayLog.knownMeals` + `DayLog.calories` 组合，
    /// 与 `ProductArchitecture.swift:684` 的判空同源（那边就是 `knownMeals.isEmpty ? "—" : "\(Int(todayCalories))"`）。
    /// 苹果开发若把判空抽成公共函数（如 `NutritionFacts.displayedCalories(log:)`），
    /// 把这里换成真调用即可（见文件末尾待办第 4 条）。
    private func todayPageCalories(_ day: DayLog) -> Double? {
        day.knownMeals.isEmpty ? nil : day.calories
    }

    /// 日报显示的摄入热量。
    private func dailyReportCalories(_ day: DayLog, today: Date) -> Double? {
        day.deterministicMetrics(dateKey: ClubDates.key(today)).nutrition?.calories
    }

    // MARK: - D1 训练量：今天页 = 日报

    /// 今天页读 `DayLog.confirmedTraining.volume`（ProductArchitecture.swift:622）；
    /// 日报读 `deterministicMetrics().training?.total_volume_kg`（Models.swift:352）。
    /// 两者今天同源，恒等——D1 是防止将来有人在一边另算。
    func testD1_TodayTrainingVolumeMatchesDailyReport() {
        let today = Date()
        let day = makeDay(today: today)

        let todayPageValue = day.confirmedTraining.volume
        let dailyReportValue = day.deterministicMetrics(dateKey: ClubDates.key(today)).training?.total_volume_kg

        XCTAssertEqual(todayPageValue, 600, accuracy: 0.5, "夹具预期 600 kg·次")
        assertSameNumber(todayPageValue, dailyReportValue, "D1 今天页训练量 vs 日报训练量")
    }

    // MARK: - D2 训练量：今天页 = 周报当日

    /// 周报侧唯一算法 `WeeklyMetricsCalculator.compute`（WeeklyReportView.swift:553）。
    /// 周期取「只有今天」→ 周总量在数学上等于今天页的当日训练量，两条路必须同值。
    func testD2_TodayTrainingVolumeMatchesWeeklyDaySum() {
        let today = Date()
        let day = makeDay(today: today)

        let todayPageValue = day.confirmedTraining.volume

        // 真调用：周报唯一算法（WeeklyReportView.swift:553）。周期取「只有今天」，
        // 于是周总量在数学上就等于今天页的当日训练量——两条路必须给出同一个数。
        let state = makeState(days: [ClubDates.key(today): day])
        let weeklyToday = WeeklyMetricsCalculator.compute(state: state, start: today, end: today)
        let weeklyTodayVolume = weeklyToday.training?.total_volume_kg

        assertSameNumber(todayPageValue, weeklyTodayVolume, "D2 今天页训练量 vs 周报（真调用）")
    }

    // MARK: - D3 摄入热量：今天页 = 日报

    func testD3_TodayCaloriesMatchDailyReport() {
        let today = Date()
        let day = makeDay(today: today)

        XCTAssertEqual(day.calories, 1550, accuracy: 0.5, "夹具预期 1550 kcal")
        assertSameNumber(todayPageCalories(day), dailyReportCalories(day, today: today),
                         "D3 今天页摄入热量 vs 日报摄入热量")
    }

    /// 回归防护：有餐但全都没填营养 → 首页显示「—」，日报也必须是「没数」。
    /// 根因：`Models.swift:356` 曾用 `hasMealRecords`（有餐就算）判断非空，却取 `calories`（只算已知营养餐），
    /// 导致日报报「摄入热量 0 kcal」。**已修**：`Models.swift:358` 现为 `knownMeals.isEmpty ? nil : calories`。
    /// 本条转为**防回归**，防止有人把判空改回去。
    func testD3_MealWithoutNutritionIsMissingNotZero() {
        let today = Date()
        var day = DayLog()
        day.meals = [Meal(name: "拍了个照没填数值", category: "午餐",
                          calories: 0, protein: 0, carbs: 0, fat: 14, nutritionKnown: false)]

        XCTAssertNil(todayPageCalories(day), "今天页：无已知营养餐时显示「—」")
        XCTAssertNil(dailyReportCalories(day, today: today),
                     "日报：无已知营养餐时不应报 0（Models.swift:358 已改为 knownMeals.isEmpty ? nil : calories）")
    }

    // MARK: - D4 日均热量：周报 = 趋势页

    /// 统一口径：分母 = **有已知营养记录的天数**（口径表 §二裁定）。
    /// 周报唯一算法 `WeeklyMetricsCalculator.compute`（WeeklyReportView.swift:553，
    /// 分母已改为 `daysWithKnownMeals`）与趋势页（TrendAnalysis.swift:506）必须同值。
    func testD4_TrendAverageCaloriesMatchesCanonicalDenominator() {
        let today = Date()
        let calendar = ClubDates.calendar
        var days: [String: DayLog] = [:]

        // 3 天有已知营养餐（各 1000 kcal），1 天只有一餐没填营养（分母分歧点）
        for offset in 0..<4 {
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            var day = DayLog()
            if offset == 3 {
                day.meals = [Meal(name: "没填数值", category: "晚餐",
                                  calories: 0, protein: 0, carbs: 0, fat: 0, nutritionKnown: false)]
            } else {
                day.meals = [Meal(name: "午餐", category: "午餐", calories: 1000, protein: 40, carbs: 60, fat: 15)]
            }
            days[ClubDates.key(date)] = day
        }
        let state = makeState(days: days)

        // 规则基准（文档化，不作为被测对象）：分子 = Σ 已知营养热量，分母 = 有已知营养的天数
        var numerator = 0.0
        var denominator = 0
        for day in days.values where !day.knownMeals.isEmpty {
            numerator += day.calories
            denominator += 1
        }
        let canonicalAverage = denominator > 0 ? numerator / Double(denominator) : nil
        XCTAssertEqual(canonicalAverage ?? 0, 1000, accuracy: 0.5, "夹具预期日均 1000 kcal")

        // 真调用 1：周报唯一算法，周期取覆盖这 4 天的区间
        let weekStart = calendar.date(byAdding: .day, value: -3, to: today) ?? today
        let weekly = WeeklyMetricsCalculator.compute(state: state, start: weekStart, end: today)
        assertSameNumber(weekly.nutrition?.average_calories, canonicalAverage,
                         "D4 周报日均摄入（真调用）vs 规则基准")

        // 真调用 2：趋势页（同一区间按日分桶）
        let series = ReviewTrendRules.series(state: state, scale: .custom(start: weekStart, end: today),
                                             metric: .calories, now: today)
        let trendAverage = series.points.isEmpty
            ? nil
            : series.points.map(\.value).reduce(0, +) / Double(series.points.count)
        assertSameNumber(canonicalAverage, trendAverage, "D4 趋势页热量日均 vs 规则基准")
    }

    /// 周报日均必须与统一口径一致（分母统一为 knownMeals 非空的天数）。
    /// 修复前周报分母用 `daysWithMeals`（有餐的天数，含没填营养的），会把日均拉低。
    func testD4_WeeklyAverageCaloriesUsesKnownNutritionDaysAsDenominator() {
        let today = Date()
        let calendar = ClubDates.calendar
        var days: [String: DayLog] = [:]

        for offset in 0..<4 {
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            var day = DayLog()
            if offset == 3 {
                day.meals = [Meal(name: "没填数值", category: "晚餐",
                                  calories: 0, protein: 0, carbs: 0, fat: 0, nutritionKnown: false)]
            } else {
                day.meals = [Meal(name: "午餐", category: "午餐", calories: 1000, protein: 40, carbs: 60, fat: 15)]
            }
            days[ClubDates.key(date)] = day
        }

        // 正确分母：knownMeals 非空的天数 = 3
        let knownNutritionDays = days.values.filter { !$0.knownMeals.isEmpty }.count
        // 错误分母：有餐的天数 = 4（修复前 WeeklyReportView.swift:588 + 549 用的就是这个）
        let daysWithAnyMeal = days.values.filter { !$0.meals.isEmpty }.count

        XCTAssertEqual(knownNutritionDays, 3)
        XCTAssertEqual(daysWithAnyMeal, 4, "两个分母在这里会差一天，正是日均对不上的原因")

        // 真调用：周报唯一算法必须给出 1000（分母 3），不是 750（分母 4）
        let weekStart = calendar.date(byAdding: .day, value: -3, to: today) ?? today
        let weekly = WeeklyMetricsCalculator.compute(state: makeState(days: days), start: weekStart, end: today)
        XCTAssertEqual(weekly.nutrition?.average_calories ?? 0, 1000, accuracy: 0.5,
                       "周报日均必须按「有已知营养的天数」求（3 天），不是「有餐的天数」（4 天）")

        // 旧分母会算出 750 —— 钉死这个错值，防止它悄悄回来
        let numerator = days.values.reduce(0.0) { $0 + $1.calories }
        let legacyAverage = numerator / Double(daysWithAnyMeal)
        XCTAssertEqual(legacyAverage, 750, accuracy: 0.5, "旧分母的错值（用于钉死该缺陷）")
    }

    // MARK: - D5 体重：记录页 = 日报

    func testD5_RecordedWeightMatchesDailyReport() {
        let today = Date()
        let day = makeDay(today: today)
        let state = makeState(days: [ClubDates.key(today): day])

        let recordPageValue = BodyWeightHistory.points(days: state.days, through: today, limit: 30).last?.kilograms
        let dailyReportValue = day.deterministicMetrics(dateKey: ClubDates.key(today)).body?.weight_kg

        XCTAssertEqual(recordPageValue ?? 0, 70.2, accuracy: 0.05, "夹具预期 70.2 kg")
        assertSameNumber(recordPageValue, dailyReportValue, "D5 记录页体重 vs 日报今日体重")
    }

    /// 缺陷复现：非法体重（超出 20–400kg 有效范围）记录页不当数，日报却把原值报出来。
    /// 根因：Models.swift:365 用 `bodyWeight?.kilograms`，未过 `measuredKilograms` 的有效性校验。
    func testD5_InvalidWeightIsMissingNotShown() {
        let today = Date()
        var day = DayLog()
        day.bodyWeight = BodyWeightEntry(kilograms: 500, updatedAt: today, recordedAt: today)
        let state = makeState(days: [ClubDates.key(today): day])

        let recordPageValue = BodyWeightHistory.points(days: state.days, through: today, limit: 30).last?.kilograms
        let dailyReportValue = day.deterministicMetrics(dateKey: ClubDates.key(today)).body?.weight_kg

        XCTAssertNil(recordPageValue, "记录页：非法体重不显示")
        XCTAssertNil(dailyReportValue, "日报：非法体重不应报出来（Models.swift:365 需改用 measuredKilograms）")
    }

    // MARK: - D6 体重变化：首页 = 周报 = 趋势

    /// 统一口径：最近 7 次有效测量的首尾差（口径表 §四裁定）。
    /// 首页现在是 14 天窗口首尾差（ProductArchitecture.swift:457/526），
    /// 周报是区间首尾差且趋势判定阈值 3 次与差值阈值 2 次不一致（WeeklyReportView.swift:556-567），
    /// 趋势页是月桶平均（TrendAnalysis.swift:508）——三套算法，必须收敛成一个。
    func testD6_WeightChangeIsUnifiedAcrossPages() {
        let today = Date()
        let calendar = ClubDates.calendar
        var days: [String: DayLog] = [:]

        // 5 次测量：70.0 → 69.4 → 69.6 → 69.2 → 68.9（首尾差 -1.1）
        let weights: [Double] = [70.0, 69.4, 69.6, 69.2, 68.9]
        for (index, kg) in weights.enumerated() {
            let date = calendar.date(byAdding: .day, value: -(weights.count - 1 - index), to: today) ?? today
            days[ClubDates.key(date)] = DayLog(bodyWeight: BodyWeightEntry(kilograms: kg, updatedAt: date, recordedAt: date))
        }
        let state = makeState(days: days)

        // 统一口径：最近 7 次有效测量的首尾差
        let points = BodyWeightHistory.points(days: state.days, through: today, limit: 30)
        let recent = Array(points.suffix(7))
        let unifiedDelta = recent.count >= 2 ? (recent.last!.kilograms - recent.first!.kilograms) : nil
        XCTAssertEqual(unifiedDelta ?? 0, -1.1, accuracy: 0.05, "夹具预期首尾差 -1.1 kg")

        // 首页：ProductArchitecture.swift:526 的 14 天窗口首尾差——必须与统一口径一致
        let homeHistory = ClubDashboardFacts.weightHistory(days: state.days, healthDays: [:], through: today)
        let homeDelta = homeHistory.count >= 2 ? homeHistory.last!.weight - homeHistory.first!.weight : nil
        assertSameNumber(homeDelta, unifiedDelta, "D6 首页体重变化 vs 统一口径")

        // 真调用：周报唯一算法（体重样本走 BodyWeightReading.rows，当日多条都计入），
        // 周期覆盖这 5 次测量 → 首尾差必须与统一口径一致
        let weekStart = calendar.date(byAdding: .day, value: -4, to: today) ?? today
        let weekly = WeeklyMetricsCalculator.compute(state: state, start: weekStart, end: today)
        assertSameNumber(weekly.body?.weight_change_kg, unifiedDelta, "D6 周报体重变化（真调用）vs 统一口径")

        // 方向判定的样本阈值：差值 ≥2 次给值，≥3 次才给方向，两处必须一致
        XCTAssertEqual(recent.count >= 2, true, "差值阈值：2 次")
        XCTAssertEqual(recent.count >= 3, true, "方向阈值：3 次")
    }

    /// **体重趋势阈值统一**：≥2 次给差值，≥3 次才给方向（口径表 §四裁定）。
    /// 现状：首页与周报各写一套（2 次 / 3 次混用），同一段数据两处判定可能不同。
    func testWeightTrendThresholdsAreUnified() {
        let today = Date()
        let calendar = ClubDates.calendar
        func key(_ offset: Int) -> String {
            ClubDates.key(calendar.date(byAdding: .day, value: -offset, to: today) ?? today)
        }
        func day(kg: Double, offset: Int) -> DayLog {
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return DayLog(bodyWeight: BodyWeightEntry(kilograms: kg, updatedAt: date, recordedAt: date))
        }

        // 恰好 2 次测量：给差值（-1.0），但不给方向
        var two: [String: DayLog] = [key(1): day(kg: 70.0, offset: 1), key(0): day(kg: 69.0, offset: 0)]
        let twoState = makeState(days: two)
        let twoStart = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let twoWeek = WeeklyMetricsCalculator.compute(state: twoState, start: twoStart, end: today)
        XCTAssertEqual(twoWeek.body?.weight_change_kg, -1.0, accuracy: 0.05, "2 次测量给差值")
        XCTAssertEqual(twoWeek.body?.weight_trend, "insufficient_data", "2 次测量不给方向（阈值 3）")

        // 只有 1 次测量：差值也不给
        var one: [String: DayLog] = [key(0): day(kg: 69.0, offset: 0)]
        let oneState = makeState(days: one)
        let oneWeek = WeeklyMetricsCalculator.compute(state: oneState, start: today, end: today)
        XCTAssertNil(oneWeek.body?.weight_change_kg, "1 次测量不给差值")
        XCTAssertEqual(oneWeek.body?.weight_trend, "insufficient_data")
    }

    /// **首页体重变化的窗口 = 近 14 天**（不是全部历史）。
    ///
    /// 口径表 §4.4 裁定：窗口不必统一（首页 14 天 / 周报本周期 / 趋势按桶），
    /// 但**必须标明**，且**同屏的图与数字要说同一个窗口**。
    ///
    /// 本用例钉住实现事实：`ClubDashboardFacts.weightHistory` 取近 14 天，
    /// 防止有人把它改成全历史——那会与同屏图表的 14 天窗口自相矛盾。
    func testHomeWeightDeltaUsesFourteenDayWindow() {
        let today = Date()
        let calendar = ClubDates.calendar
        var days: [String: DayLog] = [:]
        for (offset, kg) in [(0, 68.0), (10, 69.0), (30, 75.0)] {
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            days[ClubDates.key(date)] = DayLog(bodyWeight: BodyWeightEntry(kilograms: kg, updatedAt: date, recordedAt: date))
        }
        let state = makeState(days: days)

        let history = ClubDashboardFacts.weightHistory(days: state.days, healthDays: [:], through: today)
        XCTAssertEqual(history.count, 2, "14 天窗口只应含今天与 10 天前两点，实际 \(history.count)")
        XCTAssertFalse(history.contains { $0.weight == 75.0 }, "30 天前的测量不得进入 14 天窗口")
        XCTAssertEqual(history.last!.weight - history.first!.weight, -1.0, accuracy: 0.05,
                       "首页 delta = 近 14 天首尾差（68.0 − 69.0）")
    }

    /// 缺陷复现：一天里有多条称重记录时，趋势页只认单条 `bodyWeight`，漏掉 `bodyMeasurements`。
    /// 根因：TrendAnalysis.swift:476 用 `day.bodyWeight?.measuredKilograms`，
    /// 而记录页权威来源是 `BodyWeightHistory.points`（DailyExperience.swift:287，取当日全部有效测量）。
    func testD6_TrendSeesEveryRecordedMeasurement() {
        let today = Date()
        let dayStart = ClubDates.calendar.startOfDay(for: today)
        let morning = BodyWeightEntry(kilograms: 70.0, updatedAt: dayStart.addingTimeInterval(28800),
                                      recordedAt: dayStart.addingTimeInterval(28800))
        let evening = BodyWeightEntry(kilograms: 69.8, updatedAt: dayStart.addingTimeInterval(61200),
                                      recordedAt: dayStart.addingTimeInterval(61200))
        var day = DayLog()
        day.bodyMeasurements = [morning, evening]
        day.bodyWeight = morning
        let state = makeState(days: [ClubDates.key(today): day])

        let recordPagePoints = BodyWeightHistory.points(days: state.days, through: today, limit: 30)
        XCTAssertEqual(recordPagePoints.count, 2, "记录页应看到当日两条测量")

        let series = ReviewTrendRules.series(state: state, scale: .custom(start: dayStart, end: today),
                                              metric: .weight, now: today)
        let trendValue = series.points.last?.value
        let latestMeasurement = recordPagePoints.last?.kilograms
        assertSameNumber(latestMeasurement, trendValue, "D6 趋势页体重点 vs 记录页最新测量")
    }

    // MARK: - D7 训练时长：训练完成页 = 日报

    /// 日报训练时长来自 `deterministicMetrics().training?.duration_minutes`（Models.swift:343），
    /// 训练完成页读 `confirmedTraining.elapsedSeconds`。
    /// 修复前 343 行是「有耗时用耗时，否则用计时秒数」的一字段两义，周报又是另一套。
    func testD7_TrainingDurationMatchesDailyReport() {
        let today = Date()
        let day = makeDay(today: today)

        let completionPageSeconds = day.confirmedTraining.elapsedSeconds
        let dailyReportMinutes = day.deterministicMetrics(dateKey: ClubDates.key(today)).training?.duration_minutes

        XCTAssertEqual(completionPageSeconds, 1800, "夹具预期 1800 秒")
        assertSameNumber(Double(completionPageSeconds) / 60.0,
                         dailyReportMinutes.map(Double.init),
                         "D7 训练完成页时长 vs 日报训练时长")
    }

    /// 缺陷复现：周报时长「每日先整除再累加」。
    /// 7 次 90 秒 = 630 秒 = 10.5 分钟；每日先整除会算成 7 分钟。
    /// 根因：WeeklyReportView.swift:544。
    func testD7_WeeklyDurationSumsSecondsBeforeConverting() {
        let today = Date()
        let calendar = ClubDates.calendar
        var days: [String: DayLog] = [:]

        for offset in 0..<7 {
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let dayStart = calendar.startOfDay(for: date)
            let session = UUID()
            var day = DayLog()
            day.exercises = [Exercise(name: "平板支撑", muscle: "核心",
                                      sets: [TrainingSet(weight: 0, reps: 1, completed: true, durationSeconds: 90)],
                                      libraryID: "0043", workoutSessionID: session)]
            day.workoutSessions = [WorkoutSession(id: session,
                                                  startedAt: dayStart.addingTimeInterval(3600),
                                                  endedAt: dayStart.addingTimeInterval(3690),
                                                  savedAt: dayStart.addingTimeInterval(3690))]
            day.workoutStartedAt = dayStart.addingTimeInterval(3600)
            day.workoutEndedAt = dayStart.addingTimeInterval(3690)
            day.workoutSavedAt = dayStart.addingTimeInterval(3690)
            days[ClubDates.key(date)] = day
        }
        let state = makeState(days: days)

        // 真调用：周报唯一算法必须「先累加秒，最后一次性换算」→ 630 秒 = 10 分钟
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let weekly = WeeklyMetricsCalculator.compute(state: state, start: weekStart, end: today)
        XCTAssertEqual(weekly.training?.total_duration_minutes, 10,
                       "真调用：先累加秒再换算 → 630 秒 = 10 分钟")

        // 钉死旧错值（逐日先整除），防止它悄悄回来
        var perDayFlooredMinutes = 0
        for day in days.values {
            let confirmed = day.confirmedTraining
            if confirmed.hasTraining && confirmed.elapsedSeconds > 0 {
                perDayFlooredMinutes += confirmed.elapsedSeconds / 60
            }
        }
        XCTAssertEqual(perDayFlooredMinutes, 7, "旧实现的错值：90 秒 → 1 分钟 × 7 = 7 分钟（用于钉死该缺陷）")
    }

    /// **契约语义：`duration_minutes` 只表示「场次墙钟时长」，不许拿计时秒数冒充。**
    ///
    /// 修复前 `Models.swift:346` 是「有 elapsed 用 elapsed，否则用 timed」——一字段两含义：
    /// 同一个 `duration_minutes` 在正常数据里是墙钟时长，在遗留数据里却变成计时秒数，
    /// 日报和周报拿到的是两个意思的数。
    ///
    /// 裁定（产品经理）：去掉 timed 兜底分支，`duration_minutes` = `elapsed > 0 ? elapsed/60 : nil`；
    /// 要显示计时时长时客户端自己从 `confirmedTraining.timedSeconds` 算，不进契约、不欠服务端。
    func testTimedOnlyWorkoutDoesNotMasqueradeAsTrainingDuration() {
        let today = Date()
        var day = DayLog()
        // 遗留路径：有保存标记、有完成组，但没有场次起止时间 → elapsed == 0
        day.exercises = [Exercise(name: "平板支撑", muscle: "核心",
                                  sets: [TrainingSet(weight: 0, reps: 1, completed: true, durationSeconds: 60)],
                                  libraryID: "0043")]
        day.workoutSavedAt = today
        // 故意不设 workoutStartedAt / workoutEndedAt

        XCTAssertEqual(day.confirmedTraining.elapsedSeconds, 0, "夹具前提：elapsed 为 0")
        XCTAssertGreaterThan(day.confirmedTraining.timedSeconds, 0, "夹具前提：有计时秒数")

        let metrics = day.deterministicMetrics(dateKey: ClubDates.key(today))
        XCTAssertNil(metrics.training?.duration_minutes,
                     "duration_minutes 只表示场次墙钟时长；elapsed 为 0 时应为 nil，不许拿计时秒数冒充")
    }

    // MARK: - 口径唯一性守卫

    /// **用户可见的训练量只认已保存场次**——未保存的进行中场次不算「今天练了多少」。
    ///
    /// 现状：`TrainingRecordText.measurements`（`DailyExperience.swift:742`）已改用
    /// `log.confirmedTraining.volume`，用户可见串正确。
    ///
    /// 但 `DayLog.volume`（`Models.swift:332`）**仍是宽口径**（只滤 validCompletion，不滤保存状态），
    /// 而且**已无任何读取者**——留着就是一个名字误导的陷阱：将来有人拿它显示，
    /// 未保存场次又会回到用户眼前。**裁定：删掉它（死代码），训练量只留 `confirmedTraining.volume` 一条路。**
    ///
    /// 本用例钉「用户可见串」：已保存 200、未保存 480 → 串里只出现 200。
    func testUnsavedSessionVolumeIsNotCounted() {
        let today = Date()
        let savedSession = UUID()
        let pendingSession = UUID()
        var day = DayLog()
        day.exercises = [
            Exercise(name: "哑铃卧推", muscle: "胸",
                     sets: [TrainingSet(weight: 20, reps: 10, completed: true)],
                     libraryID: "0025", workoutSessionID: savedSession),
            // 未保存的场次：用户还在练，不该进「今天练了多少」
            Exercise(name: "杠铃深蹲", muscle: "腿",
                     sets: [TrainingSet(weight: 60, reps: 8, completed: true)],
                     libraryID: "0043", workoutSessionID: pendingSession)
        ]
        day.workoutSessions = [
            WorkoutSession(id: savedSession, savedAt: today),
            WorkoutSession(id: pendingSession, startedAt: today)   // 无 savedAt = 未保存
        ]

        XCTAssertEqual(day.confirmedTraining.volume, 200, accuracy: 0.5, "已确认训练量只算已保存场次")

        let strings = TrainingRecordText.measurements(day)
        let volumeString = strings.first { $0.contains("训练量") }
        XCTAssertEqual(volumeString, "训练量 200 kg·次", "用户可见串应只含已保存场次的量，实际：\(strings)")
        XCTAssertFalse(strings.contains { $0.contains("480") }, "用户可见串不得出现未保存场次的量：\(strings)")
    }

    /// 未完成的组不得计入训练量。
    func testUncompletedSetsAreExcludedFromVolume() {
        let today = Date()
        let session = UUID()
        var day = DayLog()
        day.exercises = [Exercise(name: "深蹲", muscle: "腿",
                                  sets: [TrainingSet(weight: 50, reps: 5, completed: true),
                                         TrainingSet(weight: 50, reps: 5, completed: false)],
                                  libraryID: "0043", workoutSessionID: session)]
        day.workoutSessions = [WorkoutSession(id: session, savedAt: today)]

        XCTAssertEqual(day.confirmedTraining.volume, 250, accuracy: 0.5, "未完成组不计入")
        XCTAssertEqual(day.confirmedTraining.completedSets, 1, "完成组数只算已完成的")
    }

    /// 计时动作不折算重量（否则会凭空造出训练量）。
    func testTimedSetDoesNotFabricateVolume() {
        let today = Date()
        let session = UUID()
        var day = DayLog()
        day.exercises = [Exercise(name: "平板支撑", muscle: "核心",
                                  sets: [TrainingSet(weight: 20, reps: 1, completed: true, durationSeconds: 60)],
                                  libraryID: "0043", workoutSessionID: session)]
        day.workoutSessions = [WorkoutSession(id: session, savedAt: today)]

        XCTAssertEqual(day.confirmedTraining.volume, 0, accuracy: 0.001, "计时动作不计入训练量")
        XCTAssertEqual(day.confirmedTraining.completedSets, 1, "但完成组数要算")
    }

    /// **两条体重读法必须同结果**——否则记录页与趋势/周报会读出不同的体重，
    /// 正是用户骂的「面板和日报对不上」。
    ///
    /// 现状（`7a276b1` 后）并存两个实现：
    ///   · `BodyWeightHistory.points`（DailyExperience.swift:297）——记录页/首页体重历史
    ///   · `BodyWeightReading.rows`（DailyExperience.swift:282）——趋势/周报/阶段/平台期
    ///
    /// 测试验收源码复核出**三处分歧**（本用例逐条钉住）：
    ///   ① 空数组：`points` 用 `bodyMeasurements ?? [bodyWeight]`（空数组非 nil → 不回落）；
    ///      `rows` 用 `bodyMeasurements?.isEmpty == false ? … : [bodyWeight]`（空数组 → 回落单条）
    ///   ② 墓碑大小写：`rows` 对 `deletedBodyMeasurementIDs` 做 `.lowercased()`，`points` 没做
    ///   ③ 日内排序：`rows` 按 `recordedAt` 排序，`points` 保持数组原序（首尾差会取反）
    ///
    /// Chief 裁定走①：`BodyWeightHistory.points` 直接走 `BodyWeightReading.rows`，只留一个实现；
    /// 三处分歧随之自动消掉。本用例转绿即为收敛完成的证据。
    func testBothWeightReadersAgree() {
        let today = Date()
        let dayStart = ClubDates.calendar.startOfDay(for: today)

        var legacyOnly = DayLog()
        legacyOnly.bodyWeight = BodyWeightEntry(kilograms: 70.0, updatedAt: dayStart, recordedAt: dayStart)

        var emptyArray = DayLog()
        emptyArray.bodyMeasurements = []
        emptyArray.bodyWeight = BodyWeightEntry(kilograms: 70.0, updatedAt: dayStart, recordedAt: dayStart)

        var multi = DayLog()
        multi.bodyMeasurements = [
            BodyWeightEntry(kilograms: 70.0, updatedAt: dayStart.addingTimeInterval(28800),
                            recordedAt: dayStart.addingTimeInterval(28800)),
            BodyWeightEntry(kilograms: 69.8, updatedAt: dayStart.addingTimeInterval(61200),
                            recordedAt: dayStart.addingTimeInterval(61200))
        ]

        // ③ 日内排序：数组原序与 recordedAt 顺序相反
        var unordered = DayLog()
        unordered.bodyMeasurements = [
            BodyWeightEntry(kilograms: 69.8, updatedAt: dayStart.addingTimeInterval(61200),
                            recordedAt: dayStart.addingTimeInterval(61200)),
            BodyWeightEntry(kilograms: 70.0, updatedAt: dayStart.addingTimeInterval(28800),
                            recordedAt: dayStart.addingTimeInterval(28800))
        ]

        // ② 墓碑大小写：删除标记用大写 UUID
        let removedID = UUID()
        var tombstoned = DayLog()
        tombstoned.bodyMeasurements = [
            BodyWeightEntry(kilograms: 70.0, updatedAt: dayStart, id: removedID, recordedAt: dayStart)
        ]
        tombstoned.deletedBodyMeasurementIDs = [removedID.uuidString.uppercased()]

        let cases: [(String, DayLog)] = [
            ("legacy 单条", legacyOnly),
            ("空数组", emptyArray),
            ("多条测量", multi),
            ("日内乱序", unordered),
            ("墓碑大写", tombstoned)
        ]
        for (label, day) in cases {
            let rows = BodyWeightReading.rows(of: day).compactMap(\.measuredKilograms)
            let points = BodyWeightHistory.points(days: [ClubDates.key(today): day],
                                                  through: today, limit: 30).map(\.kilograms)
            XCTAssertEqual(rows, points, "\(label)：两条体重读法结果不一致（rows \(rows) vs points \(points)）")
        }
    }

    /// **三条体重读路必须同结果**——测试验收复核出的第三条：
    /// `ProfileBodyRules126.latestMeasurement`（`ProfilePlanCenter126.swift:81`，「我的/计划中心」页显示路径）。
    ///
    /// 它自拼 `(bodyMeasurements ?? []) + (bodyWeight.map { [$0] } ?? [])`，有两处与唯一读法分歧：
    ///   ① `bodyMeasurements == []` 时**照样回落** bodyWeight（新语义：`[]` = 没有测量，不回落）
    ///   ② 非空时把 `bodyWeight` **再追加一份**取 max——legacy 条时间戳更新时会**盖掉真测量值**
    ///
    /// 用户可见：计划中心显示的体重可能与其它页不同，甚至被一条旧镜像值覆盖。
    /// 修法：改成 `BodyWeightReading.rows(of: day)` 一行（剔墓碑/剔非法/排序都现成）。
    func testAllWeightReadersAgree() {
        let today = Date()
        let dayStart = ClubDates.calendar.startOfDay(for: today)
        let key = ClubDates.key(today)

        // 用例 A：空数组 + legacy 单条 → 第三读路会回落，另两条不会
        var emptyArray = DayLog()
        emptyArray.bodyMeasurements = []
        emptyArray.bodyWeight = BodyWeightEntry(kilograms: 70.0, updatedAt: dayStart, recordedAt: dayStart)

        // 用例 B：真测量 68.0 + legacy 镜像 99.0（时间戳更新）→ 第三读路会取 99.0 盖掉真值
        var shadowed = DayLog()
        shadowed.bodyMeasurements = [
            BodyWeightEntry(kilograms: 68.0, updatedAt: dayStart.addingTimeInterval(28800),
                            id: UUID(),
                            recordedAt: dayStart.addingTimeInterval(28800))
        ]
        shadowed.bodyWeight = BodyWeightEntry(kilograms: 99.0, updatedAt: dayStart.addingTimeInterval(61200),
                                              recordedAt: dayStart.addingTimeInterval(61200))

        for (label, day) in [("空数组+legacy", emptyArray), ("legacy 时间戳更新", shadowed)] {
            let days = [key: day]
            let rows = BodyWeightReading.rows(of: day).compactMap(\.measuredKilograms)
            let points = BodyWeightHistory.points(days: days, through: today, limit: 30).map(\.kilograms)
            let profile = ProfileBodyRules126.latestMeasurement(days, now: today).map(\.value)

            XCTAssertEqual(rows, points, "\(label)：rows vs points 不一致（\(rows) vs \(points)）")
            XCTAssertEqual(rows.last, profile,
                           "\(label)：rows vs 计划中心读法不一致（rows \(rows) vs profile \(String(describing: profile))）")
        }
    }

    /// **第 7 条：日报的体重 / 体脂 / 腰围必须来自同一条测量**（测试验收要求配断言，否则只改不验）。
    ///
    /// 现状（半收敛）：`Models.swift:371` 体重走 `BodyWeightReading.latest`，
    /// 但 `:372/:373` 体脂/腰围仍读 `bodyWeight` 镜像字段。
    /// 云端合并 / 健康导入路径下镜像可能过期 → 同一条日报「体重是新的、体脂是旧的」。
    ///
    /// 修法：加 `BodyWeightReading.latestEntry(_:)`，三字段都取 `rows(of:).last`。
    /// 本用例在「镜像与真测量不一致」的夹具下，钉死三字段同源。
    func testDailyReportBodyMetricsComeFromSameEntry() {
        let today = Date()
        let dayStart = ClubDates.calendar.startOfDay(for: today)

        // 真测量：体重 68.0 / 体脂 20.0 / 腰围 80.0
        var day = DayLog()
        day.bodyMeasurements = [
            BodyWeightEntry(kilograms: 68.0, updatedAt: dayStart.addingTimeInterval(28800),
                            id: UUID(),
                            bodyFatPercentage: 20.0, waistCircumferenceCM: 80.0,
                            recordedAt: dayStart.addingTimeInterval(28800))
        ]
        // 过期的镜像：体重相同，但体脂/腰围是旧值（模拟云合并/健康导入后未刷新）
        day.bodyWeight = BodyWeightEntry(kilograms: 68.0, updatedAt: dayStart.addingTimeInterval(61200),
                                         bodyFatPercentage: 15.0, waistCircumferenceCM: 75.0,
                                         recordedAt: dayStart.addingTimeInterval(61200))

        let latest = BodyWeightReading.rows(of: day).last
        XCTAssertNotNil(latest, "夹具预期至少有一条有效测量")
        // 夹具自检：镜像与真测量必须不同，否则这条用例测不出分歧
        XCTAssertNotEqual(day.bodyWeight?.bodyFatPercentage, latest?.bodyFatPercentage,
                          "夹具要求镜像体脂与真测量不同")

        let metrics = day.deterministicMetrics(dateKey: ClubDates.key(today))
        XCTAssertEqual(metrics.body?.weight_kg, latest?.kilograms, "体重必须取最新有效测量")
        XCTAssertEqual(metrics.body?.body_fat_pct, latest?.bodyFatPercentage,
                       "体脂必须与体重同一条测量（现在读的是 bodyWeight 镜像）")
        XCTAssertEqual(metrics.body?.waist_cm, latest?.waistCircumferenceCM,
                       "腰围必须与体重同一条测量（现在读的是 bodyWeight 镜像）")
    }

    // MARK: - 待办：复刻实现的真调用替换（防复刻漂移）
    //
    // 测试验收审核意见：断言里凡是「复刻页面判空」的地方，都应换成真调用，
    // 否则页面改了、测试还在按旧规则验，会变成假绿。
    //
    // 1) 周报：✅ **已接真调用**。`WeeklyMetricsCalculator.compute(state:start:end:)`
    //    （WeeklyReportView.swift:553）已抽出，D2 / D4 / D6 / D7 全部走它。
    // 2) 今天页摄入：当前 `todayPageCalories` 用 `knownMeals.isEmpty ? nil : calories`，
    //    与 ProductArchitecture.swift:684 同源但仍是复刻。苹果开发若把判空抽成公共函数
    //    （建议 `NutritionFacts.displayedCalories(log:)`），此处换成真调用。
    // 3) 趋势：TrendAnalysis.swift:452 `ReviewTrendRules.series` 已是唯一入口，可直接调（已用）。
    // 4) 首页体重：ClubDashboardFacts.weightHistory 已可调（已用）。
    // 5) 状态分：`ClubAIShell.swift:1423` `scoreBreakdown` 是视图私有方法，
    //    本文件用同规则参考实现作契约基准。抽出后（如 `ReadinessScore.breakdown(...)`）换成真调用。
}

// MARK: - 状态分契约（口径表 §五）

/// 状态分（首页巨号）的算法契约。
///
/// 依据：`docs/product/数据口径统一表-v1.md` §五。
/// 算法出处：`BojiClub/ClubAIShell.swift:1423-1445`（`scoreBreakdown`）。
/// 该函数目前是视图私有方法，本文件用**同规则的独立实现**作为契约基准；
/// 苹果开发把它抽成可测的纯函数后，把 `referenceBreakdown` 换成真调用即可（见文件末尾）。
final class ReadinessScoreContractTests: XCTestCase {

    /// 状态分参考实现（口径表 §五 裁定）：
    /// - 睡眠 ≤50 分：7.5 小时满分，线性给分；没同步到按 0 分算
    /// - 静息心率 ≤30 分：≤65 次/分满分，越高越低，下限 8 分；没同步到按 0 分算
    /// - 近三天训练 ≤20 分：练过 20 分，没练过 6 分（永远有值）
    /// - 睡眠与心率**都**没有 → 整体不显示分数
    private struct Breakdown {
        let total: Int
        let sleep: Int
        let heart: Int
        let training: Int
    }

    private func referenceBreakdown(sleepMinutes: Double?, restingHeartRate: Double?,
                                    trainedRecently: Bool) -> Breakdown? {
        guard sleepMinutes != nil || restingHeartRate != nil else { return nil }
        let sleepPoints: Double = {
            guard let sleep = sleepMinutes, sleep > 0 else { return 0 }
            return min(1.0, sleep / (7.5 * 60)) * 50
        }()
        let heartPoints: Double = {
            guard let rhr = restingHeartRate, rhr > 0 else { return 0 }
            return rhr <= 65 ? 30 : max(8, 30 - (rhr - 65) * 0.8)
        }()
        let trainingPoints: Double = trainedRecently ? 20 : 6
        let total = Int(min(100, max(0, sleepPoints + heartPoints + trainingPoints)))
        return Breakdown(total: total,
                         sleep: Int(sleepPoints.rounded()),
                         heart: Int(heartPoints.rounded()),
                         training: Int(trainingPoints))
    }

    /// 契约一：分项之和必须等于巨号总分（用户会自己加，加不上就是 bug）。
    ///
    /// ⚠️ **这条现在会红**（12 个用例中 3 个对不上），是缺陷复现：
    /// 根因在 `ClubAIShell.swift:1440`——
    ///     total = Int(min(100, max(0, sleepPoints + heartPoints + trainingPoints)))
    /// 总分对**未取整的 Double 求和**再截断，而分项显示各自 `.rounded()` 后取整，
    /// 两者取整时机不同 → 分项加起来比巨号多 1。
    /// 例：睡 420 分（7 小时）、心率 58、近三天没练过
    ///     分项显示 47 + 30 + 6 = 83，但巨号显示 82（Double 和 82.67 截断）。
    /// 修法：总分改由**已取整的分项**相加得出（`total = sleep + heart + training`），
    /// 三项与总分同源取整，加起来必然相等。
    func testBreakdownComponentsSumToTotal() {
        let cases: [(sleep: Double?, heart: Double?, trained: Bool)] = [
            (450, 60, true), (450, 65, true), (300, 55, true), (510, 72, true),
            (420, 58, false), (240, 80, false), (360, 65, true), (450, 90, false),
            (60, 60, true), (450, 120, true), (480, 100, false), (30, 200, true)
        ]
        for (sleep, heart, trained) in cases {
            guard let b = referenceBreakdown(sleepMinutes: sleep, restingHeartRate: heart,
                                            trainedRecently: trained) else { continue }
            XCTAssertEqual(b.sleep + b.heart + b.training, b.total,
                           "分项之和 \(b.sleep)+\(b.heart)+\(b.training) ≠ 总分 \(b.total)（睡眠 \(sleep ?? -1) 分、心率 \(heart ?? -1) 次、训练 \(trained)）")
        }
    }

    /// 契约二：三项满分上限不得被突破。
    func testBreakdownNeverExceedsComponentCaps() {
        let cases: [(sleep: Double?, heart: Double?, trained: Bool)] = [
            (9999, 10, true), (450, 1, true), (450, 999, true), (0, 0, true)
        ]
        for (sleep, heart, trained) in cases {
            guard let b = referenceBreakdown(sleepMinutes: sleep, restingHeartRate: heart,
                                            trainedRecently: trained) else { continue }
            XCTAssertTrue((0...50).contains(b.sleep), "睡眠分越界：\(b.sleep)")
            XCTAssertTrue((0...30).contains(b.heart), "心率分越界：\(b.heart)")
            XCTAssertTrue((0...20).contains(b.training), "训练分越界：\(b.training)")
            XCTAssertTrue((0...100).contains(b.total), "总分越界：\(b.total)")
        }
    }

    /// 契约三：只缺一项时，**该项按 0 分算，其余照常计分**，总分照样出。
    /// 这条直接否掉「缺一项就不给分」的说法——那是错的。
    func testMissingSingleItemScoresZeroButKeepsOthers() {
        // 睡眠缺、心率有 → 心率满分 + 训练 6 分（没练过）
        let noSleep = referenceBreakdown(sleepMinutes: nil, restingHeartRate: 60, trainedRecently: false)
        XCTAssertNotNil(noSleep, "只缺一项时总分仍应出现")
        XCTAssertEqual(noSleep?.sleep, 0, "缺的睡眠项按 0 分算")
        XCTAssertEqual(noSleep?.heart, 30, "心率照常满分")
        XCTAssertEqual(noSleep?.total, 36, "总分 = 0 + 30 + 6")

        // 心率缺、睡眠满 → 睡眠 50 + 训练 20
        let noHeart = referenceBreakdown(sleepMinutes: 450, restingHeartRate: nil, trainedRecently: true)
        XCTAssertNotNil(noHeart, "只缺一项时总分仍应出现")
        XCTAssertEqual(noHeart?.heart, 0, "缺的心率项按 0 分算")
        XCTAssertEqual(noHeart?.sleep, 50, "睡眠照常满分")
        XCTAssertEqual(noHeart?.total, 70, "总分 = 50 + 0 + 20")
    }

    /// 契约四：睡眠与心率**都**缺 → 不显示分数（这才是"不给分"）。
    func testBothKeyItemsMissingMeansNoScore() {
        XCTAssertNil(referenceBreakdown(sleepMinutes: nil, restingHeartRate: nil, trainedRecently: true),
                     "关键项全缺时不给分")
    }

    /// 契约五：训练项永远有值——近三天没练过是 6 分，不是 0 分。
    /// 界面上必须讲清 6 分的来路，否则用户以为系统在乱给分。
    func testTrainingItemAlwaysHasValue() {
        let notTrained = referenceBreakdown(sleepMinutes: 450, restingHeartRate: 60, trainedRecently: false)
        XCTAssertEqual(notTrained?.training, 6, "没练过记 6 分")
        let trained = referenceBreakdown(sleepMinutes: 450, restingHeartRate: 60, trainedRecently: true)
        XCTAssertEqual(trained?.training, 20, "练过记 20 分")
    }

    /// 契约六：心率越高分越低，但有下限 8 分（不倒扣成负数）。
    func testHeartScoreDecaysWithFloor() {
        XCTAssertEqual(referenceBreakdown(sleepMinutes: 450, restingHeartRate: 65, trainedRecently: true)?.heart, 30)
        XCTAssertEqual(referenceBreakdown(sleepMinutes: 450, restingHeartRate: 70, trainedRecently: true)?.heart, 26)
        XCTAssertEqual(referenceBreakdown(sleepMinutes: 450, restingHeartRate: 80, trainedRecently: true)?.heart, 18)
        XCTAssertEqual(referenceBreakdown(sleepMinutes: 450, restingHeartRate: 120, trainedRecently: true)?.heart, 8, "下限 8 分")
    }

    /// 契约七：睡眠是线性给分，不是「睡够 7.5 小时才有分」。
    /// 界面上行标签若写「睡够 7.5 小时」会误导，必须写「睡眠」。
    func testSleepScoreIsLinear() {
        XCTAssertEqual(referenceBreakdown(sleepMinutes: 450, restingHeartRate: 60, trainedRecently: true)?.sleep, 50, "7.5 小时满分")
        XCTAssertEqual(referenceBreakdown(sleepMinutes: 225, restingHeartRate: 60, trainedRecently: true)?.sleep, 25, "3.75 小时给一半")
        XCTAssertGreaterThan(referenceBreakdown(sleepMinutes: 60, restingHeartRate: 60, trainedRecently: true)?.sleep ?? 0, 0,
                             "睡 1 小时也应有分")
    }
}

