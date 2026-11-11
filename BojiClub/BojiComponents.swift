import SwiftUI

// 公共组合组件：各页面从这里取用，禁止每页复制颜色与阴影代码。

// MARK: - 动作缩略图

/// 动作缩略图。列表默认静态图；示范播放只在当前可见动作进行（见 ExerciseDemoButton）。
struct BojiExerciseThumb: View {
    let exercise: Exercise
    var side: CGFloat = 64
    @State private var resolvedURL: String?
    var body: some View {
        BojiThumbImage(urlString: resolvedURL ?? exercise.imageURL, fallback: exercise.displayName)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: BojiRadius.image * side / 88, style: .continuous))
            .task(id: exercise.libraryID) {
                guard let id = exercise.libraryID, exercise.customExerciseID == nil else { return }
                resolvedURL = try? await ExerciseMediaRepository.shared.thumbnail(id: id)
            }
    }
}

actor ExerciseMediaRepository {
    static let shared = ExerciseMediaRepository()
    private var cache: [String: String] = [:]
    private var pending: [String: Task<String?, Error>] = [:]
    func thumbnail(id: String) async throws -> String? {
        if let value = cache[id] { return value }
        if let task = pending[id] { return try await task.value }
        let task = Task { try await ExerciseLibraryAPI.detail(id).imageURL }
        pending[id] = task
        defer { pending[id] = nil }
        let value = try await task.value
        if let value { cache[id] = value }
        return value
    }
}

/// 静态缩略图源：网络图走统一缓存，无图时用沙金图形占位（不伪造照片）。
struct BojiThumbImage: View {
    let urlString: String?
    let fallback: String
    var body: some View {
        if let urlString, let url = ExerciseLibraryAPI.mediaURL(urlString) {
            BojiCachedThumb(url: url, fallback: fallback)
        } else {
            BojiCoverGraphic(title: fallback, compact: true)
        }
    }
}

private struct BojiCachedThumb: View {
    let url: URL
    let fallback: String
    var body: some View {
        // AsyncImage 走 URLCache，同一素材不会逐卡重复下载。
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                BojiCoverGraphic(title: fallback, compact: true)
            default:
                BojiColor.inputSurface
            }
        }
    }
}

// MARK: - BOJI 专用封面图形

/// 沙金点阵封面：无照片素材时的自有图形封面（不裁剪竞品截图）。
struct BojiCoverGraphic: View {
    let title: String
    var compact = false
    var body: some View {
        ZStack {
            LinearGradient(colors: [BojiColor.inputSurface, BojiColor.subtleSurface],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { proxy in
                let cell = proxy.size.width / (compact ? 10 : 16)
                VStack(spacing: cell * 0.45) {
                    ForEach(0..<(compact ? 5 : 8), id: \.self) { row in
                        HStack(spacing: cell * 0.45) {
                            ForEach(0..<(compact ? 10 : 16), id: \.self) { col in
                                Circle()
                                    .fill(BojiColor.coverSand.opacity(dotOpacity(row: row, col: col)))
                                    .frame(width: cell * 0.55, height: cell * 0.55)
                            }
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            }
            if !compact {
                VStack {
                    Spacer()
                    HStack {
                        Text(title).bojiFont(.cardTitle)
                            .foregroundStyle(BojiColor.textPrimary)
                            .lineLimit(1)
                        Spacer()
                    }
                }
                .padding(BojiSpace.general)
            }
        }
        .allowsHitTesting(false)
    }

    /// 同心圆渐隐点阵，形成中心亮、边缘淡的沙金纹理。
    private func dotOpacity(row: Int, col: Int) -> Double {
        let rows = compact ? 5 : 8, cols = compact ? 10 : 16
        let dx = Double(col) / Double(cols - 1) - 0.5
        let dy = Double(row) / Double(rows - 1) - 0.5
        let distance = (dx * dx + dy * dy).squareRoot()
        return max(0.12, 0.75 - distance * 1.1)
    }
}

// MARK: - 提示带

/// 浅灰提示带：训练建议等轻量信息；没有证据时不显示，不制造建议。
#if DEBUG
struct BojiTipBand: View {
    let text: String
    var systemImage: String = "info.circle"
    var body: some View {
        HStack(spacing: BojiSpace.tightRow) {
            Image(systemName: systemImage).font(.footnote)
            Text(text).bojiFont(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(BojiColor.textSecondary)
        .padding(.horizontal, BojiSpace.general)
        .padding(.vertical, 10)
        .bojiInset(cornerRadius: BojiRadius.input, background: BojiColor.subtleSurface)
    }
}

// MARK: - 页面入口行

/// 图标＋文字＋右箭头，整行可点击。
#endif

struct BojiEntryRow: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: BojiSpace.general) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BojiColor.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(BojiColor.subtleSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(BojiColor.outline, lineWidth: 0.5)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).bojiFont(.body).foregroundStyle(BojiColor.textPrimary)
                    if let detail {
                        Text(detail).bojiFont(.secondary).foregroundStyle(BojiColor.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(BojiColor.textTertiary)
            }
            .frame(minHeight: BojiSize.minimumTap)
            .contentShape(Rectangle())
        }
        .buttonStyle(BojiRowPressStyle())
    }
}

private struct BojiRowPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .bojiSnappy, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { BojiHaptics.tick() }
            }
    }
}

