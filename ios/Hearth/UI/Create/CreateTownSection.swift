// "Move into Lantern Bay": give the character a home in town (and, if you like, a different spot for each
// part of the day) so they show up in Town scenes and Around town.

import SwiftUI

struct CreateTownSection: View {
    @Binding var draft: CreateDraft
    let locations: [Location]
    @Binding var showDayPlan: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HearthCard {
                Toggle(isOn: moveIn) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Move into Lantern Bay")
                            .font(HearthFont.headline)
                            .foregroundStyle(.hearthText)
                        Text("Give them a home in town, so they show up in Town scenes and Around town.")
                            .font(HearthFont.caption)
                            .foregroundStyle(.hearthText2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(.hearthAccent)
            }
            if draft.livesInTown {
                homePicker
                    .transition(.opacity.combined(with: .move(edge: .top)))
                CreateDisclosure("Their day", subtitle: "A different spot for each part of the day, if you like.",
                                 isExpanded: $showDayPlan) {
                    dayPlan
                }
                .transition(.opacity)
            }
        }
        .sensoryFeedback(.selection, trigger: draft.homeLocationID) { _, _ in app.settings.haptics }
    }

    private var moveIn: Binding<Bool> {
        Binding(
            get: { draft.livesInTown },
            set: { on in
                withAnimation(.snappy) {
                    draft.livesInTown = on
                    if on, draft.homeLocationID == nil { draft.homeLocationID = locations.first?.id }
                }
            }
        )
    }

    // MARK: Home

    private var homePicker: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Home")
                .font(HearthFont.headline)
                .foregroundStyle(.hearthText)
            let columns = [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 150 : 100), spacing: Spacing.s)]
            LazyVGrid(columns: columns, spacing: Spacing.s) {
                ForEach(locations) { place in
                    tile(place)
                }
            }
            if let home = locations.first(where: { $0.id == draft.homeLocationID }) {
                Text(home.blurb)
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tile(_ place: Location) -> some View {
        let selected = place.id == draft.homeLocationID
        let shape = RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
        return Button {
            withAnimation(.snappy) {
                draft.homeLocationID = place.id
                // A part of the day spent at the new home doesn't need its own entry.
                draft.dayPlaces = draft.dayPlaces.filter { $0.value != place.id }
            }
        } label: {
            VStack(spacing: Spacing.s) {
                AvatarView(place.art, size: 64, shape: .rounded, ring: selected ? .hearthAccent : nil)
                Text(place.name)
                    .font(HearthFont.caption.weight(.semibold))
                    .foregroundStyle(selected ? .hearthText : .hearthText2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.m)
            .padding(.horizontal, Spacing.xs)
            .background(selected ? Color.hearthSurface2 : Color.hearthSurface, in: shape)
            .overlay(shape.strokeBorder(selected ? Color.hearthAccent.opacity(0.7) : Color.hearthLine, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(place.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Parts of the day

    private var dayPlan: some View {
        HearthCard {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(DayPart.allCases, id: \.self) { part in
                    dayRow(part)
                    if part != DayPart.allCases.last {
                        Divider().overlay(Color.hearthLine)
                    }
                }
                Text("Anything left alone stays at home.")
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthText2)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    @ViewBuilder
    private func dayRow(_ part: DayPart) -> some View {
        let label = Label(Self.title(part), systemImage: Self.symbol(part))
            .font(HearthFont.callout.weight(.semibold))
            .foregroundStyle(.hearthText)
        let picker = Picker(Self.title(part), selection: place(for: part)) {
            ForEach(locations) { place in
                Text(place.name).tag(place.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(.hearthAccent)
        .fixedSize() // keep the place name on one line

        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                label
                picker
            }
            .frame(minHeight: 44)
        } else {
            HStack(spacing: Spacing.m) {
                label
                Spacer(minLength: Spacing.s)
                picker
            }
            .frame(minHeight: 44)
        }
    }

    private func place(for part: DayPart) -> Binding<String> {
        Binding(
            get: { draft.dayPlaces[part] ?? draft.homeLocationID ?? locations.first?.id ?? "" },
            set: { id in draft.dayPlaces[part] = id == draft.homeLocationID ? nil : id }
        )
    }

    static func title(_ part: DayPart) -> String {
        part.rawValue.capitalized
    }

    static func symbol(_ part: DayPart) -> String {
        switch part {
        case .morning: return "sunrise.fill"
        case .afternoon: return "sun.max.fill"
        case .evening: return "sunset.fill"
        case .night: return "moon.stars.fill"
        }
    }
}
