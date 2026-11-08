import SwiftUI
import UIKit
import AVFoundation

// Typed attachments are separate from display text. Typing an @name never grants a reference.
private extension NSAttributedString.Key { static let bojiReferenceID = NSAttributedString.Key("com.bojiclub.reference") }

struct ClubReferenceTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var references: [AIContextReference]
    var focusRequest: Int
    var onMention: (String?) -> Void
    var onSubmit: (() -> Void)? = nil
    var onMentionRange: ((NSRange?) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = ClubComposerTextView130()
        view.delegate = context.coordinator; view.returnKeyType = .send
        view.enablesReturnKeyAutomatically = false
        view.font = .preferredFont(forTextStyle: .body); view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear; view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 10, left: 4, bottom: 10, right: 4)
        view.isScrollEnabled = false; view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = "向 Club AI 提问，引用显示在输入框上方"
        view.accessibilityIdentifier = "v2-composer-field"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let c = context.coordinator; c.parent = self
        guard view.markedTextRange == nil else { return }
        c.applying = true; defer { c.applying = false }
        if view.text != text {
            let caret = min(view.selectedRange.location, (text as NSString).length)
            view.text = text; view.selectedRange = NSRange(location: caret, length: 0)
        }
        if c.focusRequest != focusRequest { c.focusRequest = focusRequest; view.becomeFirstResponder() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let limit: CGFloat = uiView.traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 180 : 132
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        if uiView.isScrollEnabled != (fitted.height > limit) { uiView.isScrollEnabled = fitted.height > limit }
        return CGSize(width: width, height: min(limit, max(42, fitted.height)))
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ClubReferenceTextEditor
        var applying = false
        var focusRequest: Int
        init(_ parent: ClubReferenceTextEditor) { self.parent = parent; focusRequest = parent.focusRequest }
        func mentionRange(in view: UITextView) -> NSRange? {
            guard view.selectedRange.length == 0, view.markedTextRange == nil else { return nil }
            let prefix = (view.text as NSString).substring(to: min(view.selectedRange.location, (view.text as NSString).length))
            guard let regex = try? NSRegularExpression(pattern: "(?:^|\\s)(@[^\\s@]{0,24})$"),
                  let match = regex.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) else { return nil }
            return match.range(at: 1)
        }
        private func updateMention(_ view: UITextView) {
            let range = mentionRange(in: view)
            parent.onMentionRange?(range)
            parent.onMention(range.map { String((view.text as NSString).substring(with: $0).dropFirst()) })
        }
        func textViewDidChange(_ view: UITextView) {
            guard !applying else { return }
            parent.text = view.text
            guard view.markedTextRange == nil else { return }
            updateMention(view)
        }
        func textViewDidChangeSelection(_ view: UITextView) {
            guard !applying, view.markedTextRange == nil else { return }
            updateMention(view)
        }
        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText value: String) -> Bool {
            guard view.markedTextRange == nil else { return true }
            if value == "\n", (view as? ClubComposerTextView130)?.insertingLineBreak130 != true, let send = parent.onSubmit { send(); return false }
            return true
        }
        func textView(_ view: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            UIMenu(children: suggestedActions + [UIAction(title: "换行", image: UIImage(systemName: "return")) { [weak view] _ in
                (view as? ClubComposerTextView130)?.insertLineBreak131()
            }])
        }
    }
}

@MainActor enum AIReferenceCatalog {
    static func recent(store: AppStore, ai: AIService, query: String = "") -> [AIContextReference] {
        var result: [AIContextReference] = []
        for key in store.state.days.keys.sorted().reversed() where key <= ClubDates.key(Date()) {
            guard let day = store.state.days[key] else { continue }
            for session in (day.workoutSessions ?? []).reversed() where session.cancelledAt == nil {
                result.append(.init(kind: "workout_session", resourceID: session.id.uuidString.lowercased(), from: key, to: key, title: key + " 训练"))
            }
            if !day.meals.isEmpty { result.append(.init(kind: "meal_day", from: key, to: key, title: key + " 饮食")) }
            if !BodyWeightReading.rawRows(of: day).isEmpty { result.append(.init(kind: "body_range", from: key, to: key, title: key + " 身体测量")) }
            if !day.exercises.isEmpty { result.append(.init(kind: "plan_day", from: key, to: key, title: key + " 计划")) }
            for plan in day.planVersions ?? [] { result.append(.init(kind: "plan_version", resourceID: plan.id, from: key, to: key, title: plan.title)) }
        }
        var seen = Set<String>()
        return Array(result.filter { seen.insert($0.id).inserted && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }.prefix(5))
    }
}


