// The illustrated Lantern Bay map, drawn in a Canvas: sea, coast, hills, roads, little houses, trees and
// boats, in four time-of-day palettes. Same layout and colors as the website's map (docs/app/js/world/map.js).

import SwiftUI

/// Colors for one part of the day. Afternoon is the default; the other parts change a few of them.
struct TownMapPalette {
    var sea1 = Color(hex: "#8DD0E0"), sea2 = Color(hex: "#3D8BB0"), pool = Color(hex: "#7BC6D6")
    var foam = rgba(255, 255, 255, 0.62)
    var land1 = Color(hex: "#9CC77E"), land2 = Color(hex: "#BCD898"), hill = Color(hex: "#84B467")
    var contour = rgba(36, 70, 30, 0.2)
    var sand = Color(hex: "#EEDDB3"), road = Color(hex: "#F6EBCF"), roadEdge = rgba(120, 92, 56, 0.32)
    var wood = Color(hex: "#8F6845"), ferry = rgba(255, 255, 255, 0.85)
    var plaza = Color(hex: "#EADBB8"), plazaEdge = rgba(120, 92, 56, 0.35), plazaDot = rgba(120, 92, 56, 0.22)
    /// Warm light around each place after dark (0 = none).
    var glow = rgba(255, 196, 108, 0.95), glowOpacity = 0.0
    /// Sun or moon on the water.
    var shine = rgba(255, 255, 236, 0.7), shineOpacity = 0.5
    var leaf = Color(hex: "#4F8D45"), leaf2 = Color(hex: "#74B05C"), trunk = Color(hex: "#7A5638")
    var roof = Color(hex: "#C8644A"), wall = Color(hex: "#F5E9D4"), window = Color(hex: "#7896A8"), door = Color(hex: "#8C5A3C")
    var sail = Color(hex: "#FFFDF6"), sail2 = Color(hex: "#F6C177"), hull = Color(hex: "#B4553F")
    var wave = rgba(255, 255, 255, 0.75), rock = Color(hex: "#A39A8E"), rockHi = rgba(255, 255, 255, 0.4)
    /// Street lamps and windows glow in the evening and at night.
    var lampsLit = false, lamp = Color(hex: "#FFD27A"), lampGlow = rgba(255, 196, 108, 0.55)
    /// Ring around the little avatars on the map.
    var ring = Color.white

