// The sections of a character's profile page: header, actions, "Right now", About, "Their people",
// "Past chats", "What they remember" and, for characters the user made, edit / share / delete.

import SwiftUI

// MARK: - Header

struct HomeProfileHeader: View {
    let character: Character

    var body: some View {
        let accent = Color(hex: character.accentHex)
        VStack(spacing: Spacing.m) {
            AvatarView(character.avatar, size: 168, shape: .rounded)
                .shadow(color: accent.opacity(0.5), radius: 28, y: 10)
                .background {
                    Circle()
                        .fill(RadialGradient(colors: [accent.opacity(0.42), accent.opacity(0)],
                                             center: .center, startRadius: 0, endRadius: 170))
                        .frame(width: 340, height: 340)
                }
                .padding(.top, Spacing.l)
                .padding(.bottom, Spacing.s)
            VStack(spacing: Spacing.xs) {
                Text(character.name)
                    .font(HearthFont.title(34))
                    .foregroundStyle(.hearthText)
                    .accessibilityAddTraits(.isHeader)
                Text(HomeText.speciesAndCreator(character))
                    .font(HearthFont.caption.weight(.medium))
                    .foregroundStyle(.hearthMuted)
            }
            if !character.tagline.isEmpty {
                Text(character.tagline)
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PrivacyBadge("Lives on this iPhone")
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Actions

struct HomeProfileActions: View {
    let name: String
    let chat: () -> Void
    let call: () -> Void
    let newChat: () -> Void

    var body: some View {
        VStack(spacing: Spacing.s) {
            chatButton.fullWidth()
                .accessibilityLabel("Chat with \(name)")
            // Call and New chat share a row when they fit, and stack with large text.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.s) {
                    secondaryButtons
                }
                VStack(spacing: Spacing.s) {
                    secondaryButtons
                }
            }
        }
    }

    @ViewBuilder
    private var secondaryButtons: some View {
        callButton.fullWidth()
            .accessibilityLabel("Call \(name)")
        newChatButton.fullWidth()
            .accessibilityLabel("Start a new chat with \(name)")
    }

    private var chatButton: PillButton {
        PillButton("Chat", symbol: "bubble.left.fill", kind: .primary, action: chat)
    }

    private var callButton: PillButton {
        PillButton("Call", symbol: "phone.fill", kind: .secondary, action: call)
    }

    private var newChatButton: PillButton {
        PillButton("New chat", symbol: "plus.bubble", kind: .secondary, action: newChat)
    }
}

// MARK: - Right now

struct HomeProfileDaySlot: Identifiable {
    let part: DayPart
    let place: Location?
    let activity: String
    var id: DayPart { part }
}

struct HomeProfileRightNow: View {
    let name: String
    let location: Location
    let activity: String
    let part: DayPart
    let day: [HomeProfileDaySlot]
    let visit: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        // With large text the picture sits above the words so they keep the full width.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.m))
            : AnyLayout(HStackLayout(spacing: Spacing.m))
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader("Right now")
            Button(action: visit) {
                layout {
                    HearthAvatarArt(ref: HomeText.locationArt(location), pointSize: 64)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(HomeText.dayPartName(part))
                            .font(HearthFont.small)
                            .foregroundStyle(.hearthMuted)
                        Text(HomeText.atPlace(location))
                            .font(HearthFont.headline)
                            .foregroundStyle(.hearthText)
                        Text(HomeText.sentence(activity))
                            .font(HearthFont.callout)
                            .foregroundStyle(.hearthText2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !typeSize.isAccessibilitySize {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.hearthMuted)
                            .accessibilityHidden(true)
                    }
                }
                .padding(Spacing.l)
                .background(Color.hearthSurface, in: shape)
                .overlay(shape.strokeBorder(Color.hearthLine.opacity(0.8), lineWidth: 1))
                .contentShape(shape)
            }
            .buttonStyle(.pressable)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Joins everyone \(HomeText.atPlace(location, startsSentence: false))")

            if !day.isEmpty {
                dayList
            }
        }
    }