// MARK: - 分段进度

/// 分段进度：一格代表一组，完成格实心。收起动作卡与详情共用。
struct BojiSegmentedProgress: View {
    let total: Int
    let completed: Int
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<max(total, 1), id: \.self) { index in
                Capsule()
                    .fill(index < completed ? BojiColor.emeraldAccent : BojiColor.inputSurface)
                    .frame(height: 6)
                    .animation(.bojiSnappy, value: completed)
            }
        }
        .accessibilityLabel("已完成 \(completed) 组，共 \(total) 组")
    }
}

// MARK: - 组次表骨架

/// 组次表列宽：组号 28pt、完成列 60pt，其余给数值列。
enum BojiSetTable {
    static let numberColumn: CGFloat = 28
    static let completeColumn: CGFloat = 60
    static let rowMinHeight: CGFloat = 48
    static let rowSpacing: CGFloat = 8
}

/// 数值格：支持行内快调高亮态与原生数字翻牌过渡。
struct BojiSetNumberCell: View {
    let text: String
    var placeholder: String = "—"
    var isEditing: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text.isEmpty ? placeholder : text)
                .bojiFont(.setNumber)
                .contentTransition(.numericText())
                .foregroundStyle(text.isEmpty ? BojiColor.textTertiary : BojiColor.textPrimary)
                .frame(maxWidth: .infinity, minHeight: max(44, BojiSetTable.rowMinHeight - 8))
                .background(
                    isEditing ? BojiColor.timerAccent.opacity(0.14) : BojiColor.inputSurface,
                    in: RoundedRectangle(cornerRadius: BojiRadius.input, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: BojiRadius.input, style: .continuous)
                        .stroke(isEditing ? BojiColor.timerAccent : Color.clear, lineWidth: 1.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(BojiRowPressStyle())
        .accessibilityLabel(text.isEmpty ? placeholder : text)
    }
}

// MARK: - 磁吸滑动筛选胶囊 (MatchedGeometry Sliding Chip Row)

/// Native filters use a segmented picker when compact, and a menu for longer lists or large text.
struct BojiChipRow: View {
    let items: [String]
    @Binding var selection: String
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Group {
            if items.count <= 4, !typeSize.isAccessibilitySize {
                Picker("筛选", selection: $selection) { options }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("筛选")
            } else {
                // menu 分支的 AX label 是选中项而不是标题，必须显式给 identifier，
                // 否则 `app.buttons["筛选"]` 查不到这个弹出按钮。
                Picker("筛选", selection: $selection) { options }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("筛选")
            }
        }
        .frame(minHeight: 44).tint(ClubBrand.accent)
    }
    private var options: some View {
        ForEach(items, id: \.self) { Text($0).tag($0) }
    }
}

