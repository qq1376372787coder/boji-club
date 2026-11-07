import SwiftUI
import CoreGraphics

/// One vector master for the App, Widget and exported artwork. Coordinates are
/// traced from the owner's supplied mark; the outer app-icon tile is not part of it.
enum BojiLogoGeometry {
    static let canvas = CGSize(width: 640, height: 680)
    enum Layer: CaseIterable { case stem, bowl, ribbon, cap }
    static func path(_ layer: Layer) -> CGPath {
        let p = CGMutablePath()
        switch layer {
        case .stem:
            p.move(to: CGPoint(x:381,y:735));p.addLine(to:CGPoint(x:381,y:531))
            p.addCurve(to:CGPoint(x:477,y:437),control1:CGPoint(x:381,y:479),control2:CGPoint(x:423,y:437))
            p.addCurve(to:CGPoint(x:531,y:458),control1:CGPoint(x:497,y:437),control2:CGPoint(x:517,y:444))
            p.addLine(to:CGPoint(x:531,y:813));p.addLine(to:CGPoint(x:381,y:813))
        case .bowl:
            p.move(to:CGPoint(x:706,y:547));p.addLine(to:CGPoint(x:823,y:603))
            p.addCurve(to:CGPoint(x:923,y:746),control1:CGPoint(x:886,y:638),control2:CGPoint(x:923,y:686))
            p.addCurve(to:CGPoint(x:737,y:915),control1:CGPoint(x:923,y:839),control2:CGPoint(x:845,y:915))
            p.addLine(to:CGPoint(x:475,y:915))
            p.addCurve(to:CGPoint(x:399,y:900),control1:CGPoint(x:446,y:915),control2:CGPoint(x:421,y:910))
            p.addLine(to:CGPoint(x:531,y:813));p.addLine(to:CGPoint(x:694,y:813))
            p.addCurve(to:CGPoint(x:775,y:746),control1:CGPoint(x:742,y:813),control2:CGPoint(x:775,y:788))
            p.addCurve(to:CGPoint(x:725,y:674),control1:CGPoint(x:775,y:716),control2:CGPoint(x:756,y:689))
            p.addLine(to:CGPoint(x:619,y:617))
        case .ribbon:
            p.move(to:CGPoint(x:391,y:735));p.addLine(to:CGPoint(x:706,y:547));p.addLine(to:CGPoint(x:855,y:615));p.addLine(to:CGPoint(x:399,y:900))
            p.addCurve(to:CGPoint(x:344,y:805),control1:CGPoint(x:358,y:878),control2:CGPoint(x:337,y:845))
            p.addCurve(to:CGPoint(x:391,y:735),control1:CGPoint(x:349,y:774),control2:CGPoint(x:365,y:752))
        case .cap:
            p.move(to:CGPoint(x:466,y:431))
            p.addCurve(to:CGPoint(x:430,y:316),control1:CGPoint(x:421,y:408),control2:CGPoint(x:407,y:359))
            p.addCurve(to:CGPoint(x:549,y:286),control1:CGPoint(x:452,y:275),control2:CGPoint(x:503,y:265))
            p.addLine(to:CGPoint(x:835,y:427))
            p.addCurve(to:CGPoint(x:887,y:547),control1:CGPoint(x:883,y:451),control2:CGPoint(x:904,y:498))
            p.addCurve(to:CGPoint(x:855,y:615),control1:CGPoint(x:881,y:570),control2:CGPoint(x:868,y:593))
        }
        p.closeSubpath()
        var transform = CGAffineTransform(translationX:-314,y:-260)
        return p.copy(using:&transform)!
    }
}

private struct BojiLogoLayer: Shape {
    let layer: BojiLogoGeometry.Layer
    func path(in rect: CGRect) -> Path {
        var transform = CGAffineTransform(scaleX:rect.width / BojiLogoGeometry.canvas.width,y:rect.height / BojiLogoGeometry.canvas.height)
        return Path(BojiLogoGeometry.path(layer).copy(using:&transform)!)
    }
}

enum BojiBrandStyle { case adaptive, monochrome, onDark }

struct BojiBrandMark: View {
    var size: CGFloat = 28
    var style: BojiBrandStyle = .adaptive
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var flat: Bool { size <= 24 || contrast == .increased || style != .adaptive }
    private var ink: Color { style == .onDark ? .white : .primary }
    private func color(_ layer:BojiLogoGeometry.Layer) -> Color {
        if flat { return ink }
        switch layer {
        case .stem: return scheme == .dark ? Color(red:0.55,green:0.59,blue:0.65) : Color(red:0.82,green:0.83,blue:0.85)
        case .bowl: return scheme == .dark ? Color(red:0.72,green:0.80,blue:0.90) : Color(red:0.72,green:0.79,blue:0.88)
        case .ribbon: return scheme == .dark ? Color(red:0.53,green:0.64,blue:0.79) : Color(red:0.53,green:0.61,blue:0.73)
        case .cap: return scheme == .dark ? Color(red:0.88,green:0.90,blue:0.94) : Color(red:0.31,green:0.33,blue:0.37)
        }
    }
    var body: some View {
        ZStack {
            ForEach(Array(BojiLogoGeometry.Layer.allCases.enumerated()),id:\.offset) { _,layer in
                BojiLogoLayer(layer:layer).fill(color(layer))
            }
        }
        .aspectRatio(BojiLogoGeometry.canvas.width / BojiLogoGeometry.canvas.height,contentMode:.fit)
        .frame(width:size,height:size)
        .accessibilityHidden(true)
    }
}

/// Decorative symbol is hidden from VoiceOver; the combined signature has one label.
struct BojiBrandSignature: View {
    var size: CGFloat = 24
    var style: BojiBrandStyle = .adaptive
    var title = "BOJI CLUB"
    var font: Font = .caption.weight(.semibold)
    var body: some View {
        HStack(spacing:8) {
            BojiBrandMark(size:size,style:style)
            Text(title).font(font).tracking(1.3)
                .foregroundStyle(style == .onDark ? Color.white : Color.primary)
        }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(title)
    }
}