    /// "Morning · Driftwood Cafe · Opening up..." for each part of the day, the current one marked.
    private var dayList: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("\(name)'s day")
                .font(HearthFont.headline)
                .foregroundStyle(.hearthText)
            ForEach(day) { slot in
                HStack(alignment: .top, spacing: Spacing.m) {
                    Circle()
                        .fill(slot.part == part ? Color.hearthAccent : Color.hearthLine)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(slotTitle(slot))
                            .font(HearthFont.callout.weight(.semibold))
                            .foregroundStyle(slot.part == part ? Color.hearthText : Color.hearthText2)
                        Text(HomeText.sentence(slot.activity))
                            .font(HearthFont.caption)
                            .foregroundStyle(.hearthMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(slot.part == part ? .isSelected : [])
            }
        }
        .padding(.horizontal, Spacing.xs)
    }

    private func slotTitle(_ slot: HomeProfileDaySlot) -> String {
        let place = slot.place.map { HomeText.shortPlaceName($0) } ?? "Around town"
        let now = slot.part == part ? " (now)" : ""
        return "\(HomeText.dayPartName(slot.part))\(now) · \(place)"
    }
}

// MARK: - About

struct HomeProfileAbout: View {
    let character: Character
    let searchTag: (String) -> Void

    var body: some View {
        let bio = character.bio.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bio.isEmpty || !character.tags.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.m) {
                SectionHeader("About")
                if !bio.isEmpty {
                    Text(bio)
                        .font(HearthFont.body)
                        .foregroundStyle(.hearthText)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !character.tags.isEmpty {
                    HomeFlowLayout(spacing: Spacing.s) {
                        ForEach(character.tags, id: \.self) { tag in
                            Button { searchTag(tag) } label: {
                                Text("#\(tag)")
                                    .font(HearthFont.caption.weight(.semibold))
                                    .foregroundStyle(.hearthText2)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color.hearthSurface2, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Color.hearthLine, lineWidth: 1))
                                    .padding(.vertical, 4) // taller tap target than the pill
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.pressable)
                            .accessibilityLabel(tag)
                            .accessibilityHint("Searches for \(tag)")
                        }
                    }
                }
            }
        }
    }
}

/// Lays children out left to right, wrapping to a new line when the row is full (used for tags).
struct HomeFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width ?? .infinity
        let rows = arrange(subviews, width: available)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: available.isFinite ? available : widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let fitted = CGSize(width: min(size.width, bounds.width), height: size.height)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(fitted))
                x += fitted.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            if !row.indices.isEmpty, row.width + spacing + itemWidth > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + itemWidth
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Their people

struct HomeProfilePerson: Identifiable {
    let relationship: Relationship
    let character: Character
    var id: String { character.id }
}

struct HomeProfilePeople: View {
    let ownerName: String
    let people: [HomeProfilePerson]
    let open: (String) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                SectionHeader("Their people")
                Text("In \(ownerName)'s own words.")
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
            }
            VStack(spacing: 0) {
                ForEach(people) { person in
                    Button { open(person.character.id) } label: {
                        row(person)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityHint("Opens their profile")
                    if person.id != people.last?.id {
                        Divider().overlay(Color.hearthLine).padding(.leading, Spacing.m)
                    }
                }
            }
            .background(Color.hearthSurface, in: shape)
            .overlay(shape.strokeBorder(Color.hearthLine.opacity(0.8), lineWidth: 1))
        }
    }

    /// Avatar, name and how they know each other, with the quote underneath at full width.
    private func row(_ person: HomeProfilePerson) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                AvatarView(person.character.avatar, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.character.name)
                        .font(HearthFont.headline)
                        .foregroundStyle(.hearthText)
                    Text(HomeText.capitalizedFirst(person.relationship.kind))
                        .font(HearthFont.caption.weight(.semibold))
                        .foregroundStyle(.hearthSea)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.hearthMuted)
                    .accessibilityHidden(true)
            }
            Text("“\(HomeRelationshipNote.inTheirWords(person.relationship.note))”")
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Past chats

