// Pieces of the scene screen: the place banner, who is here, each line (avatar + name above the words),
// the live typing row, the support card, the engine banner, action chips and the invite sheet.

import SwiftUI

/// The place's art as a wide banner that fades into the page, with its name and mood on top.
struct SceneBanner: View {
    let location: Location
    let worldName: String
    let part: DayPart

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label("\(TownText.label(part)) in \(worldName)", systemImage: TownText.symbol(part))
                .font(HearthFont.caption.weight(.semibold))
                .foregroundStyle(.hearthText2)
            Text(location.name)
                .font(HearthFont.title(30))
                .foregroundStyle(.hearthText)
                .accessibilityAddTraits(.isHeader)
            Text(location.ambience)
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, 150)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) { art }
    }

    private var art: some View {
        Color.clear
            .frame(height: 250)
            .overlay { HearthAvatarArt(ref: location.art, pointSize: 430) }
            .overlay {
                LinearGradient(stops: [
                    .init(color: Color.hearthBackground.opacity(0), location: 0.3),
                    .init(color: Color.hearthBackground.opacity(0.78), location: 0.62),
                    .init(color: Color.hearthBackground, location: 0.94),
                ], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .accessibilityHidden(true)
    }
}

/// "Here now": everyone present (tap for their profile), plus a button to invite someone.
struct ScenePresentStrip: View {
    let present: [Character]
    let invited: Set<String>
    let inviteDisabled: Bool
    var onProfile: (String) -> Void
    var onInvite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Here now")
                .font(HearthFont.caption.weight(.semibold))
                .foregroundStyle(.hearthText2)
                .padding(.horizontal, Spacing.l)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Spacing.m) {
                    ForEach(present) { person in
                        Button { onProfile(person.id) } label: { face(person) }
                            .buttonStyle(.pressable)
                            .accessibilityLabel(invited.contains(person.id) ? "\(person.name), visiting" : person.name)
                            .accessibilityHint("Opens \(person.name)'s profile")
                    }
                    Button(action: onInvite) {
                        VStack(spacing: 6) {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.hearthText2)
                                .frame(width: 56, height: 56)
                                .background(Circle().fill(Color.hearthSurface2))
                                .overlay(Circle().strokeBorder(Color.hearthLine, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])))
                            Text("Invite")
                                .font(HearthFont.caption.weight(.semibold))
                                .foregroundStyle(.hearthText2)
                        }
                        .frame(minWidth: 64)
                    }
                    .buttonStyle(.pressable)
                    .disabled(inviteDisabled)
                    .accessibilityLabel("Invite someone")
                }
                .padding(.horizontal, Spacing.l)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func face(_ person: Character) -> some View {
        VStack(spacing: 6) {
            AvatarView(person.avatar, size: 56, ring: Color(hex: person.accentHex))
            Text(person.name)
                .font(HearthFont.caption.weight(.semibold))
                .foregroundStyle(.hearthText)
                .lineLimit(1)
            if invited.contains(person.id) {
                Text("Visiting")
                    .font(HearthFont.small)
                    .foregroundStyle(.hearthMuted)
            }
        }
        .frame(minWidth: 64)
    }
}

