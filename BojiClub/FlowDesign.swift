import SwiftUI

enum FlowPalette {
    static let paper = ClubUI.page
    static let ink = BojiColor.textPrimary
    static let secondaryInk = BojiColor.textSecondary
    static let silver = BojiColor.textTertiary
}

struct FlowBackground: View {
    var body: some View {
        ClubBackground()
    }
}

struct FlowHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = BojiFontRole.pageTitle.size
    @ScaledMetric(relativeTo: .caption) private var eyebrowSize: CGFloat = 11
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.rowGap) {
            // D3 修复：eyebrow 恒显示；拉丁文 mono eyebrow，中文 label。
            if BojiScript.containsCJK(eyebrow) {
                Text(eyebrow).bojiType(.label).foregroundStyle(ClubBrand.accent)
            } else {
                Text(eyebrow).bojiType(.eyebrow).foregroundStyle(ClubBrand.accent)
            }
            Text(title).bojiType(.title).foregroundStyle(FlowPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle).bojiType(.secondary).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FlowSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: BojiLayout.cardInset) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(ClubUI.cardInset)
            .bojiElevated(cornerRadius: ClubUI.cardRadius)
    }
}

struct FlowButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ClubActionButtonStyle(kind: .primary).makeBody(configuration: configuration)
    }
}

struct FlowDock<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: BojiLayout.inline) { content }
            .padding(BojiSpace.general).frame(maxWidth: ClubUI.contentWidth)
            .clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
            .padding(.horizontal, ClubUI.pageInset).padding(.vertical, BojiLayout.inline)
            .frame(maxWidth: .infinity)
    }
}

struct FlowChoice: View {
    let title: String
    let detail: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: BojiLayout.cardInset) {
                Image(systemName: symbol).bojiType(.section)
                    .frame(width: 44, height: 44)
                    .background(selected ? ClubBrand.onAccent.opacity(0.14) : FlowPalette.secondaryInk.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: BojiLayout.tight) {
                    Text(title).bojiType(.body)
                    Text(detail).bojiType(.label).opacity(selected ? 1 : 0.68).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").bojiType(.section).opacity(selected ? 1 : 0.25)
            }.padding(ClubUI.cardInset).frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(selected ? ClubBrand.onAccent : FlowPalette.ink)
                .background(selected ? ClubBrand.accent : BojiColor.cardSurface, in: RoundedRectangle(cornerRadius: ClubUI.cardRadius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: ClubUI.cardRadius, style: .continuous).stroke(BojiColor.outline, lineWidth: 0.5).allowsHitTesting(false) }
        }.buttonStyle(ClubMotionButton()).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct FlowChips: View {
    let values: [String]
    @Binding var selection: String
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: BojiLayout.inline) { choices }
            VStack(spacing: BojiLayout.inline) { choices }
        }
    }
    private var choices: some View {
        ForEach(values, id: \.self) { value in
            Button { selection = value } label: {
                Text(value).bojiType(.secondary).padding(.vertical, BojiLayout.rowGap).frame(maxWidth: .infinity)
                    .foregroundStyle(selection == value ? ClubBrand.onAccent : FlowPalette.ink)
                    .background(selection == value ? ClubBrand.accent : BojiColor.cardSurface, in: Capsule())
                    .overlay { Capsule().stroke(BojiColor.outline, lineWidth: 0.5).allowsHitTesting(false) }
            }.buttonStyle(ClubMotionButton()).accessibilityAddTraits(selection == value ? .isSelected : [])
        }
    }
}

struct FlowError: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .bojiType(.label).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