struct ClubCameraCapture: UIViewControllerRepresentable {
    var thumbnail: UIImage?
    let onCapture: (Data) -> Void
    let onAlbum: () -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        let overlay = UIView(frame: UIScreen.main.bounds)
        let button = UIButton(type: .system)
        button.frame = CGRect(x: overlay.bounds.width - 82, y: overlay.bounds.height - 160, width: 66, height: 54)
        button.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
        if let thumbnail { button.setImage(thumbnail.withRenderingMode(.alwaysOriginal), for: .normal); button.imageView?.contentMode = .scaleAspectFill }
        else { button.setImage(UIImage(systemName: "photo.on.rectangle"), for: .normal); button.setTitle("相册", for: .normal) }
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 12; button.clipsToBounds = true
        button.accessibilityLabel = "从相册选择照片"
        button.addTarget(context.coordinator, action: #selector(Coordinator.album), for: .touchUpInside)
        overlay.addSubview(button); controller.cameraOverlayView = overlay
        return controller
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) { context.coordinator.parent = self }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: ClubCameraCapture
        init(_ parent: ClubCameraCapture) { self.parent = parent }
        @objc func album() { parent.onAlbum() }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.85) else { parent.onCancel(); return }
            parent.onCapture(data)
        }
    }
}

struct ClubCompactReferencePicker: View {
    @Binding var selection: [AIContextReference]
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ai: AIService
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var more = false
    var body: some View {
        NavigationStack {
            List {
                Section("最近记录 · \(selection.count)/5") {
                    ForEach(AIReferenceCatalog.recent(store: store, ai: ai, query: search)) { ref in
                        Button {
                            if !selection.contains(where: { $0.id == ref.id }), selection.count < 5 { selection.append(ref) }
                            dismiss()
                        } label: { Label(ref.title, systemImage: "at") }.disabled(selection.count >= 5)
                    }
                    Button("按类型或日期查找…") { more = true }
                }
            }.searchable(text: $search, prompt: "搜索最近记录")
            .navigationTitle("引用记录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $more) { AIReferencePicker(selection: $selection).presentationDetents([.medium, .large]) }
        }
    }
}

/// 原生数字输入：系统键盘直接录入，过滤规则与原自绘键盘一致（数字、一个小数点、最长 8 位）。
struct ClubNumericField: View {
    @Binding var value: String
    let placeholder: String
    let decimal: Bool
    var body: some View {
        TextField(placeholder, text: $value)
            .bojiType(.section)
            .keyboardType(decimal ? .decimalPad : .numberPad)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, BojiLayout.inline)
            .background(BojiColor.inputSurface, in: RoundedRectangle(cornerRadius: BojiRadius.thumb))
            .onChange(of: value) { _, newValue in
                let sanitized = ClubNumericField.sanitize(newValue, decimal: decimal)
                if sanitized != newValue { value = sanitized }
            }
    }
    private static func sanitize(_ raw: String, decimal: Bool) -> String {
        let allowed = CharacterSet.decimalDigits.union(decimal ? CharacterSet(charactersIn: ".") : CharacterSet())
        var result = String(raw.unicodeScalars.filter { allowed.contains($0) })
        if decimal, let first = result.firstIndex(of: "."), let last = result.lastIndex(of: "."), first != last {
            result.removeSubrange(result.index(after: first)...last)
        }
        return String(result.prefix(8))
    }
}

struct ClubMovementHelp: View {
    let exercise: Exercise
    let date: Date
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(exercise.name).bojiType(.bodyStrong)
                    ExerciseDemoButton(exercise: exercise)
                    Text("选择你正在遇到的问题。回答以这个动作与器械为背景，不会自动调整训练。位置不适或疼痛请先停止这组。").bojiType(.label).foregroundStyle(.secondary)
                }
                Section("想了解什么？") {
                    ForEach(["这个动作主要练哪里？", "这个动作怎么发力？", "器械座椅和握把应该怎么调整？", "常见错误和需要注意的地方？", "没有这个器械，可以换什么动作？"], id: \.self) { question in
                        Button(question) {
                            guard let owner = store.editingAccountID else { return }
                            let ref = AIContextReference.day("workout_range", date: date, title: ClubDates.key(date) + " 当前训练")
                            ClubAIRoute.open(owner: owner, question: "我正在做「\(exercise.name)」。\(question)", references: FeatureFlagService.shared.referencesEnabled ? [ref] : [])
                            dismiss()
                        }
                    }
                }
            }.navigationTitle("动作帮助").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

