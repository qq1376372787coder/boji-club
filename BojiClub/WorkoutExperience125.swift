import SwiftUI
import UIKit
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
            guard text.range(of: "^[0-9]+(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
                  let kg = Double(text), kg.isFinite, kg >= 0, kg <= RecordLimits.maximumWeight else {
                throw EntryError.message("请填写重量；自重或无额外负重时填 0，支持 1.25、2.5 等小数。")
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
    let active: Bool
    let plan: Bool
    let save: (TrainingSet) -> Bool
    let more: () -> Void
    @State private var draft: TrainingSetDraft125
    @State private var message: String?
    @State private var weightFocusRequest = 0
    @State private var amountFocusRequest = 0
    init(number: Int, original: TrainingSet, active: Bool, plan: Bool,
         save: @escaping (TrainingSet) -> Bool, more: @escaping () -> Void) {
        self.number = number; self.original = original; self.active = active; self.plan = plan
        self.save = save; self.more = more; _draft = State(initialValue: TrainingSetDraft125(original, plan: plan))
    }
    private var changed: Bool { draft != TrainingSetDraft125(original, plan: plan) }
    private var done: Bool { original.validCompletion && !changed }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: BojiSpace.tightRow) {
                Text("\(number)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: BojiSetTable.numberColumn)
                    .contextMenu { Button("更多编辑选项", action: more) }
                if original.durationSeconds == nil {
                    TrainingNumericInput125(text: $draft.weight, placeholder: plan ? "目标" : "重量",
                        label: "第\(number)组重量，千克", identifier: "set-weight-\(original.id)", focusRequest: weightFocusRequest)
                        .frame(height: 48).contentShape(Rectangle())
                        .onTapGesture { weightFocusRequest += 1 }
                        .modifier(TrainingNumberStyle125())
                }
                TrainingNumericInput125(text: $draft.amount, placeholder: original.durationSeconds == nil ? "次数" : "秒数",
                    label: "第\(number)组\(original.durationSeconds == nil ? "次数" : "秒数")", identifier: "set-amount-\(original.id)", focusRequest: amountFocusRequest)
                    .frame(height: 48).contentShape(Rectangle())
                    .onTapGesture { amountFocusRequest += 1 }
                    .modifier(TrainingNumberStyle125())
                Button { commit() } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 29, weight: .regular))
                        .foregroundStyle(done ? ClubBrand.accent : BojiColor.textSecondary)
                        .frame(width: BojiSetTable.completeColumn, height: 48)
                }.buttonStyle(.plain)
                    .accessibilityLabel(plan ? "保存本组目标" : done ? "撤销本组完成" : "保存并完成本组")
                    .accessibilityIdentifier("set-complete-\(original.id)")
            }
            if let message { Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.vertical, 4)
        .onChange(of: original) { _, value in draft = TrainingSetDraft125(value, plan: plan); message = nil }
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
private struct TrainingNumericInput125: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let label: String
    let identifier: String
    var focusRequest = 0
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.keyboardType = .decimalPad; field.textAlignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 19, weight: .medium)
        field.adjustsFontForContentSizeCategory = true; field.textColor = .label
        field.autocorrectionType = .no; field.spellCheckingType = .no
        field.accessibilityLabel = label; field.accessibilityIdentifier = identifier
        field.placeholder = placeholder; field.text = text
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        context.coordinator.field = field
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), UIBarButtonItem(title: "收起", style: .done, target: context.coordinator, action: #selector(Coordinator.done))]
        field.inputAccessoryView = bar
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        if context.coordinator.lastFocus != focusRequest {
            context.coordinator.lastFocus = focusRequest
            DispatchQueue.main.async { [weak field] in if field?.window != nil { field?.becomeFirstResponder() } }
        }
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: TrainingNumericInput125
        weak var field: UITextField?
        var lastFocus = 0
        init(_ parent: TrainingNumericInput125) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ field: UITextField) { field.selectAll(nil) }
        func textFieldDidEndEditing(_ field: UITextField) { parent.text = field.text ?? "" }
        @objc func done() { field?.resignFirstResponder() }
    }
}

private struct TrainingNumberStyle125: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 19, weight: .medium, design: .rounded).monospacedDigit())
            .multilineTextAlignment(.center).textFieldStyle(.plain)
            .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 48)
            .background(BojiColor.brandMist.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .autocorrectionDisabled()
    }
}

