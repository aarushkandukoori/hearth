// The Hearth mark: the lantern from the app icon (docs/assets/brand/logo.svg), drawn in code so it stays
// sharp at any size. Used on the lock screen, the app-switcher shield, onboarding and About.

import SwiftUI

struct HearthLanternMark: View {
    /// Height in points. The width follows the lantern's shape.
    var height: CGFloat = 96
    /// A soft ember halo behind the lantern.
    var glows = true

    var body: some View {
        Canvas { context, size in
            let scale = size.height / Self.box.height
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -Self.box.minX, y: -Self.box.minY)
            Self.drawLantern(in: context, blur: 22 * scale)
        }
        .frame(width: height * Self.box.width / Self.box.height, height: height)
        .background {
            if glows {
                Circle()
                    .fill(RadialGradient(colors: [Self.ember.opacity(0.42), Self.ember.opacity(0.12), .clear],
                                         center: .center, startRadius: 0, endRadius: height * 0.8))
                    .frame(width: height * 1.6, height: height * 1.6)
                    .offset(y: height * 0.1)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Drawing (coordinates are the SVG's, inside `box`)

    private static let box = CGRect(x: 314, y: 141, width: 396, height: 677)
    private static let ember = Color(hex: "#FF8A4C")

    private static func drawLantern(in context: GraphicsContext, blur: CGFloat) {
        // Ring handle and the small knob under it.
        let ring = Path(ellipseIn: CGRect(x: 460, y: 170, width: 104, height: 104))
        context.stroke(ring, with: metal(ring.boundingRect), lineWidth: 26)
        let knob = Path(roundedRect: CGRect(x: 478, y: 266, width: 68, height: 40), cornerRadius: 12)
        context.fill(knob, with: metal(knob.boundingRect))

        // Roof.
        var roof = Path()
        roof.move(to: CGPoint(x: 432, y: 300))
        roof.addLine(to: CGPoint(x: 592, y: 300))
        roof.addLine(to: CGPoint(x: 680, y: 372))
        roof.addLine(to: CGPoint(x: 344, y: 372))
        roof.closeSubpath()
        context.fill(roof, with: metal(roof.boundingRect))
        context.stroke(roof, with: metal(roof.boundingRect), style: StrokeStyle(lineWidth: 22, lineJoin: .round))

        // Glowing glass in a gold frame, with a thin inner line and a highlight.
        let glass = Path(roundedRect: CGRect(x: 362, y: 372, width: 300, height: 368), cornerRadius: 58)
        context.fill(glass, with: .radialGradient(
            Gradient(stops: [.init(color: Color(hex: "#FFB863"), location: 0),
                             .init(color: Color(hex: "#FF8A4C"), location: 0.55),
                             .init(color: Color(hex: "#D2522A"), location: 1)]),
            center: CGPoint(x: 512, y: 610), startRadius: 0, endRadius: 260))
        context.stroke(glass, with: metal(glass.boundingRect), lineWidth: 22)
        let inner = Path(roundedRect: CGRect(x: 378, y: 388, width: 268, height: 336), cornerRadius: 44)
        context.stroke(inner, with: .color(Color(hex: "#B9471F").opacity(0.35)), lineWidth: 6)
        let shine = Path(roundedRect: CGRect(x: 394, y: 414, width: 22, height: 280), cornerRadius: 11)
        context.fill(shine, with: .color(.white.opacity(0.24)))

        // The flame: a soft glow, the flame itself, then its white-hot core.
        let flame = flamePath()
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: blur))
            layer.fill(flame, with: .color(Color(hex: "#FFE6B0").opacity(0.85)))
        }
        context.fill(flame, with: .radialGradient(
            Gradient(stops: [.init(color: .white, location: 0),
                             .init(color: Color(hex: "#FFF1CF"), location: 0.5),
                             .init(color: Color(hex: "#FFE29A"), location: 1)]),
            center: CGPoint(x: 510, y: 650), startRadius: 0, endRadius: 170))
        context.fill(corePath(), with: .color(.white.opacity(0.9)))

        // Base.
        let base = Path(roundedRect: CGRect(x: 330, y: 732, width: 364, height: 70), cornerRadius: 26)
        context.fill(base, with: .linearGradient(
            Gradient(colors: [Color(hex: "#EDB565"), Color(hex: "#B06A28")]),
            startPoint: CGPoint(x: base.boundingRect.midX, y: base.boundingRect.minY),
            endPoint: CGPoint(x: base.boundingRect.midX, y: base.boundingRect.maxY)))
    }

    /// Lantern gold, light at the top of each part and deeper at the bottom.
    private static func metal(_ rect: CGRect) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [Color(hex: "#F7C77A"), Color(hex: "#C7802F")]),
                        startPoint: CGPoint(x: rect.midX, y: rect.minY),
                        endPoint: CGPoint(x: rect.midX, y: rect.maxY))
    }

    private static func flamePath() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 522, y: 440))
        path.addCurve(to: CGPoint(x: 592, y: 612), control1: CGPoint(x: 528, y: 492), control2: CGPoint(x: 592, y: 540))
        path.addCurve(to: CGPoint(x: 512, y: 696), control1: CGPoint(x: 592, y: 660), control2: CGPoint(x: 556, y: 696))
        path.addCurve(to: CGPoint(x: 432, y: 612), control1: CGPoint(x: 468, y: 696), control2: CGPoint(x: 432, y: 660))
        path.addCurve(to: CGPoint(x: 522, y: 440), control1: CGPoint(x: 432, y: 552), control2: CGPoint(x: 486, y: 520))
        path.closeSubpath()
        return path
    }

    private static func corePath() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 516, y: 566))
        path.addCurve(to: CGPoint(x: 552, y: 646), control1: CGPoint(x: 520, y: 596), control2: CGPoint(x: 552, y: 616))
        path.addCurve(to: CGPoint(x: 512, y: 684), control1: CGPoint(x: 552, y: 670), control2: CGPoint(x: 534, y: 684))
        path.addCurve(to: CGPoint(x: 472, y: 646), control1: CGPoint(x: 490, y: 684), control2: CGPoint(x: 472, y: 670))
        path.addCurve(to: CGPoint(x: 516, y: 566), control1: CGPoint(x: 472, y: 616), control2: CGPoint(x: 504, y: 600))
        path.closeSubpath()
        return path
    }
}

/// The app icon as a tile: the lantern on a deep charcoal-brown background with an ember halo.
struct HearthAppIconTile: View {
    var size: CGFloat = 96

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        ZStack {
            RadialGradient(stops: [.init(color: Color(hex: "#3A2518"), location: 0),
                                   .init(color: Color(hex: "#1F1611"), location: 0.45),
                                   .init(color: Color(hex: "#110D0B"), location: 1)],
                           center: UnitPoint(x: 0.5, y: 0.49), startRadius: 0, endRadius: size * 0.74)
            HearthLanternMark(height: size * 0.7)
                .offset(y: size * 0.02)
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: Color(hex: "#FF8A4C").opacity(0.22), radius: size * 0.16, y: size * 0.05)
        .accessibilityHidden(true)
    }
}
