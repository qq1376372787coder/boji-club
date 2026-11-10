#if DEBUG
import SwiftUI

// 训练预览与计划详情（任务书 4.2）：封面 2.1:1＋单容器动作列表＋底部开始按钮。
// 开始操作用明确的点击按钮，不做滑动手势门槛。

struct TrainingPreviewView: View {
    let title: String
    let focus: String
    let exercises: [Exercise]
    let date: Date
    @Environment(\.dynamicTypeSize) private var typeSize
    var startTitle: String = "开始训练"
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: BojiSpace.sectionSpacing) {
                    cover
                    exerciseList
                    purposeSection
                }
                .padding(BojiSpace.pageInset)
                .frame(maxWidth: BojiSize.contentWidth)
                .frame(maxWidth: .infinity)
            }
            startDock
        }
        .background(BojiColor.pageBackground.ignoresSafeArea())
    }

    /// 封面约 2.1:1：名称、训练方向、动作数量。
    @ViewBuilder private var cover: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).bojiFont(.pageTitle)
                Text("\(focus) · \(exercises.count) 个动作").bojiFont(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(BojiSpace.cardInset)
                .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.card))
        } else { ZStack(alignment: .bottomLeading) {
            BojiCoverGraphic(title: "")
                .aspectRatio(2.1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .bojiFont(.pageTitle)
                    .foregroundStyle(BojiColor.textPrimary)
                Text("\(focus) · \(exercises.count) 个动作")
                    .bojiFont(.label)
                    .foregroundStyle(BojiColor.textSecondary)
            }
            .padding(BojiSpace.showcase)
        }
        .clipShape(RoundedRectangle(cornerRadius: BojiRadius.cover, style: .continuous))
        }
    }

    /// 单容器分行，不为每行再套大卡片。
    private var exerciseList: some View {
        VStack(spacing: 0) {
            ForEach(Array(exercises.enumerated()), id: \.element.id) { index, exercise in
                BojiAdaptiveGroup(spacing: BojiSpace.general) {
                    BojiExerciseThumb(exercise: exercise, side: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(exercise.displayName)
                            .bojiFont(.exerciseName)
                            .foregroundStyle(BojiColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(exercise.muscle + (exercise.equipment.map { " · " + $0 } ?? ""))
                            .bojiFont(.secondary)
                            .foregroundStyle(BojiColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text("\(exercise.sets.count) 组")
                        .bojiFont(.label, monospacedDigits: true)
                        .foregroundStyle(BojiColor.textSecondary)
                }
                .padding(.horizontal, BojiSpace.cardInset)
                .frame(minHeight: 80)
                if index < exercises.count - 1 {
                    Divider().overlay(BojiColor.divider).padding(.leading, BojiSpace.cardInset + 56 + BojiSpace.general)
                }
            }
        }
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
        .shadow(color: .black.opacity(0.035), radius: 18, x: 0, y: 5)
    }

    /// 训练目的、制定依据进入独立展开区。
    @ViewBuilder private var purposeSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: BojiSpace.tightRow) {
                Text("组间休息与重量目标在进入训练后逐组登记；计划目标与实际完成数据分别保存。")
                    .bojiFont(.secondary)
                    .foregroundStyle(BojiColor.textSecondary)
            }
            .padding(.top, BojiSpace.tightRow)
        } label: {
            Text("训练目的与制定依据")
                .bojiFont(.body)
                .foregroundStyle(BojiColor.textPrimary)
        }
        .padding(BojiSpace.cardInset)
        .background(BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
        .tint(ClubBrand.accent)
    }

    /// 开始操作固定在底部安全区域，明确点击。
    private var startDock: some View {
        VStack(spacing: 8) {
            Button(startTitle, action: onStart)
                .buttonStyle(BojiButtonStyle(kind: .primary))
            Text(ClubDates.isFuture(date) ? "未来日期先保存安排，到当天再开始。" : "开始后自动记录用时；完成一组登记一组。")
                .bojiFont(.label)
                .foregroundStyle(BojiColor.textSecondary)
        }
        .padding(.horizontal, BojiSpace.pageInset)
        .padding(.top, BojiSpace.general)
        .padding(.bottom, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(BojiColor.divider).frame(height: 1) }
    }
}

#endif
