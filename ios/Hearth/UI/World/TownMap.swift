// The interactive town map: the drawn map, a pin per place, and each resident's little avatar at the place
// they are during the shown part of the day. Avatars glide from pin to pin when the part changes.

import SwiftUI
import UIKit

/// Sizes and positions on the map. Pure math, unit-tested.
enum TownMapLayout {
    /// Width / height of the map on a phone (a little taller than wide).
    static let aspectRatio: CGFloat = 4.0 / 5.0
    static let markerSize: CGFloat = 36
    static let avatarSize: CGFloat = 22
    /// Distance between overlapping avatars under a pin.
    static let avatarStep: CGFloat = 15
    /// At most this many slots under a pin; with more people the last slot says "+N".
    static let maxSlots = 4
    /// A pin's frame: the marker on top, room for the avatar row, then the name label.
    static let pinWidth: CGFloat = 76
    static let pinHeight: CGFloat = 74

    static func markerCenter(_ map: MapPoint, in size: CGSize) -> CGPoint {
        TownMapArt.point(map.x, map.y, in: size)
    }

    /// Where to `.position` a pin so its marker sits exactly on the place.
    static func pinCenter(forMarker marker: CGPoint) -> CGPoint {
        CGPoint(x: marker.x, y: marker.y - markerSize / 2 + pinHeight / 2)
    }

    /// Centers of the avatar slots under a marker for `count` people (at most `maxSlots` slots).
    static func avatarSlots(count: Int, marker: CGPoint) -> [CGPoint] {
        let n = min(max(count, 0), maxSlots)
        guard n > 0 else { return [] }
        let width = avatarSize + CGFloat(n - 1) * avatarStep
        let y = marker.y + markerSize / 2 - avatarSize * 0.38 + avatarSize / 2
        return (0..<n).map { i in
            CGPoint(x: marker.x - width / 2 + avatarSize / 2 + CGFloat(i) * avatarStep, y: y)
        }
    }

    /// How many avatars show under a pin (the rest are counted in a "+N" chip in the last slot).
    static func visibleAvatars(count: Int) -> Int {
        count <= maxSlots ? count : maxSlots - 1
    }
}

struct TownMapView: View {
    let world: WorldDefinition
    /// The part of the day shown (now, or a peek).
    let part: DayPart
    /// Who is where during `part` (residents per place id, in world order).
    let residentsByPlace: [String: [Character]]
    let isNow: Bool
    var onOpen: (Location) -> Void

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let palette = TownMapPalette.forPart(part)
            ZStack(alignment: .topLeading) {
                TownMapBackdrop(part: part, palette: palette)
                TownMapTerrain(palette: palette, places: world.locations.map(\.map))
                    .opacity(0.93)
                    .id(part)
                    .transition(.opacity)
                TownMapTint(part: part, size: size)
                ForEach(pinOrder) { location in
                    let marker = TownMapLayout.markerCenter(location.map, in: size)
                    pinButton(location, people: residentsByPlace[location.id] ?? [])
                        .position(TownMapLayout.pinCenter(forMarker: marker))
                        .zIndex(location.map.y)
                }
                avatarLayer(size: size, palette: palette)
                    .zIndex(2)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(TownMapLayout.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.hearthLine, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            // The header above already shows the time; the badge only says when someone is peeking.
            if !isNow {
                badge
                    .padding(Spacing.m)
                    .allowsHitTesting(false) // pins underneath stay tappable
                    .transition(.opacity)
            }
        }
        .background {
            // Shadow from a plain shape, so the moving avatars never force the whole map offscreen.
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.hearthSurface)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        // The map is a picture: its labels stay map-sized. The Places list below grows with Dynamic Type.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isNow ? "Map of \(world.name), right now" : "Map of \(world.name), \(TownText.label(part).lowercased())")
    }

    /// Pins from the top of the map down, so lower pins draw over higher ones (and VoiceOver reads top to bottom).
    private var pinOrder: [Location] {
        world.locations.sorted { $0.map.y < $1.map.y }
    }

    private func pinButton(_ location: Location, people: [Character]) -> some View {
        Button { onOpen(location) } label: {
            TownMapPin(location: location, isEmpty: people.isEmpty, afterDark: part == .evening || part == .night)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(location.name)
        .accessibilityValue(peopleSummary(people))
        .accessibilityHint("Opens the conversation there")
    }

    private func peopleSummary(_ people: [Character]) -> String {
        let when = isNow ? "now" : "in the \(TownText.label(part).lowercased())"
        return people.isEmpty ? "Nobody here \(when)" : "Here \(when): \(TownText.names(people))"
    }

    // MARK: Avatars

    /// One avatar per resident, keyed by id, so moving between places animates as a glide.
    private func avatarLayer(size: CGSize, palette: TownMapPalette) -> some View {
        let spots = avatarSpots(size: size)
        return ZStack(alignment: .topLeading) {
            ForEach(world.characters) { character in
                if let spot = spots.avatars[character.id] {
                    TownMapAvatar(character: character, ring: palette.ring)
                        .position(spot.center)
                        .opacity(spot.visible ? 1 : 0)
                }
            }
            ForEach(spots.chips, id: \.placeID) { chip in
                Text("+\(chip.count)")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(hex: "#F4EDE4"))
                    .padding(.horizontal, 5)
                    .frame(minWidth: TownMapLayout.avatarSize, minHeight: TownMapLayout.avatarSize)
                    .background(Color(hex: "#211B16"), in: Capsule())
                    .overlay(Capsule().strokeBorder(palette.ring, lineWidth: 2))
                    .position(chip.center)
                    .transition(.opacity)
            }
        }
        .accessibilityHidden(true)
    }