struct WorkoutFinishReview125: View {
    let completed: Int
    let total: Int
    let confirm: () -> Void
    let cancel: () -> Void
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                BojiBrandMark(size: 44)
                Text("这一练，准备收官？").font(.title2.weight(.semibold))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(completed)").font(.system(size: 48, weight: .semibold, design: .rounded))
                    Text("组已登记").foregroundStyle(.secondary)
                }
                Text(total > completed ? "还有 \(total-completed) 组未登记。保存后它们会保留未完成状态。" : "本次登记已经齐全，可以保存训练记录。")
                    .font(.body).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("结束并保存 \(completed) 组", action: confirm).buttonStyle(PrimaryButton()).disabled(completed == 0)
                Button("继续训练", action: cancel).buttonStyle(SecondaryButton())
            }.padding(24)
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
        volume = valid.filter { $0.durationSeconds == nil }.reduce(0) { $0 + $1.weight * Double($1.reps) }
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
        VStack(spacing: 18) {
            BojiBrandMark(size: 62).padding(22)
                .background(BojiColor.brandMist, in: Circle())
                .overlay { Circle().stroke(ClubBrand.accent.opacity(0.2), lineWidth: 1) }
                .scaleEffect(appeared || reduceMotion ? 1 : 0.88)
            Text("辛苦了，训练已完成").font(.title2.weight(.semibold))
            Text("\(facts.completed) 组已登记，为你保存了本次训练。").font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()),GridItem(.flexible()),GridItem(.flexible())],spacing:20) {
                fact("完成组", "\(appeared ? facts.completed : 0)", "组")
                fact("训练用时", duration, "")
                fact("登记动作", "\(facts.registeredExercises)", "项")
                fact("累计次数", "\(facts.reps)", "次")
                fact("额外负重训练量", facts.volume.formatted(.number.precision(.fractionLength(0...1))), "kg·次")
                fact("计时动作", "\(facts.seconds)", "秒")
            }.padding(.top,8)
        }.frame(maxWidth:.infinity).padding(.vertical,16)
            .onAppear { withAnimation(reduceMotion ? nil : .spring(duration:0.55, bounce:0.12)) { appeared = true } }
    }
    private func fact(_ title: String,_ value: String,_ unit: String) -> some View {
        VStack(spacing:5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size:24,weight:.semibold,design:.rounded).monospacedDigit()).contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.65)
            Text(unit.isEmpty ? " " : unit).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity)
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
        VStack(alignment: .leading, spacing: 18) {
            ClubCard {
                Text("这次完成了多少").font(.title3.weight(.semibold))
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20)) : AnyLayout(HStackLayout(spacing: 24))
                layout {
                    BojiRingGauge(progress: NativeData134.share(Double(facts.completed), total: Double(facts.planned)), tint: DataPalette134.blue, lineWidth: 12) {
                        VStack(spacing: 2) {
                            Text("\(facts.completed)").font(.system(size: 32, weight: .semibold, design: .rounded)).contentTransition(.numericText())
                            Text("完成组").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(width: 128, height: 128)
                        .accessibilityElement(children: .ignore).accessibilityLabel("实际完成\(facts.completed)组，本次安排\(facts.planned)组")
                    VStack(alignment: .leading, spacing: 9) {
                        Text("本次安排 \(facts.planned) 组").font(.headline)
                        Text("\(max(0, facts.planned - facts.completed)) 组未完成").font(.subheadline).foregroundStyle(.secondary)
                        Text("只统计你已登记完成的组").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 10)
            }
            ClubCard {
                HStack { Text("每个动作的完成情况").font(.title3.weight(.semibold)); Spacer() }
                Text("彩色为已完成，浅色底为本次安排。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(showAll ? facts.exercises : Array(facts.exercises.prefix(5))) { item in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.name).font(.subheadline.weight(.medium))
                            Spacer(minLength: 12)
                            Text("\(item.completed) / \(item.planned) 组").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(BojiColor.brandMist)
                                Capsule().fill(DataPalette134.color(item.muscle).gradient)
                                    .frame(width: geometry.size.width * (appeared ? NativeData134.share(Double(item.completed), total: Double(item.planned)) : 0))
                            }
                        }.frame(height: 10)
                    }.padding(.vertical, 10).accessibilityElement(children: .combine)
                }
                if facts.exercises.count > 5 {
                    Button(showAll ? "收起动作" : "查看全部 \(facts.exercises.count) 个动作") {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { showAll.toggle() }
                        BojiHaptics.selection()
                    }.font(.subheadline).frame(minHeight: 44)
                }
            }
            if muscles.contains(where: { $0.sets > 0 }) {
                ClubCard {
                    Text("这次练到了哪里").font(.title3.weight(.semibold))
                    MuscleFlower134(items: muscles)
                }
            }
        }
        .onAppear { withAnimation(reduceMotion ? nil : .smooth(duration: 0.5)) { appeared = true } }
    }
}

/// Small, brand-coloured line drawings for the two training destinations.
struct TrainingEntryGlyph125: View {
    let library: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(BojiColor.brandMist)
            Canvas { context, size in
                var path = Path()
                if library {
                    for index in 0..<3 {
                        let x = 9.0 + Double(index) * 6
                        path.addRoundedRect(in: CGRect(x:x,y:index == 2 ? 10 : 8,width:3.5,height:index == 2 ? 16 : 18),cornerSize:CGSize(width:1,height:1))
                    }
                } else {
                    path.addRoundedRect(in:CGRect(x:8,y:7,width:18,height:21),cornerSize:CGSize(width:3,height:3))
                    for y in [13.0,18,23] { path.move(to:CGPoint(x:12,y:y));path.addLine(to:CGPoint(x:22,y:y)) }
                }
                context.stroke(path,with:.color(ClubBrand.accent),style:StrokeStyle(lineWidth:1.4,lineCap:.round,lineJoin:.round))
            }
        }.accessibilityHidden(true)
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