    static func forPart(_ part: DayPart) -> TownMapPalette {
        var p = TownMapPalette()
        switch part {
        case .afternoon:
            break
        case .morning:
            p.sea1 = Color(hex: "#B4E0E8"); p.sea2 = Color(hex: "#5CA6C2"); p.pool = Color(hex: "#8FD0DD")
            p.land1 = Color(hex: "#A6CB88"); p.land2 = Color(hex: "#C6DFA6"); p.hill = Color(hex: "#8DBA70")
            p.sand = Color(hex: "#F3E4BE"); p.road = Color(hex: "#F9F0DA")
            p.shine = rgba(255, 236, 196, 0.85); p.shineOpacity = 0.7
            p.leaf = Color(hex: "#568F49"); p.leaf2 = Color(hex: "#7DB663"); p.window = Color(hex: "#8AA7B6")
        case .evening:
            p.sea1 = Color(hex: "#6F9EBF"); p.sea2 = Color(hex: "#2C4A74"); p.pool = Color(hex: "#5E8FB0")
            p.foam = rgba(255, 228, 196, 0.45)
            p.land1 = Color(hex: "#879D69"); p.land2 = Color(hex: "#A7AE79"); p.hill = Color(hex: "#6C8753")
            p.contour = rgba(40, 40, 20, 0.2); p.sand = Color(hex: "#E4C590"); p.road = Color(hex: "#EED7AA")
            p.plaza = Color(hex: "#DCC495"); p.glowOpacity = 0.62
            p.shine = rgba(255, 168, 92, 0.75); p.shineOpacity = 0.9
            p.leaf = Color(hex: "#46703C"); p.leaf2 = Color(hex: "#5E8A4B")
            p.roof = Color(hex: "#B4523F"); p.wall = Color(hex: "#EBD6B8"); p.window = Color(hex: "#FFC867"); p.door = Color(hex: "#6E4430")
            p.sail = Color(hex: "#FBE7D0"); p.hull = Color(hex: "#9C4636"); p.wave = rgba(255, 236, 214, 0.6); p.rock = Color(hex: "#8D8073")
            p.lampsLit = true; p.lamp = Color(hex: "#FFD27A"); p.lampGlow = rgba(255, 196, 108, 0.55)
            p.ring = Color(hex: "#FFE6C2")
        case .night:
            p.sea1 = Color(hex: "#223B5E"); p.sea2 = Color(hex: "#0D1A33"); p.pool = Color(hex: "#2D5276")
            p.foam = rgba(170, 200, 240, 0.18)
            p.land1 = Color(hex: "#2B3E34"); p.land2 = Color(hex: "#34493B"); p.hill = Color(hex: "#23372C")
            p.contour = rgba(170, 210, 180, 0.08); p.sand = Color(hex: "#5F5847"); p.road = Color(hex: "#545040")
            p.roadEdge = rgba(0, 0, 0, 0.35); p.wood = Color(hex: "#4D3A27"); p.ferry = rgba(246, 193, 119, 0.6)
            p.plaza = Color(hex: "#4E4A3C"); p.plazaEdge = rgba(0, 0, 0, 0.35); p.plazaDot = rgba(255, 220, 160, 0.12)
            p.glowOpacity = 1; p.shine = rgba(214, 226, 255, 0.45); p.shineOpacity = 0.8
            p.leaf = Color(hex: "#1D3124"); p.leaf2 = Color(hex: "#2A4533"); p.trunk = Color(hex: "#3B2B1E")
            p.roof = Color(hex: "#4F2F2A"); p.wall = Color(hex: "#5F574D"); p.window = Color(hex: "#FFD27A"); p.door = Color(hex: "#2F241C")
            p.sail = Color(hex: "#C7CDD9"); p.sail2 = Color(hex: "#A88A5A"); p.hull = Color(hex: "#5A2E26")
            p.wave = rgba(180, 200, 240, 0.3); p.rock = Color(hex: "#403D3A"); p.rockHi = rgba(255, 255, 255, 0.12)
            p.lampsLit = true; p.lamp = Color(hex: "#FFD98A"); p.lampGlow = rgba(255, 200, 110, 0.7)
            p.ring = Color(hex: "#F6C177")
        }
        return p
    }
}

/// CSS-style rgba(255, 196, 108, 0.95).
private func rgba(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) -> Color {
    Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: alpha)
}

/// The drawn terrain and decorations (no pins). Redraws only when the palette or size changes.
struct TownMapTerrain: View {
    let palette: TownMapPalette
    /// Normalized place positions, for the warm glow around each place after dark.
    let places: [MapPoint]

    var body: some View {
        Canvas { context, size in
            TownMapArt.draw(in: &context, size: size, palette: palette, places: places)
        }
        .accessibilityHidden(true)
    }
}

enum TownMapArt {
    /// Places sit inside an inset frame so pins near the edges keep their labels on the map.
    static let insetX = 0.08
    static let insetY = 0.09
    /// The map width the decoration sizes were tuned for (a phone map with 16 pt margins).
    static let referenceWidth: CGFloat = 361

    /// A normalized map position (0...1, may run past the edges) in view coordinates.
    static func point(_ u: Double, _ v: Double, in size: CGSize) -> CGPoint {
        CGPoint(x: (insetX + u * (1 - 2 * insetX)) * size.width, y: (insetY + v * (1 - 2 * insetY)) * size.height)
    }

    // MARK: Terrain, in the same 0...1 space as the places

