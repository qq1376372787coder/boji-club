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
        VStack(alignment: .leading, spacing: 14) {
            if BojiCopy130.isStep(eyebrow) {
            Text(eyebrow).font(.system(size: eyebrowSize, weight: .semibold, design: .monospaced))
                .tracking(2.5).foregroundStyle(ClubBrand.accent)
            }
            Text(title).font(.system(size: titleSize, weight: BojiFontRole.pageTitle.weight)).tracking(-1)
                .foregroundStyle(FlowPalette.ink).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FlowSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) { content }
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
        VStack(spacing: 10) { content }
            .padding(BojiSpace.general).frame(maxWidth: ClubUI.contentWidth)
            .clubGlassEffect(in: RoundedRectangle(cornerRadius: BojiRadius.card, style: .continuous))
            .padding(.horizontal, ClubUI.pageInset).padding(.vertical, 8)
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
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 21, weight: .light))
                    .frame(width: 44, height: 44)
                    .background(selected ? .white.opacity(0.12) : FlowPalette.secondaryInk.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.footnote).opacity(selected ? 1 : 0.68).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3).opacity(selected ? 1 : 0.25)
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
            HStack(spacing: 8) { choices }
            VStack(spacing: 8) { choices }
        }
    }
    private var choices: some View {
        ForEach(values, id: \.self) { value in
            Button { selection = value } label: {
                Text(value).font(.subheadline.weight(.medium)).padding(.vertical, 13).frame(maxWidth: .infinity)
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
            .font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