    private struct AvatarSpot { var center: CGPoint; var visible: Bool }
    private struct OverflowChip { var placeID: String; var center: CGPoint; var count: Int }

    private func avatarSpots(size: CGSize) -> (avatars: [String: AvatarSpot], chips: [OverflowChip]) {
        var avatars: [String: AvatarSpot] = [:]
        var chips: [OverflowChip] = []
        for location in world.locations {
            let people = residentsByPlace[location.id] ?? []
            let marker = TownMapLayout.markerCenter(location.map, in: size)
            let slots = TownMapLayout.avatarSlots(count: people.count, marker: marker)
            let shown = TownMapLayout.visibleAvatars(count: people.count)
            for (index, person) in people.enumerated() {
                guard let last = slots.last else { continue }
                // Hidden ones wait (invisible) in the "+N" slot, so they fade in when they move somewhere roomier.
                avatars[person.id] = index < shown ? AvatarSpot(center: slots[index], visible: true)
                                                   : AvatarSpot(center: last, visible: false)
            }
            if people.count > shown, let last = slots.last {
                chips.append(OverflowChip(placeID: location.id, center: last, count: people.count - shown))
            }
        }
        return (avatars, chips)
    }

    // MARK: Badge

    private var badge: some View {
        Label("\(TownText.label(part)), peeking", systemImage: TownText.symbol(part))
            .font(HearthFont.small.weight(.semibold))
            .foregroundStyle(Color(hex: "#FBF5EC"))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(Color.black.opacity(0.3)), in: Capsule())
            .environment(\.colorScheme, .dark)
            .accessibilityHidden(true) // the map's own label says the time
    }
}

/// A place's pin: a cream bubble with the place's symbol, and its short name underneath.
private struct TownMapPin: View {
    let location: Location
    let isEmpty: Bool
    let afterDark: Bool

    var body: some View {
        VStack(spacing: 0) {
            marker
            Spacer(minLength: 0)
            Text(TownText.shortName(location.name))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: "#FBF5EC"))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color(hex: "#18120E").opacity(0.78), in: Capsule())
                .frame(height: 20)
        }
        .frame(width: TownMapLayout.pinWidth, height: TownMapLayout.pinHeight)
        .contentShape(Rectangle())
    }

    private var marker: some View {
        let colors = location.art.colors ?? []
        let ring = Color(hex: colors.last ?? "#FF8A4C")
        let ink = Color(hex: colors.first ?? "#4A3022")
        return Image(systemName: symbolName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(ink)
            .frame(width: TownMapLayout.markerSize, height: TownMapLayout.markerSize)
            .background(
                Circle().fill(RadialGradient(colors: [.white, Color(hex: "#FFF8EC"), Color(hex: "#EFE1CA")],
                                             center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0,
                                             endRadius: TownMapLayout.markerSize * 0.8))
            )
            .overlay(Circle().strokeBorder(ring, lineWidth: 3))
            .shadow(color: afterDark ? Color(hex: "#FFC46C").opacity(0.6) : Color.black.opacity(0.3),
                    radius: afterDark ? 10 : 6, y: afterDark ? 0 : 4)
            .saturation(isEmpty ? 0.5 : 1)
            .opacity(isEmpty ? 0.8 : 1)
    }

    /// The place's SF Symbol, or a plain pin if this iOS doesn't have it.
    private var symbolName: String {
        UIImage(systemName: location.symbol) == nil ? "mappin" : location.symbol
    }
}

/// A resident's tiny avatar on the map, with a ring that matches the light.
private struct TownMapAvatar: View {
    let character: Character
    let ring: Color

    var body: some View {
        AvatarView(character.avatar, size: TownMapLayout.avatarSize)
            .overlay(Circle().strokeBorder(ring, lineWidth: 2))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}

/// The town art, blurred, under the drawn map: it gives the sea and land a soft painted texture.
private struct TownMapBackdrop: View {
    let part: DayPart
    let palette: TownMapPalette

    var body: some View {
        HearthCachedImage(source: .bundled(TownText.heroAsset(part)), maxPixel: 512) { phase in
            if case .loaded(let image) = phase {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [palette.sea1, palette.sea2], startPoint: .top, endPoint: .bottom)
            }
        }
        .blur(radius: 16)
        .saturation(1.2)
        .scaleEffect(1.15)
        .opacity(0.9)
        .accessibilityHidden(true)
    }
}

/// The light of the time of day over the map, plus a soft vignette at the edges.
private struct TownMapTint: View {
    let part: DayPart
    let size: CGSize

    var body: some View {
        ZStack {
            switch part {
            case .morning:
                LinearGradient(colors: [tint(255, 214, 160, 0.3), tint(255, 214, 160, 0)],
                               startPoint: .topLeading, endPoint: UnitPoint(x: 0.6, y: 0.6))
            case .afternoon:
                Color.clear
            case .evening:
                LinearGradient(colors: [tint(255, 150, 80, 0.2), tint(140, 70, 110, 0.16)], startPoint: .top, endPoint: .bottom)
            case .night:
                RadialGradient(colors: [tint(30, 40, 90, 0.25), tint(5, 8, 20, 0.2)], center: .top,
                               startRadius: 0, endRadius: max(size.height, 1))
            }
            RadialGradient(colors: [.clear, tint(8, 6, 5, 0.28)], center: .center,
                           startRadius: size.width * 0.42, endRadius: max(size.width * 0.82, 1))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func tint(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: alpha)
    }
}