#if DEBUG
// MARK: - 布局组件模式库 (LAYOUT_PATTERN_LIBRARY.md 落地)

/// Pattern 1: Asymmetric Hero Banner (非对称视觉主图卡)
struct BojiHeroBanner<Background: View, Action: View>: View {
    let title: String
    let subtitle: String
    var badge: String? = nil
    var aspectRatio: CGFloat = 2.1
    @ViewBuilder let background: () -> Background
    @ViewBuilder let action: () -> Action

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            background()
                .aspectRatio(aspectRatio, contentMode: .fill)
                .clipped()
            LinearGradient(
                colors: [.clear, .black.opacity(0.18), .black.opacity(0.72)],
                startPoint: .center,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 12) {
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .padding(.horizontal, BojiSpace.tightRow)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                }
                action()
            }
            .padding(BojiSpace.cardInset)
        }
        .clipShape(RoundedRectangle(cornerRadius: BojiRadius.cover, style: .continuous))
    }
}

/// Pattern 3: Compact Metric Band (紧凑型关键指标带)
struct BojiMetricItem: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let unit: String
    var note: String? = nil
}

struct BojiMetricBand: View {
    let items: [BojiMetricItem]
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .bojiFont(.label)
                        .foregroundStyle(BojiColor.textSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(item.value)
                            .bojiFont(.setNumber, monospacedDigits: true)
                            .foregroundStyle(BojiColor.textPrimary)
                        if !item.unit.isEmpty {
                            Text(item.unit)
                                .bojiFont(.label)
                                .foregroundStyle(BojiColor.textTertiary)
                        }
                    }
                    if let note = item.note {
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundStyle(BojiColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if index < items.count - 1 {
                    Divider()
                        .frame(height: 24)
                        .padding(.horizontal, BojiSpace.tight)
                        .overlay(BojiColor.divider)
                }
            }
        }
        .padding(.horizontal, BojiSpace.cardInset)
        .padding(.vertical, BojiSpace.general)
        .bojiCard()
    }
}

/// Pattern 4: Bento Dual-Column Metric Grid (便当双列数据网格)
struct BojiBentoDualGrid<Left: View, Right: View>: View {
    @ViewBuilder let left: () -> Left
    @ViewBuilder let right: () -> Right
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    left()
                    right()
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    left()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    right()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Pattern 5: Unified Container Compact List (单容器紧凑列表)
struct BojiUnifiedContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .bojiCard(padding: 0)
    }
}

/// Pattern 6: Progressive Disclosure Section (渐进式折叠面板)
struct BojiProgressiveDisclosure<Summary: View, Detail: View>: View {
    let title: String
    var isExpanded: Binding<Bool>? = nil
    @State private var internalExpanded = false
    @ViewBuilder let summary: () -> Summary
    @ViewBuilder let detail: () -> Detail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expanded: Binding<Bool> {
        isExpanded ?? $internalExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(BojiMotion.cardExpand(reduceMotion: reduceMotion)) {
                    expanded.wrappedValue.toggle()
                }
            } label: {
                HStack {
                    summary()
                    Spacer()
                    Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(BojiColor.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded.wrappedValue {
                Divider().overlay(BojiColor.divider)
                detail()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .bojiCard()
    }
}



#endif

/// Pair related content at normal sizes; keep every label and action readable at accessibility sizes.
struct BojiAdaptiveGroup<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var spacing: CGFloat = 12
    @ViewBuilder let content: () -> Content
    private var layout: AnyLayout {
        typeSize >= .xxxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .center, spacing: spacing))
    }
    var body: some View { layout { content() } }
}


