import SwiftUI
import UIKit
import ImageIO

struct LibraryExercise: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let bodyPart: String
    let equipment: String
    let target: String
    let muscleGroup: String
    let secondaryMuscles: [String]
    let imageURL: String?
    let gifURL: String?
    var trainingTypeZH: String? = nil
    var suggestedRecordingUnit: String? = nil
    var nameZH: String? = nil
    var customID: UUID? { id.hasPrefix("custom-") ? UUID(uuidString: String(id.dropFirst(7))) : nil }
    var displayName: String { nameZH?.isEmpty == false ? nameZH! : ExerciseNames.display(name, id: id) }
    var equipmentZH: String? = nil
    var equipmentLabel: String { equipmentZH ?? equipmentName(equipment) }
    var muscleLabel: String { trainingTypeZH == "有氧" ? "心肺耐力" : muscleName(target.isEmpty ? bodyPart : target) }

    enum CodingKeys: String, CodingKey {
        case id, name, equipment, target
        case trainingTypeZH = "training_type_zh"
        case suggestedRecordingUnit = "suggested_recording_unit"
        case equipmentZH = "equipment_zh"
        case nameZH = "name_zh"
        case bodyPart = "body_part"
        case muscleGroup = "muscle_group"
        case secondaryMuscles = "secondary_muscles"
        case imageURL = "image_url"
        case gifURL = "gif_url"
    }
}

struct LibraryExerciseDetail: Codable {
    let id: String
    let catalogVisible: Bool
    let name: String
    let bodyPart: String
    let equipment: String
    let target: String
    let muscleGroup: String
    let secondaryMuscles: [String]
    let imageURL: String?
    let gifURL: String?
    let instructions: String
    let instructionSteps: [String]
    var trainingTypeZH: String? = nil
    var suggestedRecordingUnit: String? = nil
    var nameZH: String? = nil
    var copyReviewNeeded: Bool? = nil
    var equipmentZH: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, equipment, target
        case trainingTypeZH = "training_type_zh"
        case suggestedRecordingUnit = "suggested_recording_unit"
        case catalogVisible = "catalog_visible"
        case nameZH = "name_zh", instructions
        case copyReviewNeeded = "copy_review_needed"
        case equipmentZH = "equipment_zh"
        case bodyPart = "body_part"
        case muscleGroup = "muscle_group"
        case secondaryMuscles = "secondary_muscles"
        case imageURL = "image_url"
        case gifURL = "gif_url"
        case instructionSteps = "instruction_steps"
    }
}

fileprivate struct LibraryPage: Decodable {
    let total: Int
    let items: [LibraryExercise]
}

