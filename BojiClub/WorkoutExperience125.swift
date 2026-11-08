import SwiftUI
import Charts

/// Drafts never count as actual training until the member explicitly saves the row.
struct TrainingSetDraft125: Equatable {
    var weight: String
    var amount: String
    init(_ set: TrainingSet, plan: Bool = false) {
        let entered = set.hasActualEntry || plan
        weight = entered ? set.weight.formatted(.number.grouping(.never).precision(.fractionLength(0...2))) : ""
        amount = entered ? String(set.durationSeconds ?? set.reps) : ""
    }
    func saved(over original: TrainingSet, completed: Bool, plan: Bool = false) throws -> TrainingSet {
        let raw = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.range(of: "^[0-9]+$", options: .regularExpression) != nil, let count = Int(raw), count > 0,
              count <= (original.durationSeconds == nil ? RecordLimits.maximumReps : RecordLimits.maximumSeconds) else {
            throw EntryError.message(original.durationSeconds == nil ? "请填写实际次数，次数需为正整数。" : "请填写实际秒数，秒数需为正整数。")
        }
        var value = original
        if original.durationSeconds == nil {
            let text = weight.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
            let kg: Double
            if text.isEmpty {
                kg = 0.0
            } else {
                guard text.range(of: "^[0-9]+(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
                      let parsed = Double(text), parsed.isFinite, parsed >= 0, parsed <= RecordLimits.maximumWeight else {
                    throw EntryError.message("请填写重量；自重或不加重量可以留空，支持 1.25、2.5 这样的小数。")
                }
                kg = parsed
            }
            value.weight = kg; value.reps = count
        } else { value.durationSeconds = count; value.reps = 0 }
        value.actualEntered = !plan; value.completed = completed && !plan
        return value
    }
    enum EntryError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
    }
}