    static let coast: [(Double, Double)] = [
        (-0.2, -0.2), (1.2, -0.2), (1.2, 0.5), (1.06, 0.55), (0.98, 0.6), (0.93, 0.64), (0.96, 0.71), (0.93, 0.79),
        (0.86, 0.82), (0.8, 0.78), (0.76, 0.71), (0.68, 0.72), (0.62, 0.77), (0.56, 0.79), (0.46, 0.79), (0.4, 0.75),
        (0.32, 0.74), (0.25, 0.72), (0.19, 0.7), (0.12, 0.7), (0.07, 0.66), (0.05, 0.59), (0.06, 0.52), (0.02, 0.47),
        (-0.2, 0.45),
    ]
    static let hills: [[(Double, Double)]] = [
        [(0.0, 0.06), (0.14, -0.03), (0.34, -0.02), (0.45, 0.12), (0.42, 0.3), (0.26, 0.37), (0.08, 0.33), (-0.03, 0.2)],
        [(0.5, -0.06), (0.72, -0.12), (0.95, -0.06), (1.08, 0.08), (1.02, 0.24), (0.84, 0.27), (0.64, 0.24), (0.52, 0.12)],
    ]
    static let roads: [[(Double, Double)]] = [
        [(0.52, 0.8), (0.51, 0.7), (0.5, 0.6), (0.51, 0.5), (0.52, 0.4)],                 // Main Street, harbor to the square
        [(0.52, 0.4), (0.42, 0.34), (0.32, 0.3), (0.24, 0.22)],                           // up to the greenhouse
        [(0.52, 0.4), (0.58, 0.3), (0.64, 0.2), (0.72, 0.1)],                             // the hill path to the observatory
        [(0.52, 0.4), (0.64, 0.4), (0.74, 0.37), (0.82, 0.36)],                           // to the arcade
        [(0.15, 0.58), (0.26, 0.64), (0.4, 0.62), (0.5, 0.64)],                           // the boardwalk
        [(0.51, 0.6), (0.62, 0.6), (0.72, 0.64), (0.8, 0.68), (0.86, 0.72)],              // the coast road to the lighthouse
    ]
    static let ferry: [(Double, Double)] = [(0.53, 0.95), (0.68, 1.0), (0.86, 1.04), (1.04, 1.06)]

    enum Decoration {
        case plaza, pine, round, house, boat, wave, rock, island, compass, lamp

        /// Size in points on a 361 pt wide map.
        var size: CGSize {
            switch self {
            case .plaza: return CGSize(width: 59, height: 59)
            case .pine: return CGSize(width: 14.4, height: 19.2)
            case .round: return CGSize(width: 16, height: 17.6)
            case .house: return CGSize(width: 17.6, height: 16)
            case .boat: return CGSize(width: 19.2, height: 16)
            case .wave: return CGSize(width: 20.8, height: 6.4)
            case .rock: return CGSize(width: 16, height: 10.4)
            case .island: return CGSize(width: 51, height: 27)
            case .compass: return CGSize(width: 30, height: 30)
            case .lamp: return CGSize(width: 5, height: 5)
            }
        }

        /// The drawing's own coordinate box (the SVG viewBox on the website).
        var box: CGSize {
            switch self {
            case .plaza, .lamp: return size
            case .pine: return CGSize(width: 20, height: 26)
            case .round: return CGSize(width: 22, height: 24)
            case .house: return CGSize(width: 24, height: 22)
            case .boat: return CGSize(width: 26, height: 22)
            case .wave: return CGSize(width: 28, height: 8)
            case .rock: return CGSize(width: 22, height: 14)
            case .island: return CGSize(width: 64, height: 34)
            case .compass: return CGSize(width: 40, height: 40)
            }
        }
    }