private struct ClubBasicDraft: Codable {
    var nickname = ""
    var age = ""
    var sex = ""
    var height = ""
    var weight = ""
    var measured = false
    var observedAt = Date()
    static func url(_ owner: Int) -> URL { ClubChatDraftStorage.folder.appendingPathComponent("basic-\(owner).json") }
    static func load(_ owner: Int) -> Self { (try? Data(contentsOf: url(owner))).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self() }
    func save(_ owner: Int) {
        try? FileManager.default.createDirectory(at: ClubChatDraftStorage.folder, withIntermediateDirectories: true)
        var folder = ClubChatDraftStorage.folder; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url(owner), options: [.atomic, .completeFileProtection]) }
    }
}

struct ClubBasicProfileCard: View {
    let finished: () -> Void
    @EnvironmentObject private var account: AccountService
    private var legacyDraft: [String:JSONValue] {
        guard let owner=account.user?.id else { return [:] }
        let draft=ClubBasicDraft.load(owner)
        var values:[String:JSONValue]=[:]
        for (key,value) in [("nickname",draft.nickname),("age_years",draft.age),("height_cm",draft.height),("profile_weight_kg",draft.weight),("sex_for_nutrition",draft.sex)] where !value.isEmpty { values[key] = .string(value) }
        return values
    }
    private var legacyMeasurementDate: Date? {
        guard let owner=account.user?.id else { return nil }
        let draft=ClubBasicDraft.load(owner);return draft.measured ? draft.observedAt:nil
    }
    var body: some View {
        ProfileFactsForm133(title:"先认识你",fields:ProfileFields133.basics,onboardingBasics:true,suggestions:legacyDraft,initialMeasurementDate:legacyMeasurementDate) {
            if let owner=account.user?.id { try? FileManager.default.removeItem(at:ClubBasicDraft.url(owner)) }
            finished()
        }
    }
}

struct ClubInlineGuide: View {
    let step: String
    let message: String
    @EnvironmentObject private var store: AppStore
    @State private var hidden = false
    var body: some View {
        if let owner = store.editingAccountID, !hidden, !UserDefaults.standard.bool(forKey: "club.guide123.\(owner).\(step)") {
            HStack(alignment: .center, spacing: BojiLayout.inline) {
                Image(systemName: "hand.point.up.left")
                Text(message).bojiType(.label).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("稍后") { UserDefaults.standard.set(true, forKey: "club.guide123.\(owner).\(step)"); hidden = true }.bojiType(.caption).frame(minHeight: 44)
            }.padding(.horizontal, BojiLayout.rowGap).background(BojiColor.brandMist, in: RoundedRectangle(cornerRadius: 12))
        }
    }
    static func complete(_ step: String, owner: Int?) { if let owner { UserDefaults.standard.set(true, forKey: "club.guide123.\(owner).\(step)") } }
}

struct ClubReviewScope: Codable, Equatable {
    enum Kind: String, Codable { case daily, completedCalendarWeek, rolling7 }
    let kind: Kind
    let from: String
    let to: String
    let timeZone: String
    var endDate: Date { ClubDates.date(fromKey: to) ?? Date() }
    var contextDays: Int { kind == .daily ? 1 : 14 }
    var prompt: String {
        let label = kind == .daily ? "当日记录解读" : kind == .completedCalendarWeek ? "上一个完整自然周解读" : "截至所选日期的近七天解读"
        return "请做\(label)：\(from)—\(to)。先给我最重要的结论，再说说接下来可以怎么做。"
    }
    static func make(_ kind: Kind, through date: Date = Date()) -> Self {
        let cal = ClubDates.calendar
        var end = cal.startOfDay(for: min(date, Date()))
        if kind == .completedCalendarWeek { let offset = (cal.component(.weekday, from: end) + 5) % 7; end = cal.date(byAdding: .day, value: -offset - 1, to: end) ?? end }
        let start = kind == .daily ? end : cal.date(byAdding: .day, value: -6, to: end) ?? end
        return Self(kind: kind, from: ClubDates.key(start), to: ClubDates.key(end), timeZone: cal.timeZone.identifier)
    }
}

