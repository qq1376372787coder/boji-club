// Executed together with the production ClubDates and meal-context types.
let now = ClubDates.date(fromKey: "2026-10-09")!.addingTimeInterval(20 * 3600)
func verify(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), name)
    print("PASS \(name)")
}
let breakfast = MealDescriptionUnderstanding.inspect("早上吃了俩鸡蛋一根油条", date: now, category: "晚餐", now: now)
verify(breakfast.category == "早餐", "Evening backfill detects breakfast")
verify(ClubDates.key(breakfast.date) == "2026-10-09", "Unspecified day keeps selected date")
let yesterday = MealDescriptionUnderstanding.inspect("昨晚吃了一碗面", date: now, category: "早餐", now: now)
verify(ClubDates.key(yesterday.date) == "2026-10-08" && yesterday.category == "晚餐", "Yesterday evening uses yesterday")
let prior = MealDescriptionUnderstanding.inspect("前天午餐吃了米饭", date: now, category: "晚餐", now: now)
verify(ClubDates.key(prior.date) == "2026-10-07" && prior.category == "午餐", "Day before yesterday is preserved")
let selected = ClubDates.date(fromKey: "2026-10-02")!
verify(ClubDates.key(MealDescriptionUnderstanding.inspect("吃了一根香蕉", date: selected, category: "加餐", now: now).date) == "2026-10-02", "Manual historical date is not changed without evidence")
verify(MealDescriptionUnderstanding.inspect("早上加餐喝了一杯奶", date: now, category: "早餐", now: now).category == "加餐", "Explicit snack wins over time hint")
verify(MealDescriptionUnderstanding.inspect("早餐鸡蛋午餐米饭", date: now, category: "早餐", now: now).problem != nil, "Multiple meals are not merged")
verify(MealDescriptionUnderstanding.inspect("早餐鸡蛋中午米饭", date: now, category: "早餐", now: now).problem != nil, "Named and time-based meals are not merged")
verify(MealDescriptionUnderstanding.inspect("昨天吃面今天吃饭", date: now, category: "午餐", now: now).problem != nil, "Multiple days require separate records")
verify(MealDescriptionUnderstanding.inspect("明早打算吃鸡蛋", date: now, category: "早餐", now: now).problem != nil, "Future meals cannot become consumption")
print("Voice meal date/category rules passed")