enum ExerciseLibraryAPI {
    private static let base: URL = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["BOJI_EXERCISE_BASE_URL"], let url = URL(string: override), ["https", "http"].contains(url.scheme ?? "") { return url }
        #endif
        if let configured = Bundle.main.object(forInfoDictionaryKey: "ExerciseAPIBaseURL") as? String, let url = URL(string: configured), url.scheme == "https" { return url }
        return URL(string: "https://117.50.119.49")!
    }()
    static func mediaURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value) else { return nil }
        if url.host == "dongzuo.gongxiang.cloud", url.path.hasPrefix("/media/") {
            var mapped = URLComponents(url: base, resolvingAgainstBaseURL: false)
            let original = URLComponents(url: url, resolvingAgainstBaseURL: false)
            mapped?.percentEncodedPath = original?.percentEncodedPath ?? url.path
            mapped?.percentEncodedQuery = original?.percentEncodedQuery
            return mapped?.url
        }
        return url
    }

    private static let aliases: [String: String] = [
        "杠铃深蹲": "barbell squat",
        "深蹲": "squat",
        "徒手深蹲": "bodyweight squat",
        "自重深蹲": "bodyweight squat",
        "高脚杯深蹲": "goblet squat",
        "杠铃卧推": "barbell bench press",
        "卧推": "bench press",
        "哑铃卧推": "dumbbell bench press",
        "上斜哑铃卧推": "incline dumbbell bench press",
        "跪姿俯卧撑": "knee push up",
        "俯卧撑": "push up",
        "坐姿划船": "seated cable row",
        "划船": "row",
        "单臂哑铃划船": "one arm dumbbell row",
        "哑铃划船": "dumbbell row",
        "罗马尼亚硬拉": "romanian deadlift",
        "硬拉": "deadlift",
        "哑铃推举": "dumbbell shoulder press",
        "肩推": "shoulder press",
        "哑铃弯举": "dumbbell curl",
        "弯举": "curl",
        "平板支撑": "plank",
        "臀桥": "glute bridge",
        "弓步蹲": "lunge",
        "卷腹": "crunch",
    ]

    static func lookupQueries(for value: String) -> [String] {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [""] }
        if raw.allSatisfy({ $0.isASCII }) { return [raw] }
        if let alias = aliases[raw] { return [alias, raw] }; return [raw]
    }

    static func preferredQuery(for value: String) -> String {
        lookupQueries(for: value).first ?? value
    }

    fileprivate static func page(_ query: String, bodyPart: String = "", limit: Int = 40, offset: Int = 0, trainingType: String = "") async throws -> LibraryPage {
        var components = URLComponents(url: base.appending(path: "/api/v1/exercises"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
        if !bodyPart.isEmpty { components.queryItems?.append(URLQueryItem(name: "body_part", value: bodyPart)) }
        if !trainingType.isEmpty { components.queryItems?.append(URLQueryItem(name: "training_type", value: trainingType)) }
        let page: LibraryPage = try await get(components.url!)
        return page
    }

    static func search(_ query: String, bodyPart: String = "", limit: Int = 40) async throws -> [LibraryExercise] {
        try await page(query, bodyPart: bodyPart, limit: limit).items
    }

    static func resolve(_ value: String, bodyPart: String = "", limit: Int = 40) async throws -> [LibraryExercise] {
        var results: [LibraryExercise] = []
        var seen = Set<String>()
        for query in lookupQueries(for: value) {
            let found = try await search(query, bodyPart: bodyPart, limit: limit)
            for item in found where seen.insert(item.id).inserted {
                results.append(item)
            }
            if results.count >= limit { break }
        }
        return Array(results.prefix(limit))
    }

    static func verifiedMovement(_ query: String) async throws -> LibraryExercise? {
        struct Resolution: Decodable { let item: LibraryExercise? }
        var components = URLComponents(url: base.appending(path: "/api/v1/resolve"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let response: Resolution = try await get(components.url!)
        return response.item
    }

    static func detail(_ id: String) async throws -> LibraryExerciseDetail {
        guard id.range(of: #"^[0-9A-Za-z_-]{1,64}$"#, options: .regularExpression) != nil else {
            throw URLError(.badURL)
        }
        var components = URLComponents(url: base.appending(path: "/api/v1/exercises/\(id)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "lang", value: "zh")]
        return try await get(components.url!)
    }

    private static func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 2_000_000 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension CustomExercise {
    var libraryItem: LibraryExercise {
        LibraryExercise(id: "custom-" + id.uuidString.lowercased(), name: name, bodyPart: bodyPart, equipment: equipment, target: muscle, muscleGroup: muscle, secondaryMuscles: [], imageURL: nil, gifURL: nil, nameZH: name, equipmentZH: equipment.isEmpty ? "器械未指定" : equipment)
    }
}

struct ExerciseLibraryView: View {
    @EnvironmentObject private var store: AppStore
    let date: Date
    let added: () -> Void
    let selectionAction: ((LibraryExercise) -> Void)?
    /// 独立页面/弹层自带纵向滚动；被父级 ScrollView 复用时关闭，避免双滚动。
    let embedded: Bool
    var selectedIDs: Set<String> = []
    @State private var query = ""

    init(date: Date, selectionAction: ((LibraryExercise) -> Void)? = nil, initialQuery: String = "", embedded: Bool = false, selectedIDs: Set<String> = [], added: @escaping () -> Void) {
        self.date = date; self.added = added; self.selectionAction = selectionAction
        self.embedded = embedded; self.selectedIDs = selectedIDs
        _query = State(initialValue: initialQuery)
    }
    @State private var bodyPart = ""
    @State private var trainingType = ""
    @State private var section = "推荐动作"
    @State private var customEditor: CustomExercise?
    @State private var creating = false
    @State private var pendingCustom: CustomExercise?
    @State private var deletingCustom: CustomExercise?
    @State private var confirmingDelete = false
    @State private var owner: Int?
    @State private var items: [LibraryExercise] = []
    @State private var total = 0
    @State private var queryTicket = UUID()
    @State private var selected: LibraryExercise?
    @State private var loading = false
    @State private var error: String?

    private let parts = ["", "chest", "back", "shoulders", "upper arms", "upper legs", "glutes", "lower legs", "waist", "cardio"]

    var body: some View { presentedLibrary }

    private var libraryContent: some View {
        Group {
            Picker("动作来源", selection: $section) { Text("推荐动作").tag("推荐动作"); Text("我的动作").tag("我的动作") }.clubAdaptivePicker()
            if embedded { TextField("搜索动作、肌群或器械", text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier("exercise-search") }
            if section == "我的动作" {
                Button { creating = true; customEditor = CustomExercise(name: query.trimmingCharacters(in: .whitespacesAndNewlines)) } label: { Label("创建自定义动作", systemImage: "plus.circle") }.buttonStyle(SecondaryButton()).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("exercise-create-custom")
                personalList
            } else {
                recommendedList
            }
        }
    }

    @ViewBuilder private var recommendedList: some View {

            trainingTypeFilter
            if !query.isEmpty || !bodyPart.isEmpty || !trainingType.isEmpty {
                HStack(spacing: BojiLayout.inline) {
                    if !query.isEmpty { filterChip("搜索：\(query)") { query = "" } }
                    if !bodyPart.isEmpty { filterChip("部位：\(partName(bodyPart))") { bodyPart = "" } }
                    if !trainingType.isEmpty { filterChip("类型：\(trainingType)") { trainingType = "" } }
                    Button("全部清除") { query = ""; bodyPart = ""; trainingType = "" }
                        .bojiType(.caption).foregroundStyle(BojiColor.textSecondary)
                        .frame(minHeight: ClubUI.minimumTap)
                }
            }
            Picker("训练部位", selection: $bodyPart) {
                ForEach(parts, id: \.self) { part in Text(partName(part)).tag(part) }
            }.pickerStyle(.menu)

            Text("云端动作库 · \(items.count) / \(total) 个结果").bojiType(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if loading && items.isEmpty { ClubLoadingSkeleton(title: "正在加载动作库…", rows: 3) }
            else if loading { ClubLoadingCard(title: "正在加载更多动作…") }
            if let error { Text(error).bojiType(.caption).foregroundStyle(.secondary) }
            if !loading && error == nil && items.isEmpty {
                EmptyNote(title: "没有找到符合条件的动作", detail: "试试较短的动作名称、肌群或器械名称，也可以清除筛选后查看。")
                if !query.isEmpty || !bodyPart.isEmpty || !trainingType.isEmpty {
                    Button("清除搜索与筛选") { query = ""; bodyPart = ""; trainingType = "" }.buttonStyle(SecondaryButton())
                }
            }
            ForEach(items) { item in recommendedRow(item) }
            if items.count < total {
                Button(loading ? "加载中…" : "加载更多动作") { Task { await fetchPage(reset: false) } }.buttonStyle(SecondaryButton()).disabled(loading)
            }
            if error != nil { Button("重新加载") { Task { await fetchPage(reset: true) } }.buttonStyle(SecondaryButton()).disabled(loading) }
            Text("选择动作可查看演示和要领；训练记录使用你实际完成的组次。")
                .bojiType(.caption).foregroundStyle(BojiColor.textTertiary).fixedSize(horizontal: false, vertical: true)
    }

    private func recommendedRow(_ item: LibraryExercise) -> some View {
        Button {
            if let selectionAction { selectionAction(item) } else { selected = item }
        } label: {
            VStack(spacing: 0) {
                recommendedRowContents(item)
                    .padding(.vertical, BojiSpace.general)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                if embedded { Divider().overlay(BojiColor.divider) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("library-exercise-" + item.id).accessibilityValue(selectedIDs.contains(item.id) ? "已选择" : "未选择")
    }
    private func recommendedRowContents(_ item: LibraryExercise) -> some View {
        HStack(alignment: .top, spacing: BojiLayout.rowGap) {
            ExerciseLibraryThumbnail(item: item)
                .frame(width: 44, height: 44)
                .background(BojiColor.cardSurface.opacity(0.7), in: RoundedRectangle(cornerRadius: BojiRadius.inner))
            VStack(alignment: .leading, spacing: BojiLayout.tight) {
                Text(item.displayName).bojiFont(.exerciseName).multilineTextAlignment(.leading)
                Text(partName(item.bodyPart) + " · " + item.equipmentLabel)
                    .bojiType(.caption).foregroundStyle(.secondary)
                if let detail = trainingDetail(item) {
                    Text(detail).bojiType(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: selectionAction == nil ? "chevron.right" : selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle").bojiType(.section)
        }
    }
    private func trainingDetail(_ item: LibraryExercise) -> String? {
        guard let type = item.trainingTypeZH else { return nil }
        let unit = item.suggestedRecordingUnit == "time" ? " · 按时长" : " · 按次数"
        let availability = item.gifURL == nil ? " · 文字记录" : ""
        return type + unit + availability
    }

    private var presentedLibrary: some View {
        // AUD-020/FIX-020：统一嵌入与独立路径，长列表必须有纵向滚动，
        // 否则搜索、筛选和“我的动作”会被裁出屏幕。
        Group {
            if embedded { LazyVStack(spacing: BojiLayout.rowGap) { libraryContent } }
            else {
                List { libraryContent }.clubManagementList132()
                    .searchable(text: $query, prompt: "搜索动作、肌群或器械")
            }
        }
        .onAppear { if owner == nil { owner = store.editingAccountID } }
        .onChange(of: store.editingAccountID) { _, id in if owner != id { customEditor = nil; pendingCustom = nil; selected = nil; deletingCustom = nil; error = "账号已变化，请重新打开动作库。" } }
        .task(id: section + "|" + query + "|" + bodyPart + "|" + trainingType) {
            guard section == "推荐动作" else { queryTicket = UUID(); loading = false; error = nil; return }
            do { try await Task.sleep(for: .milliseconds(250)); await fetchPage(reset: true) } catch { }
        }
        .background { ClubBackground() }
        .sheet(item: $customEditor, onDismiss: { if let item = pendingCustom { pendingCustom = nil; useCustom(item) } }) { item in
            CustomExerciseEditor(initial: item, owner: owner) { saved in if creating { pendingCustom = saved }; section = "我的动作"; query = "" }
        }
        .confirmationDialog("从我的动作中删除？", isPresented: $confirmingDelete, titleVisibility: .visible, presenting: deletingCustom) { item in
            Button("删除个人动作", role: .destructive) { guard owner != nil, owner == store.editingAccountID else { error = "账号已变化。"; return }; if !store.deleteCustomExercise(item.id) { error = store.takeMessage() } }
            Button("取消", role: .cancel) { }
        } message: { _ in Text("已经加入计划或训练记录的动作会保留。") }
        .sheet(item: $selected) { item in
            LibraryExerciseDetailView(item: item, date: date) { added() }
        }

    }
    private func filterChip(_ label: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: BojiLayout.tight) {
                Text(label).lineLimit(1)
                Image(systemName: "xmark.circle.fill").bojiType(.caption)
            }
            .bojiType(.caption)
            .padding(.horizontal, BojiLayout.inline).padding(.vertical, BojiSpace.tight)
            .background(BojiColor.inputSurface, in: Capsule())
            .foregroundStyle(BojiColor.textPrimary)
            .frame(minHeight: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("清除筛选 \(label)")
    }

    private var trainingTypeFilter: some View {
        Picker("训练类型", selection: $trainingType) {
            ForEach(["", "力量／稳定性", "有氧", "体能／全身", "拉伸／活动度"], id: \.self) { type in
                Text(type.isEmpty ? "全部类型" : type).tag(type)
            }
        }.pickerStyle(.menu)
    }
    private var personalItems: [CustomExercise] { store.customExercises.filter { query.isEmpty || ($0.name + " " + $0.muscle + " " + $0.equipment).localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    private var personalList: some View {
        VStack(spacing: BojiLayout.rowGap) {
            Text("仅你可见 · 保存到账号，联网后同步").bojiType(.label).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if personalItems.isEmpty {
                EmptyNote(title: store.customExercises.isEmpty ? "这里是你的个人动作库" : "没有找到符合搜索的个人动作", detail: store.customExercises.isEmpty ? "找不到常练的动作？输入名称，选次数或时长即可创建；无需动图。" : "试试较短的动作名称，或清除搜索查看所有个人动作。")
                if !query.isEmpty { Button("清除搜索") { query = "" }.buttonStyle(SecondaryButton()) }
            }
            ForEach(personalItems) { item in
                ClubCard {
                    HStack(spacing: BojiLayout.rowGap) {
                        Button { useCustom(item) } label: {
                            HStack(spacing: BojiLayout.rowGap) {
                                Image(systemName: item.unit == "秒" ? "timer" : "dumbbell").bojiType(.section).frame(width: 44, height: 44).background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: BojiRadius.inner))
                                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                                    Text(item.name).bojiType(.secondary).multilineTextAlignment(.leading)
                                    Text((item.unit == "秒" ? "按时长 · 每组秒数" : "按次数 · 每组次数与重量") + (item.muscle.isEmpty ? "" : " · " + item.muscle)).bojiType(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: selectionAction == nil ? "plus.circle" : "arrow.triangle.2.circlepath")
                            }
                        }.buttonStyle(ClubMotionButton())
                        Menu {
                            Button("编辑") { creating = false; customEditor = item }
                            Button("删除", role: .destructive) { deletingCustom = item; confirmingDelete = true }
                        } label: { Image(systemName: "ellipsis").accessibilityLabel("管理" + item.name) }
                            .buttonStyle(ClubIconButtonStyle())
                    }
                }
            }
            if let error { Text(error).bojiType(.label).foregroundStyle(.red) }
        }
    }
    private func useCustom(_ item: CustomExercise) {
        guard owner != nil, owner == store.editingAccountID else { error = "账号已变化，请重新打开动作库。"; return }
        if let selectionAction { selectionAction(item.libraryItem) }
        else if store.addCustomExercise(item.id, on: date) { error = nil; added() }
        else { error = store.takeMessage() }
    }
    private func fetchPage(reset: Bool) async {
        if reset { queryTicket = UUID(); items = []; total = 0 }
        let ticket = queryTicket; let selectedQuery = query; let selectedPart = bodyPart; let selectedType = trainingType
        loading = true; error = nil
        do {
            let page = try await ExerciseLibraryAPI.page(selectedQuery, bodyPart: selectedPart, offset: reset ? 0 : items.count, trainingType: selectedType)
            guard ticket == queryTicket, selectedQuery == query, selectedPart == bodyPart, selectedType == trainingType, !Task.isCancelled else { return }
            if reset { items = page.items } else { items.append(contentsOf: page.items) }
            total = page.total
        } catch { if ticket == queryTicket { self.error = "动作库暂时无法连接，请重试。" } }
        if ticket == queryTicket { loading = false }
    }

}

enum ExerciseMediaPolicy {
    static var thirdPartyDemoEnabled: Bool { true }
    static let pendingNotice = "这项动作暂无演示素材，可查看下方动作要领。"
}

private struct ExerciseLibraryThumbnail: View {
    let item: LibraryExercise
    var body: some View {
        if ExerciseMediaPolicy.thirdPartyDemoEnabled, let url = ExerciseLibraryAPI.mediaURL(item.imageURL) {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFit() }
                else if phase.error != nil { Image(systemName: "figure.strengthtraining.traditional").foregroundStyle(.secondary) }
                else { ClubCompactWait() }
            }
        } else {
            Image(systemName: item.trainingTypeZH == "有氧" ? "figure.walk" : "figure.strengthtraining.traditional")
                .bojiType(.section).foregroundStyle(.secondary)
        }
    }
}

struct ExerciseDemoButton: View {
    let exercise: Exercise
    @State private var selected: LibraryExercise?
    @State private var loading = false
    @State private var unavailable = false
    @State private var showUnavailable = false
    @State private var failed = false
    @State private var hiddenLegacy = false

    var body: some View {
        Button {
            guard exercise.customExerciseID == nil else { unavailable = true; showUnavailable = true; return }
            loading = true; hiddenLegacy = false
            Task {
                defer { loading = false }
                do {
                    if let id = exercise.libraryID {
                        let detail = try await ExerciseLibraryAPI.detail(id)
                        if detail.catalogVisible {
                            selected = LibraryExercise(id: detail.id, name: detail.name, bodyPart: detail.bodyPart,
                                                       equipment: detail.equipment, target: detail.target,
                                                       muscleGroup: detail.muscleGroup, secondaryMuscles: detail.secondaryMuscles,
                                                       imageURL: detail.imageURL, gifURL: detail.gifURL, trainingTypeZH: detail.trainingTypeZH, suggestedRecordingUnit: detail.suggestedRecordingUnit, nameZH: detail.nameZH, equipmentZH: detail.equipmentZH)
                        } else {
                            selected = nil; hiddenLegacy = true
                        }
                    } else {
                        let lookup = ExerciseLibraryAPI.preferredQuery(for: exercise.libraryQuery ?? exercise.name)
                        selected = try await ExerciseLibraryAPI.verifiedMovement(lookup)
                    }
                    unavailable = selected == nil; showUnavailable = unavailable; failed = false
                } catch { failed = true }
            }
        } label: {
            HStack(spacing: BojiLayout.inline) {
                if loading { ClubActivityMark(size: 16) }
                Label(exercise.customExerciseID != nil ? "个人动作" : loading ? "查找中…" : unavailable ? "暂无演示" : failed ? "重试" : "动作要领", systemImage: "play.rectangle")
            }
        }
        .buttonStyle(.borderless)
        .bojiType(.caption)
        .frame(minHeight: 44)

        .accessibilityLabel("查看动作演示与要领")
        .disabled(loading)
        .alert("暂无经过核对的匹配演示", isPresented: $showUnavailable) {
            Button("知道了", role: .cancel) { }
        } message: { Text(exercise.customExerciseID != nil ? "这是你创建的个人动作，没有经过核对的演示素材，不会自动匹配其他动作的图片。" : hiddenLegacy ? "这是保留在历史记录中的旧动作，已不列入当前动作库。原训练记录会保留，但不能从当前动作库再次添加。" : "当前动作库没有这项动作的可靠匹配，暂不播放其他变体。可从动作库查看准确名称与器械，再确认适合的动作。") }
        .sheet(item: $selected) { LibraryExerciseDetailView(item: $0, date: nil, added: nil) }
    }
}

struct ExerciseAnatomyGuideCard: View {
    let item: LibraryExercise
    let detail: LibraryExerciseDetail?

    private var primaryMuscleText: String {
        let raw = detail?.target ?? item.target
        return raw.isEmpty ? partName(item.bodyPart) : muscleName(raw)
    }

    private var secondaryMusclesText: [String] {
        let list = detail?.secondaryMuscles ?? item.secondaryMuscles
        return list.prefix(3).map { muscleName($0) }
    }

    private var tempoGuide: String {
        if item.trainingTypeZH == "有氧" {
            return "均匀步频 · 稳定心率区间 · 鼻吸口呼"
        }
        if item.suggestedRecordingUnit == "time" {
            return "核心收紧 · 保持骨盆中立 · 均匀呼吸不憋气"
        }
        return "离心下放 2s · 底部停顿 1s · 向心发力 1s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            HStack(spacing: BojiLayout.rowGap) {
                ZStack {
                    Circle()
                        .fill(BojiColor.accentBrand.opacity(0.14))
                        .frame(width: 52, height: 52)
                    Image(systemName: item.trainingTypeZH == "有氧" ? "heart.circle.fill" : "figure.strengthtraining.traditional")
                        .bojiType(.section)
                        .foregroundStyle(BojiColor.accentBrand)
                }
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    HStack(spacing: BojiLayout.tight) {
                        Text("目标肌群与发力节奏")
                            .bojiType(.caption)
                            .foregroundStyle(BojiColor.accentBrand)
                        Text(partName(item.bodyPart))
                            .bojiType(.caption)
                            .padding(.horizontal, BojiSpace.tightRow)
                            
                            .background(BojiColor.subtleSurface, in: Capsule())
                            .foregroundStyle(BojiColor.textSecondary)
                    }
                    Text("主发力：\(primaryMuscleText)")
                        .bojiType(.bodyStrong)
                        .foregroundStyle(BojiColor.textPrimary)
                }
                Spacer(minLength: 0)
            }

            if !secondaryMusclesText.isEmpty {
                HStack(spacing: BojiLayout.tight) {
                    Text("协同肌群：")
                        .bojiType(.caption)
                        .foregroundStyle(BojiColor.textSecondary)
                    ForEach(secondaryMusclesText, id: \.self) { sec in
                        Text(sec)
                            .bojiType(.caption)
                            .padding(.horizontal, BojiSpace.tightRow)
                            .padding(.vertical, BojiLayout.tight)
                            .background(BojiColor.subtleSurface, in: Capsule())
                            .foregroundStyle(BojiColor.textPrimary)
                    }
                }
            }

            HStack(spacing: BojiLayout.inline) {
                Image(systemName: "metronome.fill")
                    .bojiType(.caption)
                    .foregroundStyle(ClubBrand.accent)
                Text(tempoGuide)
                    .bojiType(.caption)
                    .foregroundStyle(BojiColor.textSecondary)
            }
            .padding(.horizontal, BojiSpace.general)
            .padding(.vertical, BojiSpace.tightRow)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: BojiRadius.inner, style: .continuous))
        }
        .padding(ClubUI.cardInset)
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
    }
}

struct LibraryExerciseDetailView: View {
    let item: LibraryExercise
    let date: Date?
    let added: (() -> Void)?
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var detail: LibraryExerciseDetail?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BojiLayout.cardInset) {
                    if ExerciseMediaPolicy.thirdPartyDemoEnabled, item.gifURL != nil {
                        AnimatedGIFView(url: ExerciseLibraryAPI.mediaURL(item.gifURL))
                            .frame(maxWidth: .infinity).frame(height: 260)
                            .background(ClubUI.surface, in: RoundedRectangle(cornerRadius: ClubUI.cardRadius, style: .continuous))
                    } else {
                        ExerciseAnatomyGuideCard(item: item, detail: detail)
                        EmptyNote(title: "文字要领", detail: ExerciseMediaPolicy.pendingNotice)
                    }
                    HStack {
                        Label(partName(item.bodyPart), systemImage: "figure.strengthtraining.traditional")
                        Spacer()
                        Label(item.equipmentLabel, systemImage: "dumbbell")
                    }.bojiType(.caption).foregroundStyle(.secondary)
                    if let detail {
                        Text("动作要领").bojiFont(.cardTitle).foregroundStyle(BojiColor.textPrimary)
                        if detail.copyReviewNeeded == true {
                            Text("这个动作的文字说明正在核对，可先选择其他熟悉的动作。")
                                .bojiType(.secondary).foregroundStyle(.secondary)
                        } else if detail.instructionSteps.isEmpty { Text(detail.instructions).bojiType(.secondary) }
                        else {
                            ForEach(Array(detail.instructionSteps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .top) {
                                    Text("\(index + 1)").bojiType(.caption).frame(width: 24, height: 24).background(.black, in: Circle()).foregroundStyle(.white)
                                    Text(step).bojiType(.secondary)
                                }
                            }
                        }
                    } else if let error { Text(error).foregroundStyle(.secondary) }
                    else { ClubLoadingCard(title: "正在加载动作说明…") }
                    if let date, let added {
                        Button("加入 \(ClubDates.label(date)) 的训练") {
                            guard store.addExercise(item, on: date) else { error = store.takeMessage(fallback: "本机保存失败，请重试。"); return }
                            added()
                            dismiss()
                        }.buttonStyle(PrimaryButton())
                    }
                }.padding(ClubUI.pageInset)
            }
            .background { ClubBackground() }
            .navigationTitle(item.displayName).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
            .task {
                do { detail = try await ExerciseLibraryAPI.detail(item.id) }
                catch { self.error = "动作说明加载失败，请稍后重试。" }
            }
        }
    }
}

@MainActor
private final class GIFLoader: ObservableObject {
    @Published var image: GIFAnimation?
    @Published var error: String?
    @Published var loading = false
    private var task: Task<Void, Never>?
    func cancel() { task?.cancel(); task = nil; loading = false }
    func load(_ url: URL?) {
        task?.cancel(); image = nil; error = nil; loading = true
        guard let url else { loading = false; error = "暂无动态演示，请参考下面的动作要领。"; return }
        if let cached = Self.cache.object(forKey: url.absoluteString as NSString) {
            image = cached; loading = false; return
        }
        task = Task {
            do {
                let downloader = GIFDownload()
                let data = try await withTaskCancellationHandler(operation: { try await downloader.fetch(url) }, onCancel: { downloader.cancel() })
                try Task.checkCancellation()
                let animated = try await Self.decodeGate.decode(data)
                try Task.checkCancellation()
                guard let animated else { throw URLError(.cannotDecodeContentData) }
                Self.cache.setObject(animated, forKey: url.absoluteString as NSString, cost: animated.cost)
                image = animated; loading = false
            } catch { if !Task.isCancelled { loading = false; self.error = "演示加载失败或图片过大，可以重试或查看动作要领。" } }
        }
    }
    deinit { task?.cancel() }
    private static let decodeGate = GIFDecodeGate()
    private static let cache: NSCache<NSString, GIFAnimation> = {
        let cache = NSCache<NSString, GIFAnimation>(); cache.totalCostLimit = 64 * 1024 * 1024; cache.countLimit = 8
        return cache
    }()
    nonisolated fileprivate static func animatedImage(_ data: Data) -> GIFAnimation? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= 240 else { return nil }
        var frames: [UIImage] = []; var delays: [Double] = []; var bytes = 0
        // Bound the entire decoded animation, not just each frame. A longer
        // demonstration uses smaller thumbnails instead of failing halfway.
        let memoryBudget = 48 * 1024 * 1024
        let pixelLimit = min(600, max(1, Int(sqrt(Double(memoryBudget) / Double(count * 4)) * 0.90)))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelLimit, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true]
        for index in 0..<count {
            guard !Task.isCancelled else { return nil }
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
            bytes += cg.bytesPerRow * cg.height
            guard bytes <= memoryBudget else { return nil }
            frames.append(UIImage(cgImage: cg))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.08
            // Preserve valid source timings, including deliberate holds.
            // Only malformed/zero delays use a fallback to avoid a busy loop.
            delays.append(delay.isFinite && delay > 0 ? delay : 0.10)
        }
        return GIFAnimation(frames: frames, delays: delays, cost: bytes)
    }
}

// Bound concurrent decoding across pages. Awaiting a slot releases the actor;
// cancellation stops both waiting and the per-frame worker.
private actor GIFDecodeGate {
    private var running = 0
    func decode(_ data: Data) async throws -> GIFAnimation? {
        while running >= 2 { try await Task.sleep(for: .milliseconds(20)) }
        try Task.checkCancellation()
        running += 1; defer { running -= 1 }
        let worker = Task.detached(priority: .userInitiated) { GIFLoader.animatedImage(data) }
        return try await withTaskCancellationHandler(operation: {
            let result = await worker.value
            try Task.checkCancellation()
            return result
        }, onCancel: { worker.cancel() })
    }
}

// URLSession delivers chunks, avoiding millions of individual byte appends.
// Every mutable field is protected by lock; finish resumes exactly once.
private final class GIFDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var request: URLSessionDataTask?
    private var cancelled = false
    private var finished = false
    private let maximum = 8_000_000
    private static let sharedConfiguration: URLSessionConfiguration = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 4
        return config
    }()

    func fetch(_ url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let configuration = Self.sharedConfiguration
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let request = session.dataTask(with: url)
            self.session = session; self.request = request
            lock.unlock()
            request.resume()
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true; self.continuation = nil
        let session = self.session; self.session = nil; request = nil; buffer = Data()
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= maximum else {
            finish(.failure(URLError(.badServerResponse))); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= maximum - buffer.count else { lock.unlock(); finish(.failure(URLError(.dataLengthExceedsMaximum))); return }
        buffer.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock(); let data = buffer; lock.unlock()
        finish(.success(data))
    }
}

