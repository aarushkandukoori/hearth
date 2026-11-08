// Character avatars: the character's image when there is one, otherwise their emoji or SF Symbol on a
// gradient of their colors. Images decode off the main thread (see ImagePipeline.swift).

import SwiftUI
import UIKit

enum AvatarShape {
    case circle, rounded

    /// Rounded avatars use Radius.avatarSquare when big and scale it down when small.
    static func cornerRadius(for size: CGFloat) -> CGFloat {
        min(Radius.avatarSquare, size * 0.22)
    }
}

struct AvatarView: View {
    private let ref: AvatarRef
    private let size: CGFloat
    private let shape: AvatarShape
    private let ring: Color?

    init(_ ref: AvatarRef, size: CGFloat, shape: AvatarShape = .circle, ring: Color? = nil) {
        self.ref = ref
        self.size = size
        self.shape = shape
        self.ring = ring
    }

    var body: some View {
        // With a ring, the picture shrinks so ring + a small gap fit inside `size`.
        let ringWidth: CGFloat = ring == nil ? 0 : max(2, size * 0.03)
        let gap: CGFloat = ring == nil ? 0 : max(1.5, size * 0.025)
        let inner = max(1, size - 2 * (ringWidth + gap))
        let outerRadius = AvatarShape.cornerRadius(for: size)
        let innerRadius = max(0, outerRadius - ringWidth - gap)

        HearthAvatarArt(ref: ref, pointSize: inner)
            .frame(width: inner, height: inner)
            .clipShape(AvatarOutline(shape: shape, cornerRadius: innerRadius))
            .frame(width: size, height: size)
            .overlay {
                if let ring {
                    AvatarOutline(shape: shape, cornerRadius: outerRadius)
                        .strokeBorder(ring, lineWidth: ringWidth)
                }
            }
            .accessibilityHidden(true) // the name next to it says who this is
    }
}

/// Avatar artwork that fills whatever frame it is given. `pointSize` sets the decode size and emoji size.
struct HearthAvatarArt: View {
    let ref: AvatarRef
    let pointSize: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HearthCachedImage(source: source, maxPixel: HearthImageCache.pixelBucket(pointSize * displayScale)) { phase in
            if case .loaded(let image) = phase {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                fallback
            }
        }
    }

    /// file first (user-made), then bundled art.
    private var source: HearthImageSource? {
        if let file = ref.file, !file.isEmpty { return .media(file) }
        if let asset = ref.asset, !asset.isEmpty { return .bundled(asset) }
        return nil
    }

    private var fallback: some View {
        ZStack {
            HearthAvatarGradient(ref: ref)
            if let emoji = ref.emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: pointSize * 0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: pointSize * 0.4, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
    }

    private var symbolName: String {
        if let symbol = ref.symbol, UIImage(systemName: symbol) != nil { return symbol }
        return "face.smiling"
    }
}

/// The soft two-tone background behind emoji and symbol avatars.
struct HearthAvatarGradient: View {
    let ref: AvatarRef

    /// Used when an avatar has no colors; picked by the emoji/symbol so different characters differ.
    private static let defaultPairs = [
        ["#4A3428", "#9A6040"], ["#2C4048", "#5E8F9B"], ["#3B3350", "#7B6C9E"],
        ["#2E4A3F", "#6E9E86"], ["#55302B", "#A65A4B"],
    ]

    var body: some View {
        let given = (ref.colors ?? []).map { Color(hex: $0) }
        let colors: [Color]
        switch given.count {
        case 0: colors = Self.defaultPairs[Int(seed % UInt32(Self.defaultPairs.count))].map { Color(hex: $0) }
        case 1: colors = [given[0], given[0]]
        default: colors = given
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                // A gentle sheen from the top left so flat colors feel lit.
                EllipticalGradient(colors: [.white.opacity(0.16), .clear],
                                   center: UnitPoint(x: 0.3, y: 0.15),
                                   startRadiusFraction: 0, endRadiusFraction: 0.8)
            }
    }

    private var seed: UInt32 {
        (ref.emoji ?? ref.symbol ?? ref.asset ?? "").unicodeScalars.reduce(0) { $0 &+ $1.value }
    }
}

/// Circle or continuous rounded square that can be inset (needed for `strokeBorder`).
private struct AvatarOutline: InsettableShape {
    var shape: AvatarShape
    var cornerRadius: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        switch shape {
        case .circle: return Path(ellipseIn: r)
        case .rounded: return Path(roundedRect: r, cornerRadius: max(0, cornerRadius - inset), style: .continuous)
        }
    }

    func inset(by amount: CGFloat) -> AvatarOutline {
        var copy = self
        copy.inset += amount
        return copy
    }
}