    static let decorations: [(Decoration, Double, Double)] = [
        (.plaza, 0.52, 0.4),
        (.pine, 0.05, 0.1), (.pine, 0.16, 0.05), (.pine, 0.1, 0.3), (.round, 0.35, 0.05), (.pine, 0.41, 0.25),
        (.round, 0.57, 0.04), (.pine, 0.88, 0.12), (.pine, 0.95, 0.25), (.round, 0.62, 0.2), (.round, 0.02, 0.38),
        (.round, 0.94, 0.46), (.pine, 0.3, 0.16),
        (.house, 0.33, 0.43), (.house, 0.42, 0.48), (.house, 0.6, 0.5), (.house, 0.68, 0.53), (.house, 0.27, 0.5),
        (.house, 0.75, 0.47), (.house, 0.62, 0.68),
        (.lamp, 0.505, 0.71), (.lamp, 0.5, 0.54), (.lamp, 0.3, 0.635), (.lamp, 0.67, 0.6), (.lamp, 0.66, 0.4), (.lamp, 0.38, 0.33),
        (.boat, 0.66, 0.9), (.boat, 0.36, 0.92), (.wave, 0.12, 0.84), (.wave, 0.24, 0.98), (.wave, 0.78, 0.99),
        (.wave, 1.03, 0.65), (.wave, 0.99, 0.92), (.wave, 0.01, 0.78),
        (.rock, 0.03, 0.69), (.rock, 0.1, 0.76), (.rock, 0.97, 0.8), (.rock, 0.91, 0.86),
        (.island, 1.03, 1.06), (.compass, -0.02, 0.98),
    ]

    // MARK: Drawing