struct HomeProfilePastChats: View {
    let chats: [Conversation]
    let now: Date
    let open: (UUID) -> Void
    let newChat: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader("Past chats", actionTitle: chats.isEmpty ? nil : "New chat", action: chats.isEmpty ? nil : newChat)
            if chats.isEmpty {
                Text("No chats yet. Say hello, and your conversations will show up here.")
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(chats) { conversation in
                        Button { open(conversation.id) } label: {
                            row(conversation)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityHint("Opens the chat")
                        if conversation.id != chats.last?.id {
                            Divider().overlay(Color.hearthLine).padding(.leading, Spacing.l)
                        }
                    }
                }
                .background(Color.hearthSurface, in: shape)
                .overlay(shape.strokeBorder(Color.hearthLine.opacity(0.8), lineWidth: 1))
            }
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        let count = conversation.messages.filter { $0.role != .narrator }.count
        let messages = count == 1 ? "1 message" : "\(count) messages"
        return HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(HomeText.preview(of: conversation))
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText)
                    .lineLimit(2)
                Text("\(messages) · \(HomeText.shortTime(conversation.updatedAt, now: now))")
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthMuted)
                    .accessibilityLabel("\(messages), \(HomeText.spokenTime(conversation.updatedAt, now: now))")
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.hearthMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - What they remember

struct HomeProfileMemoryRow: View {
    let name: String
    let count: Int
    let open: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        Button(action: open) {
            HStack(spacing: Spacing.m) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.hearthGold)
                    .frame(width: 44, height: 44)
                    .background(Color.hearthGold.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What \(name) remembers")
                        .font(HearthFont.headline)
                        .foregroundStyle(.hearthText)
                    Text(detail)
                        .font(HearthFont.callout)
                        .foregroundStyle(.hearthText2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.hearthMuted)
                    .accessibilityHidden(true)
            }
            .padding(Spacing.l)
            .background(Color.hearthSurface, in: shape)
            .overlay(shape.strokeBorder(Color.hearthLine.opacity(0.8), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows what they remember, and lets you remove anything")
    }

    private var detail: String {
        switch count {
        case 0: return "Nothing yet. Things you share in chats can stick."
        case 1: return "1 thing about you, kept on this iPhone"
        default: return "\(count) things about you, kept on this iPhone"
        }
    }
}

// MARK: - Your character (edit, share, delete)

struct HomeProfileOwnerTools: View {
    let character: Character
    let edit: () -> Void
    let delete: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader("Your character")
            VStack(spacing: 0) {
                Button(action: edit) {
                    toolLabel("Edit \(character.name)", symbol: "pencil", tint: .hearthText)
                }
                .buttonStyle(.pressable)
                divider
                ShareLink(item: HomeCharacterCardFile(character: character),
                          preview: SharePreview("\(character.name) character card", image: Image(systemName: "person.text.rectangle"))) {
                    toolLabel("Share character card", symbol: "square.and.arrow.up", tint: .hearthText)
                }
                .buttonStyle(.pressable)
                divider
                Button { confirmingDelete = true } label: {
                    toolLabel("Delete \(character.name)", symbol: "trash", tint: .hearthDanger)
                }
                .buttonStyle(.pressable)
                .confirmationDialog("Delete \(character.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Delete \(character.name)", role: .destructive, action: delete)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes \(character.name), your chats with them and what they remember from this iPhone. It can't be undone.")
                }
            }
            .background(Color.hearthSurface, in: shape)
            .overlay(shape.strokeBorder(Color.hearthLine.opacity(0.8), lineWidth: 1))
            Text("Cards are saved as Character Card V2 files, which other character apps can open.")
                .font(HearthFont.caption)
                .foregroundStyle(.hearthMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var divider: some View {
        Divider().overlay(Color.hearthLine).padding(.leading, 28 + Spacing.l + Spacing.m)
    }

    private func toolLabel(_ title: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title)
                .font(HearthFont.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Spacing.l)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}