/// One line of the scene: the person's own words on the right; a character's avatar and name above
/// their words on the left (no bubble); invite notes centered and quiet.
struct SceneLine: View {
    let message: Message
    let speaker: Character?
    let canDelete: Bool
    var onProfile: (String) -> Void
    var onDelete: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        switch message.role {
        case .user: userLine
        case .character: characterLine
        case .narrator: note
        }
    }

    private var userLine: some View {
        HStack {
            Spacer(minLength: 56)
            Text(TownText.styled(message.text))
                .font(HearthFont.body)
                .foregroundStyle(.hearthText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.hearthSurface2, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
                .contextMenu { copyButton; deleteButton }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(TownText.plain(message.text))")
    }

    private var characterLine: some View {
        let name = speaker?.name ?? "Someone"
        return HStack(alignment: .top, spacing: Spacing.s + 2) {
            AvatarView(speaker?.avatar ?? AvatarRef(symbol: "person.fill"), size: 36)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(name)
                    .font(HearthFont.caption.weight(.semibold))
                    .foregroundStyle(.hearthText2)
                if !message.text.isEmpty {
                    Text(TownText.styled(message.text))
                        .font(HearthFont.body)
                        .foregroundStyle(.hearthText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let attachment = message.attachment, attachment.kind == .picture {
                    ScenePicture(attachment: attachment)
                }
                if app.settings.showEngineStats, let stats = message.stats {
                    Text(TownText.statsLine(stats))
                        .font(HearthFont.small.monospacedDigit())
                        .foregroundStyle(.hearthMuted)
                }
            }
            Spacer(minLength: Spacing.xl)
        }
        .contentShape(Rectangle())
        .contextMenu {
            copyButton
            if let speaker, !message.text.isEmpty {
                Button("Play aloud", systemImage: "speaker.wave.2") {
                    app.voice.speak(message.text, as: speaker, overrides: app.settings.voiceOverrides, messageID: message.id)
                }
                Button("\(speaker.name)'s profile", systemImage: "person.crop.circle") { onProfile(speaker.id) }
            }
            deleteButton
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(TownText.plain(message.text))")
    }

    private var note: some View {
        Text(TownText.styled(message.text, textStyle: .footnote))
            .font(HearthFont.caption)
            .foregroundStyle(.hearthMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xs)
            .contextMenu { deleteButton }
    }

    @ViewBuilder private var copyButton: some View {
        if !message.text.isEmpty {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = TownText.plain(message.text) }
        }
    }

    @ViewBuilder private var deleteButton: some View {
        if canDelete {
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

/// A picture a character shared in the scene (town art or a postcard; a placeholder shows while it is picked).
struct ScenePicture: View {
    let attachment: Attachment
    private let shape = RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous)

    var body: some View {
        switch attachment.status {
        case .pending:
            shape.fill(Color.hearthSurface2)
                .frame(width: 220, height: 220)
                .overlay {
                    VStack(spacing: Spacing.s) {
                        ProgressView()
                        Text("Picking a picture…")
                            .font(HearthFont.caption)
                            .foregroundStyle(.hearthText2)
                    }
                }
                .accessibilityElement(children: .combine)
        case .ready:
            if let file = attachment.file {
                MediaImage(relativePath: file)
                    .frame(width: 220, height: 220)
                    .clipShape(shape)
                    .accessibilityLabel(attachment.caption.map { "Picture: \($0)" } ?? "Picture")
            }
        case .failed:
            EmptyView()
        }
    }
}

/// The line being written right now: who is typing, then their words as they arrive.
struct SceneStreamingLine: View {
    let speaker: Character
    let text: String?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s + 2) {
            AvatarView(speaker.avatar, size: 36)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(speaker.name)
                    .font(HearthFont.caption.weight(.semibold))
                    .foregroundStyle(.hearthText2)
                if let text, !text.isEmpty {
                    Text(TownText.styled(text))
                        .font(HearthFont.body)
                        .foregroundStyle(.hearthText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    TypingIndicator()
                }
            }
            Spacer(minLength: Spacing.xl)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(speaker.name) is typing")
    }
}

/// Gentle support resources, shown when something the person wrote sounds like they may be in danger.
/// It never blocks the conversation and can be hidden.
struct SceneSupportCard: View {
    let level: SafetyLevel
    var onHide: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.hearthAccent)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                Text(level == .crisis ? "Help is here, any time" : "If things feel heavy")
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.s)
                Button(action: onHide) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.hearthMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, -12)
                .padding(.trailing, -12)
                .accessibilityLabel("Hide support options")
            }
            Text(SafetyGuard.gentleMessage)
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(SafetyGuard.resources.enumerated()), id: \.element.id) { index, resource in
                resourceRow(resource, primary: index == 0)
            }
            Text("If you're in immediate danger, call your local emergency number.")
                .font(HearthFont.caption)
                .foregroundStyle(.hearthMuted)
        }
        .padding(Spacing.l)
        .background(Color.hearthSurface, in: shape)
        .overlay(shape.strokeBorder(Color.hearthSea.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func resourceRow(_ resource: SafetyResource, primary: Bool) -> some View {
        // A long button title ("Open findahelpline.com") goes under its description instead of being cut short.
        let stacked = typeSize.isAccessibilitySize || resource.actionTitle.count > 12
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.m))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(resource.title)
                    .font(HearthFont.callout.weight(.semibold))
                    .foregroundStyle(.hearthText)
                Text(resource.detail)
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthText2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Link(destination: resource.url) {
                Text(resource.actionTitle)
                    .font(HearthFont.callout.weight(.semibold))
                    .foregroundStyle(primary ? Color.hearthOnAccent : Color.hearthText)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(primary ? Color.hearthAccent : Color.hearthSurface2, in: Capsule())
            }
        }
    }
}