// Immutable decoded frames are produced off the main thread. Playback state
// and UIImageView mutations are confined to the main actor.
private final class GIFAnimation: NSObject, @unchecked Sendable {
    let frames: [UIImage]
    let delays: [Double]
    let cost: Int
    var duration: Double { delays.reduce(0, +) }
    init(frames: [UIImage], delays: [Double], cost: Int) {
        self.frames = frames; self.delays = delays; self.cost = cost
    }
}

@MainActor
private final class GIFTickTarget: NSObject {
    weak var player: GIFPlaybackView?
    @objc func tick(_ link: CADisplayLink) { player?.tick(link) }
}

@MainActor
private final class GIFPlaybackView: UIImageView {
    private var animation: GIFAnimation?
    private var displayLink: CADisplayLink?
    private let tickTarget = GIFTickTarget()
    private var frameIndex = 0
    private var elapsed = 0.0
    private var lastTimestamp = 0.0
    private var paused = false
    func configure(_ value: GIFAnimation, paused: Bool) {
        if animation !== value {
            animation = value; frameIndex = 0; elapsed = 0; lastTimestamp = 0
            image = value.frames.first
        }
        self.paused = paused
        updatePlayback()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); updatePlayback() }
    private func updatePlayback() {
        let shouldPlay = window != nil && !paused && (animation?.frames.count ?? 0) > 1
        if shouldPlay, displayLink == nil {
            tickTarget.player = self
            let link = CADisplayLink(target: tickTarget, selector: #selector(GIFTickTarget.tick(_:)))
            link.preferredFramesPerSecond = 60
            link.add(to: .main, forMode: .common); displayLink = link; lastTimestamp = 0
        } else if !shouldPlay { stopPlayback() }
    }
    func stopPlayback() { displayLink?.invalidate(); displayLink = nil; lastTimestamp = 0 }
    func tick(_ link: CADisplayLink) {
        guard let animation, animation.frames.count > 1 else { return }
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp > 0 else { return }
        let previousIndex = frameIndex
        elapsed += max(0, link.timestamp - lastTimestamp)
        if elapsed >= animation.duration { elapsed.formTruncatingRemainder(dividingBy: animation.duration) }
        while elapsed >= animation.delays[frameIndex] {
            elapsed -= animation.delays[frameIndex]
            frameIndex = (frameIndex + 1) % animation.frames.count
        }
        if frameIndex != previousIndex {
            let next = animation.frames[frameIndex]
            self.image = next
        }
    }
}