struct TrainingInlineSetRow125: View {
    let number: Int
    let original: TrainingSet
    let previous: TrainingSet?
    let active: Bool
    let plan: Bool
    let save: (TrainingSet) -> Bool
    let more: () -> Void
    @State private var draft: TrainingSetDraft125
    @State private var undoDraft: TrainingSetDraft125?
    @State private var copiedNotice: String?
    @State private var message: String?
    @State private var weightFocusRequest = 0
    @State private var amountFocusRequest = 0
    @AppStorage("workout_swipe_copy_tip_shown") private var swipeCopyTipShown = false
    init(number: Int, original: TrainingSet, previous: TrainingSet? = nil, active: Bool, plan: Bool,
         save: @escaping (TrainingSet) -> Bool, more: @escaping () -> Void) {
        self.number = number; self.original = original; self.previous = previous; self.active = active; self.plan = plan
        self.save = save; self.more = more; _draft = State(initialValue: TrainingSetDraft125(original, plan: plan))
    }
    private var changed: Bool { draft != TrainingSetDraft125(original, plan: plan) }
    private var done: Bool { original.validCompletion && !changed }
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            HStack(spacing: BojiSpace.tightRow) {
                Text("\(number)").bojiType(.secondary).foregroundStyle(.secondary)
                    .frame(width: BojiSetTable.numberColumn)
                    .contextMenu {
                        if previous != nil, !done, !plan {
                            Button("带入上一组数据") { copyFromPrevious() }
                        }
                        Button("更多编辑选项", action: more)
                    }
                if original.durationSeconds == nil {
                    TrainingNumericInput125(text: $draft.weight, placeholder: plan ? "目标" : "重量",
                        label: "第\(number)组重量，千克", identifier: "set-weight-\(original.id)", focusRequest: weightFocusRequest)
                        .frame(height: 48).contentShape(Rectangle())
                        .onTapGesture { weightFocusRequest += 1 }
                }
                TrainingNumericInput125(text: $draft.amount, placeholder: original.durationSeconds == nil ? "次数" : "秒数",
                    label: "第\(number)组\(original.durationSeconds == nil ? "次数" : "秒数")", identifier: "set-amount-\(original.id)", focusRequest: amountFocusRequest)
                    .frame(height: 48).contentShape(Rectangle())
                    .onTapGesture { amountFocusRequest += 1 }
                Button { commit() } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .bojiType(.title)
                        .foregroundStyle(done ? ClubBrand.accent : BojiColor.textTertiary)
                        .frame(width: BojiSetTable.completeColumn, height: 48)
                }
                .buttonStyle(BojiPressableButtonStyle(scale: BojiPressSpec.rowScale, haptic: { BojiHaptics.tick() }))
                .accessibilityLabel(plan ? "保存本组目标" : done ? "撤销本组完成" : "保存并完成本组")
                .accessibilityIdentifier("set-complete-\(original.id)")
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 25)
                    .onEnded { gesture in
                        guard !done, !plan, previous != nil, gesture.translation.width > 45, abs(gesture.translation.height) < 35 else { return }
                        copyFromPrevious()
                    }
            )
            if let notice = copiedNotice {
                HStack(spacing: BojiLayout.inline) {
                    Text(notice)
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                    Spacer()
                    if undoDraft != nil {
                        Button("撤回") {
                            if let undo = undoDraft {
                                draft = undo
                                undoDraft = nil
                                copiedNotice = nil
                                BojiHaptics.tick()
                            }
                        }
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.brandAccent)
                    }
                }
                .padding(.horizontal, BojiLayout.inline)
                .padding(.vertical, BojiLayout.tight)
                .background(BojiColor.inputSurface, in: RoundedRectangle(cornerRadius: BojiRadius.badge))
                .transition(.opacity)
            }
            if let message { Text(message).bojiType(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.vertical, BojiLayout.tight)
        .onChange(of: original) { _, value in draft = TrainingSetDraft125(value, plan: plan); message = nil }
    }
    private func copyFromPrevious() {
        guard let previous else { return }
        undoDraft = draft
        if original.durationSeconds == nil && previous.durationSeconds == nil {
            draft.weight = previous.weight.formatted(.number.grouping(.never).precision(.fractionLength(0...1)))
            draft.amount = String(previous.reps)
        } else if original.durationSeconds != nil && previous.durationSeconds != nil {
            draft.amount = String(previous.durationSeconds ?? 0)
        }
        BojiHaptics.latch()
        withAnimation(BojiMotion2.state) {
            if !swipeCopyTipShown {
                copiedNotice = "已右滑带入第 \(number - 1) 组数据 · 需主动点击圆圈确认完成"
                swipeCopyTipShown = true
            } else {
                copiedNotice = "已带入第 \(number - 1) 组数据"
            }
        }
    }
    private func hideKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
    private func commit() {
        if done && !plan {
            var value = original; value.completed = false
            if save(value) { hideKeyboard(); message = nil }
            return
        }
        do {
            let value = try draft.saved(over: original, completed: true, plan: plan)
            if save(value) { hideKeyboard(); message = nil; BojiHaptics.latch() }
            else { message = "未能保存，请核对这组记录后重试。" }
        } catch { message = error.localizedDescription; if draft.weight.isEmpty && original.durationSeconds == nil { weightFocusRequest += 1 } else { amountFocusRequest += 1 } }
    }
}
/// 原生数字输入：SwiftUI TextField + decimalPad + 键盘工具条「收起」。
/// 保留 label/identifier/focusRequest 供无障碍与 UI 测试，删除自绘 UITextField 包装。
private struct TrainingNumericInput125: View {
    @Binding var text: String
    let placeholder: String
    let label: String
    let identifier: String
    var focusRequest = 0
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .bojiType(.section)
            .keyboardType(.decimalPad)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: BojiLayout.inputHeight)
            .padding(.horizontal, BojiLayout.tight)
            .background(BojiColor.inputSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
            .focused($focused)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
            .onChange(of: focusRequest) { _, value in
                if value > 0 { focused = true }
            }
    }
}

struct WorkoutFinishReview125: View {
    let completed: Int
    let total: Int
    let confirm: () -> Void
    let cancel: () -> Void
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: BojiLayout.blockGap) {
                BojiBrandMark(size: 44)
                Text("这一练，准备收官？").bojiType(.section)
                HStack(alignment: .firstTextBaseline, spacing: BojiLayout.tight) {
                    Text("\(completed)").bojiFont(.bodyMetric, monospacedDigits: true)
                    Text("组已记录").foregroundStyle(.secondary)
                }
                Text(total > completed ? "还有 \(total-completed) 组没记完。保存后它们会保留未完成状态。" : "这次都记完了，可以保存训练记录。")
                    .bojiType(.body).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("结束并保存 \(completed) 组", action: confirm).buttonStyle(PrimaryButton()).disabled(completed == 0)
                Button("继续训练", action: cancel).buttonStyle(SecondaryButton())
            }.padding(BojiLayout.Rhythm.headerToContent)
                .navigationTitle("结束训练").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", action: cancel) } }
        }.presentationDetents([.height(440), .large]).presentationDragIndicator(.visible)
    }
}