    static func draw(in context: inout GraphicsContext, size: CGSize, palette p: TownMapPalette, places: [MapPoint]) {
        let k = size.width / referenceWidth
        let full = CGRect(origin: .zero, size: size)
        func at(_ points: [(Double, Double)]) -> [CGPoint] { points.map { point($0.0, $0.1, in: size) } }

        // Sea, the sun (or moon) on the water, and two little tide pools.
        context.fill(Path(full), with: .linearGradient(Gradient(colors: [p.sea1, p.sea2]),
                                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        var shine = context
        shine.opacity = p.shineOpacity
        fillEllipseGlow(&shine, center: CGPoint(x: size.width * 0.74, y: size.height * 0.95),
                        radii: CGSize(width: size.width * 0.34, height: size.height * 0.11), color: p.shine)
        for (u, v, rx, ry) in [(0.035, 0.62, 0.014, 0.011), (0.085, 0.715, 0.011, 0.009)] {
            let c = point(u, v, in: size)
            context.fill(Path(ellipseIn: CGRect(x: c.x - rx * size.width, y: c.y - ry * size.height,
                                                width: 2 * rx * size.width, height: 2 * ry * size.height)), with: .color(p.pool))
        }

        // Coast: white foam, a sandy beach, then the land.
        let land = smooth(at(coast), closed: true)
        let round = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
        context.stroke(land, with: .color(p.foam), style: widened(round, 18 * k))
        context.stroke(land, with: .color(p.sand), style: widened(round, 11 * k))
        let landBox = land.boundingRect
        context.fill(land, with: .linearGradient(Gradient(colors: [p.land1, p.land2]),
                                                 startPoint: CGPoint(x: landBox.midX, y: landBox.minY),
                                                 endPoint: CGPoint(x: landBox.midX, y: landBox.maxY)))

        // Hills with two contour lines each.
        for hill in hills {
            context.fill(smooth(at(hill), closed: true), with: .color(p.hill))
            for factor in [0.68, 0.38] {
                context.stroke(smooth(at(shrink(hill, factor)), closed: true), with: .color(p.contour), lineWidth: 1.2 * k)
            }
        }

        // Roads, the pier and the dotted ferry route.
        let roadPaths = roads.map { smooth(at($0), closed: false) }
        for road in roadPaths { context.stroke(road, with: .color(p.roadEdge), style: widened(round, 9 * k)) }
        for road in roadPaths { context.stroke(road, with: .color(p.road), style: widened(round, 6 * k)) }
        var pier = Path()
        pier.move(to: point(0.52, 0.77, in: size))
        pier.addLine(to: point(0.52, 0.94, in: size))
        context.stroke(pier, with: .color(p.wood), lineWidth: 8 * k)
        context.stroke(smooth(at(ferry), closed: false), with: .color(p.ferry),
                       style: StrokeStyle(lineWidth: 2 * k, lineCap: .round, dash: [3 * k, 6 * k]))

        // Warm light around each place after dark.
        if p.glowOpacity > 0 {
            var glow = context
            glow.opacity = p.glowOpacity
            for place in places {
                fillEllipseGlow(&glow, center: point(place.x, place.y, in: size),
                                radii: CGSize(width: size.width * 0.09, height: size.height * 0.09), color: p.glow)
            }
        }

        for (kind, u, v) in decorations {
            drawDecoration(kind, at: point(u, v, in: size), scale: k, in: context, palette: p)
        }
    }

    /// Catmull-Rom curve through the points (the website uses the same curve).
    static func smooth(_ points: [CGPoint], closed: Bool) -> Path {
        var path = Path()
        let n = points.count
        guard n > 1 else { return path }
        func at(_ i: Int) -> CGPoint { closed ? points[((i % n) + n) % n] : points[min(max(i, 0), n - 1)] }
        path.move(to: points[0])
        for i in 0..<(closed ? n : n - 1) {
            let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        if closed { path.closeSubpath() }
        return path
    }

    /// The same outline pulled toward its middle (contour lines on the hills).
    static func shrink(_ points: [(Double, Double)], _ factor: Double) -> [(Double, Double)] {
        let cu = points.map(\.0).reduce(0, +) / Double(points.count)
        let cv = points.map(\.1).reduce(0, +) / Double(points.count)
        return points.map { (cu + ($0.0 - cu) * factor, cv + ($0.1 - cv) * factor) }
    }

    private static func widened(_ style: StrokeStyle, _ width: CGFloat) -> StrokeStyle {
        var copy = style
        copy.lineWidth = width
        return copy
    }

    /// A soft elliptical glow that fades to nothing at its edge.
    private static func fillEllipseGlow(_ context: inout GraphicsContext, center: CGPoint, radii: CGSize, color: Color) {
        guard radii.width > 0, radii.height > 0 else { return }
        var squashed = context
        squashed.translateBy(x: center.x, y: center.y)
        squashed.scaleBy(x: 1, y: radii.height / radii.width)
        let r = radii.width
        squashed.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)),
                      with: .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: .zero, startRadius: 0, endRadius: r))
    }

    // MARK: Little drawings

    private static func drawDecoration(_ kind: Decoration, at center: CGPoint, scale k: CGFloat,
                                       in context: GraphicsContext, palette p: TownMapPalette) {
        let size = CGSize(width: kind.size.width * k, height: kind.size.height * k)
        switch kind {
        case .plaza:
            drawPlaza(center: center, diameter: size.width, in: context, palette: p)
            return
        case .lamp:
            guard p.lampsLit else { return }
            var lit = context
            lit.addFilter(.shadow(color: p.lampGlow, radius: 5 * k))
            lit.fill(Path(ellipseIn: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                            width: size.width, height: size.height)), with: .color(p.lamp))
            return
        default:
            break
        }

        // Everything else is drawn in its own small coordinate box, then scaled into place.
        var ctx = context
        ctx.translateBy(x: center.x - size.width / 2, y: center.y - size.height / 2)
        ctx.scaleBy(x: size.width / kind.box.width, y: size.height / kind.box.height)
        switch kind {
        case .pine:
            ctx.fill(polygon([(10, 1), (17, 12), (13.5, 12), (18.5, 20), (1.5, 20), (6.5, 12), (3, 12)]), with: .color(p.leaf))
            ctx.fill(Path(roundedRect: CGRect(x: 8.6, y: 20, width: 2.8, height: 5), cornerRadius: 1), with: .color(p.trunk))
        case .round:
            ctx.fill(Path(ellipseIn: CGRect(x: 2.5, y: 1, width: 17, height: 17)), with: .color(p.leaf))
            ctx.fill(Path(ellipseIn: CGRect(x: 4.6, y: 3.6, width: 6.8, height: 6.8)), with: .color(p.leaf2))
            ctx.fill(Path(roundedRect: CGRect(x: 9.6, y: 16, width: 2.8, height: 7), cornerRadius: 1), with: .color(p.trunk))
        case .house:
            if p.lampsLit { ctx.addFilter(.shadow(color: rgba(255, 196, 108, 0.45), radius: 4)) }
            ctx.fill(polygon([(1.5, 10.5), (12, 2.2), (22.5, 10.5)]), with: .color(p.roof))
            ctx.fill(Path(roundedRect: CGRect(x: 4.2, y: 10, width: 15.6, height: 10.8), cornerRadius: 1), with: .color(p.wall))
            ctx.fill(Path(roundedRect: CGRect(x: 7, y: 12.6, width: 3.8, height: 3.8), cornerRadius: 0.6), with: .color(p.window))
            ctx.fill(Path(roundedRect: CGRect(x: 13.4, y: 13.6, width: 3.6, height: 7.2), cornerRadius: 0.6), with: .color(p.door))
        case .boat:
            ctx.fill(polygon([(12.6, 1.5), (12.6, 15), (4.5, 15)]), with: .color(p.sail))
            ctx.fill(polygon([(14.2, 4.5), (14.2, 15), (20.7, 15)]), with: .color(p.sail2))
            ctx.fill(polygon([(1.5, 16), (24.5, 16), (20.9, 20.6), (5.1, 20.6)]), with: .color(p.hull))
        case .wave:
            var wave = Path()
            wave.move(to: CGPoint(x: 1, y: 5.5))
            wave.addCurve(to: CGPoint(x: 10, y: 5.5), control1: CGPoint(x: 4, y: 1.5), control2: CGPoint(x: 7, y: 1.5))
            wave.addCurve(to: CGPoint(x: 19, y: 5.5), control1: CGPoint(x: 13, y: 9.5), control2: CGPoint(x: 16, y: 9.5))
            wave.addCurve(to: CGPoint(x: 27, y: 4.5), control1: CGPoint(x: 22, y: 1.5), control2: CGPoint(x: 25, y: 1.5))
            ctx.stroke(wave, with: .color(p.wave), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
        case .rock:
            var rock = Path()
            rock.move(to: CGPoint(x: 2, y: 12.5))
            rock.addCurve(to: CGPoint(x: 9, y: 3.3), control1: CGPoint(x: 2, y: 8.5), control2: CGPoint(x: 5, y: 4.3))
            rock.addCurve(to: CGPoint(x: 20, y: 8.5), control1: CGPoint(x: 13, y: 2.3), control2: CGPoint(x: 18.2, y: 3.5))
            rock.addCurve(to: CGPoint(x: 19, y: 12.5), control1: CGPoint(x: 20.6, y: 10.3), control2: CGPoint(x: 20, y: 12.5))
            rock.closeSubpath()
            ctx.fill(rock, with: .color(p.rock))
            var shine = Path()
            shine.move(to: CGPoint(x: 6, y: 7.5))
            shine.addCurve(to: CGPoint(x: 10.6, y: 4.2), control1: CGPoint(x: 7, y: 5.5), control2: CGPoint(x: 8.6, y: 4.5))
            ctx.stroke(shine, with: .color(p.rockHi), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        case .island:
            drawIsland(in: ctx, palette: p)
        case .compass:
            drawCompass(in: ctx)
        case .plaza, .lamp:
            break
        }
    }

    private static func drawPlaza(center: CGPoint, diameter: CGFloat, in context: GraphicsContext, palette p: TownMapPalette) {
        let rect = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        let circle = Path(ellipseIn: rect)
        context.fill(circle, with: .color(p.plaza))
        // Cobblestones: a light grid of dots inside the square.
        var dots = context
        dots.clip(to: circle)
        let step = diameter / 8.5
        var y = rect.minY + step / 2
        while y < rect.maxY {
            var x = rect.minX + step / 2
            while x < rect.maxX {
                dots.fill(Path(ellipseIn: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8)), with: .color(p.plazaDot))
                x += step
            }
            y += step
        }
        context.stroke(Path(ellipseIn: rect.insetBy(dx: 1.5, dy: 1.5)), with: .color(p.plazaEdge), lineWidth: 3)
    }

    private static func drawIsland(in ctx: GraphicsContext, palette p: TownMapPalette) {
        ctx.fill(Path(ellipseIn: CGRect(x: 2, y: 20.5, width: 60, height: 13)), with: .color(p.foam))
        ctx.fill(Path(ellipseIn: CGRect(x: 8, y: 20, width: 48, height: 11)), with: .color(p.sand))
        var isle = Path()
        isle.move(to: CGPoint(x: 14, y: 25))
        isle.addCurve(to: CGPoint(x: 34, y: 16.5), control1: CGPoint(x: 18, y: 19), control2: CGPoint(x: 26, y: 16))
        isle.addCurve(to: CGPoint(x: 50, y: 25), control1: CGPoint(x: 42, y: 17), control2: CGPoint(x: 48, y: 21))
        isle.closeSubpath()
        ctx.fill(isle, with: .color(p.land1))
        var trunk = Path()
        trunk.move(to: CGPoint(x: 33, y: 18))
        trunk.addCurve(to: CGPoint(x: 36.5, y: 7), control1: CGPoint(x: 33.5, y: 14), control2: CGPoint(x: 34.5, y: 10))
        ctx.stroke(trunk, with: .color(p.trunk), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        // Three palm leaves from the top of the trunk.
        var leaves = Path()
        leaves.move(to: CGPoint(x: 36.5, y: 7))
        leaves.addCurve(to: CGPoint(x: 26.5, y: 8), control1: CGPoint(x: 32.5, y: 5), control2: CGPoint(x: 28.5, y: 5.5))
        leaves.addCurve(to: CGPoint(x: 36.5, y: 7), control1: CGPoint(x: 29.5, y: 7.5), control2: CGPoint(x: 32.5, y: 8))
        leaves.closeSubpath()
        leaves.move(to: CGPoint(x: 36.5, y: 7))
        leaves.addCurve(to: CGPoint(x: 46, y: 5), control1: CGPoint(x: 39.5, y: 4), control2: CGPoint(x: 43.5, y: 3.5))
        leaves.addCurve(to: CGPoint(x: 36.5, y: 7), control1: CGPoint(x: 43, y: 5.3), control2: CGPoint(x: 39.8, y: 6))
        leaves.closeSubpath()
        leaves.move(to: CGPoint(x: 36.5, y: 7))
        leaves.addCurve(to: CGPoint(x: 37, y: 15.5), control1: CGPoint(x: 38, y: 10), control2: CGPoint(x: 38, y: 13))
        leaves.addCurve(to: CGPoint(x: 36.5, y: 7), control1: CGPoint(x: 36.2, y: 12.5), control2: CGPoint(x: 36, y: 10))
        leaves.closeSubpath()
        ctx.fill(leaves, with: .color(p.leaf))
    }

    private static func drawCompass(in ctx: GraphicsContext) {
        let ring = Path(ellipseIn: CGRect(x: 5, y: 5, width: 30, height: 30))
        ctx.fill(ring, with: .color(.white.opacity(0.16)))
        ctx.stroke(ring, with: .color(.white.opacity(0.6)), lineWidth: 1.2)
        ctx.fill(polygon([(20, 6), (24, 20), (16, 20)]), with: .color(Color(hex: "#E5675B")))
        ctx.fill(polygon([(20, 34), (16, 20), (24, 20)]), with: .color(.white.opacity(0.85)))
        ctx.draw(Text("N").font(.system(size: 7, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.92)),
                 at: CGPoint(x: 20, y: 2.2))
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
        path.closeSubpath()
        return path
    }
}