private struct GIFImageView: UIViewRepresentable {
    let image: GIFAnimation
    let paused: Bool
    func makeUIView(context: Context) -> GIFPlaybackView {
        let view = GIFPlaybackView(); view.contentMode = .scaleAspectFit
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateUIView(_ view: GIFPlaybackView, context: Context) { view.configure(image, paused: paused) }
    static func dismantleUIView(_ view: GIFPlaybackView, coordinator: ()) { view.stopPlayback(); view.image = nil }
}

private struct AnimatedGIFView: View {
    let url: URL?
    @StateObject private var loader = GIFLoader()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var allowsMotion = false
    @State private var paused = false
    var body: some View {
        Group {
            if let image = loader.image {
                VStack(spacing: BojiLayout.inline) {
                    GIFImageView(image: image, paused: paused || (reduceMotion && !allowsMotion) || scenePhase != .active)
                    Button(paused || (reduceMotion && !allowsMotion) ? "播放演示" : "暂停演示", systemImage: paused || (reduceMotion && !allowsMotion) ? "play.circle" : "pause.circle") {
                        if reduceMotion && !allowsMotion { allowsMotion = true; paused = false }
                        else { paused.toggle() }
                    }
                        .bojiType(.caption).buttonStyle(ClubMotionButton())
                }
            }
            else if let error = loader.error {
                VStack { Text(error).bojiType(.caption); if url != nil { Button("重试") { loader.load(url) }.buttonStyle(SecondaryButton()) } }
            } else { ClubLoadingCard(title: "正在加载动作演示…") }
        }.task(id: url) { loader.load(url) }
            .onDisappear { loader.cancel() }
    }
}

private func partName(_ value: String) -> String {
    ["": "全部", "chest": "胸部", "back": "背部", "shoulders": "肩部", "upper arms": "手臂",
     "upper legs": "大腿", "glutes": "臀部", "lower legs": "小腿", "lower arms": "前臂", "neck": "颈部", "waist": "核心", "cardio": "有氧"][value.lowercased()] ?? value
}

private func equipmentName(_ value: String) -> String {
    ["body weight": "徒手", "dumbbell": "哑铃", "barbell": "杠铃", "cable": "拉力器",
     "band": "弹力带", "resistance band": "弹力带", "kettlebell": "壶铃", "smith machine": "史密斯机",
     "assisted": "辅助器械", "bosu ball": "半圆平衡球", "elliptical machine": "椭圆机",
     "ez barbell": "曲杆杠铃", "hammer": "训练锤", "leverage machine": "固定器械",
     "medicine ball": "药球", "olympic barbell": "奥林匹克杠铃", "roller": "滚筒",
     "rope": "训练绳", "skierg machine": "滑雪训练机", "sled machine": "雪橇训练器械",
     "stability ball": "健身球", "stationary bike": "健身车", "stepmill machine": "登阶机",
     "tire": "轮胎", "trap bar": "六角杠铃", "upper body ergometer": "上肢功率训练器",
     "weighted": "额外负重", "wheel roller": "健腹轮"][value.lowercased()] ?? value
}


private func muscleName(_ value: String) -> String {
    ["abductors": "髋外展肌群", "abs": "腹肌", "adductors": "髋内收肌群", "biceps": "肱二头肌",
     "calves": "小腿肌群", "cardiovascular system": "心肺", "delts": "三角肌", "forearms": "前臂",
     "glutes": "臀肌", "hamstrings": "大腿后侧肌群", "lats": "背阔肌", "levator scapulae": "肩胛提肌",
     "pectorals": "胸肌", "quads": "股四头肌", "serratus anterior": "前锯肌", "spine": "背部肌群",
     "traps": "斜方肌", "triceps": "肱三头肌", "upper back": "上背部"][value.lowercased()] ?? partName(value)
}



private struct CustomExerciseEditor: View {
    let initial: CustomExercise
    let owner: Int?
    let saved: (CustomExercise) -> Void
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CustomExercise()
    @State private var loaded = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("动作名称") { TextField("例如：弹力带侧向走", text: $draft.name); Text("1–60 字，使用你自己能辨认的名称。").bojiType(.label).foregroundStyle(.secondary) }
                Section("怎样记录每一组？") {
                    Picker("记录方式", selection: $draft.unit) { Text("按次数").tag("次"); Text("按时长").tag("秒") }.clubAdaptivePicker()
                    Text(draft.unit == "秒" ? "每组填写持续秒数，例如平板支撑；不把组间休息当作动作时长。" : "每组填写实际次数与可选重量；徒手动作的重量保持 0。").bojiType(.label).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("补充肌群与器械（可选）") {
                        Picker("主要部位", selection: $draft.muscle) { Text("未指定").tag(""); ForEach(CustomExercise.muscles, id: \.self) { Text($0).tag($0) } }
                        TextField("器械，例如弹力带、哑铃", text: $draft.equipment)
                    }
                }
                Section { Text("仅保存到你的账号，不进入公共动作库。编辑名称或记录方式只影响以后添加，过去的计划和训练原样保留；不会自动生成动作演示。").bojiType(.label).foregroundStyle(.secondary) }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.clubManagementList132().clubGroupedSurface().navigationTitle("我的动作").navigationBarTitleDisplayMode(.inline)
                .onAppear { if !loaded { draft = initial; loaded = true } }
                .onChange(of: store.editingAccountID) { _, id in if owner != id { dismiss() } }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") {
                        guard owner != nil, owner == store.editingAccountID else { error = "账号已变化，请重新打开。"; return }
                        if store.saveCustomExercise(draft), let actual = store.customExercises.first(where: { $0.id == draft.id }) { saved(actual); dismiss() }
                        else { error = store.takeMessage() }
                    }.disabled(!loaded) }
                }
        }
    }
}

#if DEBUG
enum ExerciseAuditFactory {
 static func custom(owner: Int?) -> some View { CustomExerciseEditor(initial: CustomExercise(), owner: owner, saved: { _ in }) }
}
#endif