struct WorkoutFacts125 {
    struct ExerciseFact: Identifiable { let id: UUID; let ordinal: Int; let name: String; let muscle: String; let completed: Int; let planned: Int }
    let exercises: [ExerciseFact]
    let completed: Int
    let planned: Int
    let volume: Double
    let reps: Int
    let seconds: Int
    var registeredExercises: Int { exercises.filter { $0.completed > 0 }.count }
    init(_ log: DayLog) {
        exercises = log.exercises.enumerated().map { index, exercise in .init(id:exercise.id, ordinal:index+1, name:exercise.displayName, muscle:exercise.muscle, completed:exercise.sets.filter(\.validCompletion).count, planned:exercise.sets.count) }
        let valid = log.exercises.flatMap(\.sets).filter(\.validCompletion)
        completed = valid.count; planned = log.exercises.reduce(0) { $0 + $1.sets.count }
        volume = valid.reduce(0) { $0 + $1.volume } // 与 ConfirmedTraining.volume 同算法（含 validCompletion，计时组天然为 0）
        reps = valid.filter { $0.durationSeconds == nil }.reduce(0) { $0 + $1.reps }
        seconds = valid.reduce(0) { $0 + ($1.durationSeconds ?? 0) }
    }
}

struct WorkoutCelebration125: View {
    let facts: WorkoutFacts125
    let duration: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    var body: some View {
        VStack(spacing: BojiLayout.cardInset) {
            BojiBrandMark(size: 62).padding(BojiLayout.blockGap)
                .background(BojiColor.brandMist, in: Circle())
                .overlay { Circle().stroke(ClubBrand.accent.opacity(0.2), lineWidth: 1) }
                .scaleEffect(appeared || reduceMotion ? 1 : 0.88)
            Text("辛苦了，训练已完成").bojiType(.section)
            Text("记了 \(facts.completed) 组，这次训练已保存。").bojiType(.secondary).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()),GridItem(.flexible()),GridItem(.flexible())],spacing: BojiLayout.blockGap) {
                // DES-004：6 格 entrance 0.35s + stagger 0.05s，整串 0.60s
                rollingFact("完成组", target: Double(facts.completed), unit: "组", index: 0)
                fact("训练用时", value: duration, unit: "", index: 1)
                fact("练了几个动作", value: "\(facts.registeredExercises)", unit: "项", index: 2)
                rollingFact("累计次数", target: Double(facts.reps), unit: "次", index: 3)
                rollingFact("训练量", target: facts.volume, precision: 1, unit: "kg·次", index: 4)
                fact("计时动作", value: "\(facts.seconds)", unit: "秒", index: 5)
            }.padding(.top, BojiLayout.inline)
        }.frame(maxWidth:.infinity).padding(.vertical, BojiLayout.cardInset)
            .onAppear { withAnimation(reduceMotion ? nil : BojiMotion2.celebrate) { appeared = true } }
            .sensoryFeedback(.success, trigger: appeared)
    }
    private func fact(_ title: String, value: String, unit: String, index: Int) -> some View {
        VStack(alignment: .leading, spacing: BojiLayout.tight) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(BojiColor.divider).frame(width: 28, height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(title).bojiType(.label).foregroundStyle(BojiColor.textSecondary)
                if !unit.isEmpty { Text(unit).bojiType(.caption).foregroundStyle(BojiColor.textTertiary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .bojiStaggeredEntrance(appeared: appeared, reduceMotion: reduceMotion, index: index)
    }

    /// 数字滚动事实格：从 0 滚到目标值（counter linear 0.35s），减少动态效果直接落终值。
    private func rollingFact(_ title: String, target: Double, precision: Int = 0, unit: String, index: Int) -> some View {
        BojiRollingFact(target: target, precision: precision, reduceMotion: reduceMotion) { value in
            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(BojiColor.divider).frame(width: 28, height: 1)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(title).bojiType(.label).foregroundStyle(BojiColor.textSecondary)
                    if !unit.isEmpty { Text(unit).bojiType(.caption).foregroundStyle(BojiColor.textTertiary) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .bojiStaggeredEntrance(appeared: appeared, reduceMotion: reduceMotion, index: index)
        }
    }
}

/// 一次性数字滚动（RollingNumericCounter 同款语义）：减少动态效果直接显示终值。
private struct BojiRollingFact<Content: View>: View {
    let target: Double
    var precision: Int = 0
    let reduceMotion: Bool
    @ViewBuilder let content: (String) -> Content
    @State private var display: Double = 0
    var body: some View {
        content(display.formatted(.number.precision(.fractionLength(precision))))
            .onAppear {
                if reduceMotion { display = target }
                else { withAnimation(BojiMotion2.counter) { display = target } }
            }
    }
}

/// 事实格进场：opacity + scale，规范 §4.1 entrance spring 0.35/0.85 + stagger 0.05（只动 transform/opacity）。
private struct BojiStaggeredEntrance: ViewModifier {
    let appeared: Bool
    let reduceMotion: Bool
    let index: Int
    func body(content: Content) -> some View {
        content
            .opacity(appeared || reduceMotion ? 1 : 0)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.96)
            .animation(BojiMotion2.resolved(BojiMotion2.entrance, reduceMotion: reduceMotion)?
                .delay(Double(index) * BojiMotion2.stagger), value: appeared)
    }
}

extension View {
    func bojiStaggeredEntrance(appeared: Bool, reduceMotion: Bool, index: Int) -> some View {
        modifier(BojiStaggeredEntrance(appeared: appeared, reduceMotion: reduceMotion, index: index))
    }
}

struct WorkoutCharts125: View {
    let facts: WorkoutFacts125
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showAll = false
    @State private var appeared = false
    private var muscles: [MusclePetal134] {
        Dictionary(grouping: facts.exercises, by: { $0.muscle.isEmpty ? "未标注" : $0.muscle })
            .map { MusclePetal134(name: $0.key, sets: $0.value.reduce(0) { $0 + $1.completed }) }
            .sorted { $0.name < $1.name }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
            ClubCard {
                Text("这次完成了多少").bojiType(.section)
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: BojiLayout.blockGap)) : AnyLayout(HStackLayout(spacing: BojiLayout.Rhythm.headerToContent))
                layout {
                    BojiRingGauge(progress: NativeData134.share(Double(facts.completed), total: Double(facts.planned)), tint: DataPalette134.blue, lineWidth: 12) {
                        VStack(spacing: 0) {
                            Text("\(facts.completed)").bojiType(.display).contentTransition(.numericText())
                            Text("完成组").bojiType(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(width: 128, height: 128)
                        .accessibilityElement(children: .ignore).accessibilityLabel("实际完成\(facts.completed)组，本次安排\(facts.planned)组")
                    VStack(alignment: .leading, spacing: BojiLayout.inline) {
                        Text("本次安排 \(facts.planned) 组").bojiType(.bodyStrong)
                        Text("\(max(0, facts.planned - facts.completed)) 组未完成").bojiType(.secondary).foregroundStyle(.secondary)
                        Text("只算你记完的组").bojiType(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, BojiLayout.inline)
            }
            ClubCard {
                HStack { Text("每个动作的完成情况").bojiType(.section); Spacer() }
                Text("彩色为已完成，浅色底为本次安排。")
                    .bojiType(.caption).foregroundStyle(.secondary)
                ForEach(showAll ? facts.exercises : Array(facts.exercises.prefix(5))) { item in
                    VStack(alignment: .leading, spacing: BojiLayout.inline) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.name).bojiType(.secondary)
                            Spacer(minLength: 12)
                            Text("\(item.completed) / \(item.planned) 组").bojiType(.secondary).foregroundStyle(.secondary)
                        }
                        ProgressView(value: appeared ? NativeData134.share(Double(item.completed), total: Double(item.planned)) : 0.0, total: 1.0)
                            .tint(DataPalette134.color(item.muscle))
                            .frame(height: 8)
                    }.padding(.vertical, BojiLayout.inline).accessibilityElement(children: .combine)
                }
                if facts.exercises.count > 5 {
                    Button(showAll ? "收起动作" : "查看全部 \(facts.exercises.count) 个动作") {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { showAll.toggle() }
                        BojiHaptics.selection()
                    }.bojiType(.secondary).frame(minHeight: 44)
                }
            }
            if muscles.contains(where: { $0.sets > 0 }) {
                ClubCard {
                    Text("这次练到了哪里").bojiType(.section)
                    MuscleFlower134(items: muscles)
                }
            }
        }
        .onAppear { withAnimation(reduceMotion ? nil : .smooth(duration: 0.5)) { appeared = true } }
    }
}

/// Apple iOS 原生符号图标
struct TrainingEntryGlyph125: View {
    let library: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: BojiRadius.thumb, style: .continuous).fill(BojiColor.brandMist)
            Image(systemName: library ? "books.vertical.fill" : "list.clipboard.fill")
                .bojiType(.body)
                .foregroundStyle(ClubBrand.accent)
        }
        .accessibilityHidden(true)
    }
}

enum AIRunFailureText125 {
    static func message(code: String) -> String {
        switch code {
        case "invalid_output": return "AI 这次没有完整回复，请重试本条消息。已保存的记录仍在。"
        case "task_timeout", "UPSTREAM_TIMEOUT": return "这次回复等待较久，请稍后重试，输入已保留。"
        case "RESULT_PERSIST_FAILED", "RECOVERY_UNAVAILABLE": return "回复或部分操作暂未确认，请先查看原消息的操作回执。"
        case "UPSTREAM_REQUEST_REJECTED", "INVALID_RUN_REQUEST": return "引用或资料可能已更新，请刷新后重试。"
        default: return "这次回复暂未完成，输入已保留，请稍后重试。"
        }
    }
}