struct ClubAIRouteRequest {
    let owner: Int
    let question: String
    var conversation: String?
    var references: [AIContextReference] = []
    var source: ClubContextSource?
    var scope: ClubReviewScope?
    var sendImmediately131 = false
}
@MainActor enum ClubAIRoute {
    static let notification = Notification.Name("club.canonicalAI.route.v123")
    static func open(owner: Int, question: String = "", conversation: String? = nil, references: [AIContextReference] = [], source: ClubContextSource? = nil, scope: ClubReviewScope? = nil, sendImmediately131: Bool = false) {
        NotificationCenter.default.post(name: notification, object: ClubAIRouteRequest(owner: owner, question: question, conversation: conversation, references: references, source: source, scope: scope, sendImmediately131: sendImmediately131))
    }
}

struct ClubAIEntryBridge: View {
    var question = ""
    var conversation: String? = nil
    var scope: ClubReviewScope? = nil
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var routed = false
    var body: some View {
        ProgressView("正在回到 Club AI…").task {
            guard !routed, let owner = store.editingAccountID else { return }; routed = true
            ClubAIRoute.open(owner: owner, question: scope?.prompt ?? question, conversation: conversation, scope: scope)
            dismiss()
        }
    }
}

struct ClubCurrentTrainingHelp: View {
    var date = Date()
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Exercise?
    var body: some View {
        NavigationStack {
            List {
                if store.log(for: date).trainingLog.exercises.isEmpty { Text("当前没有可选择的训练动作。").foregroundStyle(.secondary) }
                ForEach(store.log(for: date).trainingLog.exercises) { exercise in
                    Button(exercise.name) { selected = exercise }
                }
            }.navigationTitle("选择当前动作")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
            .sheet(item: $selected) { exercise in ClubMovementHelp(exercise: exercise, date: date) }
        }
    }
}

struct ClubActionableTrainingNotices: View {
    let date: Date
    @EnvironmentObject private var store: AppStore
    var body: some View {
        let events = ClubInsightLedger.current(in: store.state, date: date).filter { [.plan, .training, .workout].contains($0.kind) && ClubInsightPriorityRules.isActionable($0) }
        if !events.isEmpty {
            DisclosureGroup("需要处理的事项 · \(events.count)") {
                ClubContextualInsightStrip(date: date, kinds: [.plan, .training, .workout])
            }.bojiType(.label)
        }
    }
}

struct ClubChatCameraRoute125: Identifiable {
    let id = UUID()
    let owner: Int
    let conversation: String
}

/// Always enters the camera surface. A denied/unavailable camera never silently opens Photos.
struct ClubChatCamera125: View {
    let thumbnail: UIImage?
    let onCapture: (Data) -> Void
    let onAlbum: () -> Void
    let onCancel: () -> Void
    @State private var authorized = false
    @State private var checked = false
    @Environment(\.openURL) private var openURL
    private var available: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    var body: some View {
        Group {
            if available && authorized {
                ClubCameraCapture(thumbnail:thumbnail,onCapture:onCapture,onAlbum:onAlbum,onCancel:onCancel)
            } else {
                NavigationStack {
                    VStack(spacing: BojiLayout.blockGap) {
                        Spacer()
                        Image(systemName:"camera").bojiType(.hero)
                        Text(!checked ? "正在准备相机…" : available ? "需要相机权限才能拍照" : "当前设备没有可用相机")
                            .bojiType(.section)
                        if checked && available {
                            Button("打开系统设置") { if let url = URL(string:UIApplication.openSettingsURLString) { openURL(url) } }
                                .buttonStyle(SecondaryButton())
                        }
                        Spacer()
                        HStack { Spacer(); Button("从相册选择",systemImage:"photo.on.rectangle",action:onAlbum).buttonStyle(SecondaryButton()) }
                    }.padding(BojiLayout.Rhythm.headerToContent)
                        .toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消",action:onCancel) } }
                        .navigationTitle("拍照上传").navigationBarTitleDisplayMode(.inline)
                }
            }
        }.task {
            guard available else { checked = true; return }
            let status = AVCaptureDevice.authorizationStatus(for:.video)
            let allowed = status == .authorized ? true : status == .notDetermined ? await AVCaptureDevice.requestAccess(for:.video) : false
            guard !Task.isCancelled else { return }
            authorized = allowed; checked = true
        }
    }
}