/// What the person sees instead of replies when the model isn't running yet, or when only the demo engine
/// (canned lines, no AI) is standing in.
struct SceneEngineBanner: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        switch app.engine.state {
        case .ready:
            if app.engine.active?.id == "mock" {
                card(symbol: "theatermasks.fill", title: "Demo replies",
                     detail: "Everyone here is saying simple canned lines with no AI behind them, so they don't really hear you. Download a model to talk for real.",
                     button: "Models")
            }
        case .idle:
            status("Getting the town ready…")
        case .loading(let label):
            status(label)
        case .needsModel:
            if let download = SettingsModelActions.downloadLine(app.engine) {
                status(download + ". Everyone can talk as soon as it's on this iPhone.")
            } else {
                card(symbol: "arrow.down.circle.fill", title: "The town needs its model to talk",
                     detail: "It downloads once. After that everyone here lives on this iPhone, even offline.",
                     button: "Get the model")
            }
        case .failed(let message):
            card(symbol: "exclamationmark.triangle.fill", title: "The model isn't running", detail: message,
                 button: "Model settings")
        }
    }

    private func status(_ text: String) -> some View {
        HStack(spacing: Spacing.s) {
            ProgressView()
            Text(text)
                .font(HearthFont.caption)
                .foregroundStyle(.hearthText2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func card(symbol: String, title: String, detail: String, button: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.hearthGold)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(title)
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText)
                Text(detail)
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthText2)
                    .fixedSize(horizontal: false, vertical: true)
                PillButton(button, kind: .secondary) { router.show(.settings(.model), in: .you) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.m)
        .background(Color.hearthSurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.hearthLine, lineWidth: 1))
    }
}

/// A small action chip ("Let them talk"): a 36 pt capsule inside a 44 pt tap area.
struct SceneChip: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(HearthFont.callout.weight(.semibold))
                .foregroundStyle(.hearthText)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(Color.hearthSurface2, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.hearthLine, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.45)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}

/// Pick someone to come over: residents first (with where they are now), then the person's own characters.
struct SceneInviteSheet: View {
    let controller: SceneController
    let location: Location
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let here = Set(controller.present.map(\.id))
        let townsfolk = app.library.world.characters.filter { !here.contains($0.id) }
        let yours = app.library.userCharacters.filter { !here.contains($0.id) }
        NavigationStack {
            List {
                if !townsfolk.isEmpty {
                    Section {
                        ForEach(townsfolk) { row($0) }
                    } header: {
                        Text("Around town")
                    } footer: {
                        Text("They'll stay until the \(TownText.label(DayPart.at(.now)).lowercased()) is over.")
                    }
                }
                if !yours.isEmpty {
                    Section("Your characters") {
                        ForEach(yours) { row($0) }
                    }
                }
            }
            .overlay {
                if townsfolk.isEmpty && yours.isEmpty {
                    EmptyStateView(symbol: "person.3.fill", title: "Everyone's here",
                                   message: "Everyone in town is already at \(TownText.inSentence(location.name)).")
                }
            }
            .hearthScreenBackground()
            .navigationTitle("Invite someone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ person: Character) -> some View {
        Button {
            controller.invite(characterID: person.id)
            dismiss()
        } label: {
            HStack(spacing: Spacing.m) {
                AvatarView(person.avatar, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .font(HearthFont.headline)
                        .foregroundStyle(.hearthText)
                    Text(whereNow(person))
                        .font(HearthFont.callout)
                        .foregroundStyle(.hearthText2)
                        .lineLimit(2)
                }
                Spacer(minLength: Spacing.s)
                Text("Invite")
                    .font(HearthFont.callout.weight(.semibold))
                    .foregroundStyle(.hearthAccentText)
            }
            .contentShape(Rectangle())
        }
        .listRowBackground(Color.hearthSurface)
        .accessibilityLabel("Invite \(person.name)")
        .accessibilityValue(whereNow(person))
    }

    private func whereNow(_ person: Character) -> String {
        guard let place = app.director.location(of: person, at: .now) else { return person.tagline }
        return TownText.at(place.name) + " now"
    }
}
