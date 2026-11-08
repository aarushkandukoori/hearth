// The scrolling list of messages: the character's avatar and name above their text (no heavy bubble),
// the user's words in a soft bubble on the right, the live reply, swipeable alternates with "2/3",
// stars and regenerate under the last reply, a long-press menu on every message, the support card right
// after the message that called for it, and "jump to latest".

import SwiftUI
import UIKit

struct ChatMessageList: View {
    let controller: ChatController
    let character: Character
    let onEdit: (Message) -> Void
    let onOpenPicture: (ChatPictureViewer.Item) -> Void
    /// Whether the support card is on screen (the bottom bar offers a short version while it isn't).
    @Binding var supportCardVisible: Bool

    @State private var position = ScrollPosition(edge: .bottom)
    /// Follow new content. Only the user scrolling up turns this off; growing content never does.
    @State private var pinned = true
    @State private var atBottom = true
    @State private var phase: ScrollPhase = .idle
    /// Something changed size during an animated scroll: finish at the newest message when it ends.
    @State private var followAfterAnimation = false

    var body: some View {
        let messages = controller.conversation.messages
        let lastReply = ChatPipeline.lastReplyIndex(in: messages)
        let supportIndex = supportCardIndex(in: messages)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ChatIntroHeader(character: character)
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    ChatMessageRow(
                        message: message,
                        character: character,
                        controller: controller,
                        showsTime: ChatPipeline.startsTimeGroup(previous: index > 0 ? messages[index - 1].createdAt : nil,
                                                                current: message.createdAt),
                        isLastReply: index == lastReply,
                        isGreeting: index == 0 && message.role == .character,
                        onEdit: onEdit,
                        onOpenPicture: onOpenPicture)
                    if index == supportIndex {
                        supportCard
                    }
                }
                if controller.isReplying && controller.regeneratingID == nil {
                    ChatPendingReply(controller: controller, character: character, onGrow: followIfPinned)
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.m)
            .padding(.bottom, Spacing.l)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollDismissesKeyboard(.interactively)
        // A crisp edge under the two-line title, so "by @creator" never sits on top of messages or pictures.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .onScrollGeometryChange(for: ScrollFacts.self) { geometry in
            // containerSize is the part between the bars and the composer (insets already taken out),
            // so the lowest visible point of the content is offset + top inset + that height.
            let visibleBottom = geometry.contentOffset.y + geometry.contentInsets.top + geometry.containerSize.height
            return ScrollFacts(nearBottom: geometry.contentSize.height - visibleBottom < 120,
                               contentHeight: geometry.contentSize.height.rounded(),
                               visibleHeight: geometry.containerSize.height.rounded(),
                               bottomInset: geometry.contentInsets.bottom.rounded())
        } action: { old, new in
            if atBottom != new.nearBottom { atBottom = new.nearBottom }
            if phase == .interacting || phase == .decelerating {
                if pinned != new.nearBottom { pinned = new.nearBottom } // scrolled up to read, or back down
                return
            }
            if new.nearBottom && !pinned { pinned = true }
            guard pinned, new.sizeChanged(from: old) else { return }
            // An error card, a taller composer, the keyboard, a picture, a voice note or the support card took
            // space while nobody was scrolling: stay with the newest message. Being near the bottom isn't
            // enough, since even a short banner would cover the last bubble.
            if phase == .idle { position.scrollTo(edge: .bottom) } else { followAfterAnimation = true }
        }
        .onScrollPhaseChange { _, newPhase in
            phase = newPhase
            guard newPhase == .idle else { return }
            // Content can grow during an animated scroll; finish at the newest message.
            if pinned, followAfterAnimation || !atBottom { position.scrollTo(edge: .bottom) }
            followAfterAnimation = false
        }
        .onChange(of: controller.supportRequests) {
            // "Get support" from the menu: the card is now after the last message.
            pinned = true
            withAnimation(.smooth(duration: 0.3)) { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: messages.count) { old, new in
            guard new > old else { return }
            // The user's own new message always brings them back down.
            if messages.last?.role == .user { pinned = true }
            if pinned { withAnimation(.smooth(duration: 0.3)) { position.scrollTo(edge: .bottom) } }
        }
        .onChange(of: controller.isReplying) { _, replying in
            if replying { followIfPinned() }
        }
        .overlay(alignment: .bottomTrailing) {
            if !pinned {
                Button {
                    pinned = true
                    withAnimation(.smooth(duration: 0.35)) { position.scrollTo(edge: .bottom) }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.hearthText)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .padding(.trailing, Spacing.l)
                .padding(.bottom, Spacing.s)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityLabel("Jump to latest")
            }
        }
        .animation(.snappy(duration: 0.25), value: pinned)
    }

    /// Keeps the newest text in view while a reply streams, unless the user scrolled up to read.
    private func followIfPinned() {
        if pinned { position.scrollTo(edge: .bottom) }
    }

    /// Index of the message the support card follows: the one that called for it, else the last message.
    private func supportCardIndex(in messages: [Message]) -> Int? {
        guard controller.safety != .none, !messages.isEmpty else { return nil }
        if let id = controller.supportAfterID, let index = messages.firstIndex(where: { $0.id == id }) { return index }
        return messages.count - 1
    }

    /// The support card in the conversation (it scrolls away like a message, so it never squeezes the chat).
    private var supportCard: some View {
        ChatSafetyCard(level: controller.safety) {
            withAnimation(.snappy) { controller.dismissSafety() }
        }
        .transition(.opacity)
        .onScrollVisibilityChange(threshold: 0.3) { visible in
            if supportCardVisible != visible { supportCardVisible = visible }
        }
        .onDisappear { supportCardVisible = false }
    }
}

/// What the list needs to know about its scroll position (changes only when one of these does).
private struct ScrollFacts: Equatable {
    var nearBottom: Bool
    /// Sizes that change when something grows or the bars move, not when the user scrolls.
    var contentHeight: CGFloat
    var visibleHeight: CGFloat
    var bottomInset: CGFloat

    func sizeChanged(from old: ScrollFacts) -> Bool {
        contentHeight != old.contentHeight || visibleHeight != old.visibleHeight || bottomInset != old.bottomInset
    }
}

/// The top of every chat: who this is, like the start of a Character.AI conversation.
private struct ChatIntroHeader: View {
    let character: Character

    var body: some View {
        VStack(spacing: 6) {
            AvatarView(character.avatar, size: 72)
                .padding(.bottom, Spacing.xs)
            Text(character.name)
                .font(HearthFont.title(24))
                .foregroundStyle(.hearthText)
            Text(character.tagline)
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(ChatPipeline.byLine(character.creator))
                .font(HearthFont.caption)
                .foregroundStyle(.hearthMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One message

private struct ChatMessageRow: View {
    let message: Message
    let character: Character
    let controller: ChatController
    let showsTime: Bool
    let isLastReply: Bool
    let isGreeting: Bool
    let onEdit: (Message) -> Void
    let onOpenPicture: (ChatPictureViewer.Item) -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if showsTime {
                Text(ChatPipeline.timeLabel(for: message.createdAt))
                    .font(HearthFont.small)
                    .foregroundStyle(.hearthMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Spacing.xs)
            }
            switch message.role {
            case .narrator:
                ChatNote(text: message.text)
            case .user:
                ChatUserMessage(message: message, controller: controller, onOpenPicture: onOpenPicture)
                    .contextMenu { menu }
            case .character:
                ChatCharacterMessage(message: message, character: character, controller: controller,
                                     isLastReply: isLastReply, isGreeting: isGreeting, onOpenPicture: onOpenPicture)
                    .contextMenu { menu }
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        let isSpeakingThis = app.voice.nowPlayingMessageID == message.id && app.voice.isSpeaking
        Section("Sent \(ChatPipeline.timeLabel(for: message.createdAt))") {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = message.text.isEmpty ? (message.attachment?.caption ?? "") : message.text
            }
            Button("Edit", systemImage: "pencil") { onEdit(message) }
            if message.role == .character || ChatPipeline.playableVoice(message) != nil {
                Button(isSpeakingThis ? "Stop" : "Play aloud", systemImage: isSpeakingThis ? "stop.fill" : "speaker.wave.2") {
                    controller.play(messageID: message.id)
                }
            }
            if message.pinned {
                Button("Forget this", systemImage: "pin.slash") { controller.unpin(messageID: message.id) }
            } else {
                Button("Remember this", systemImage: "pin") { controller.pin(messageID: message.id) }
            }
            if isLastReply && !isGreeting {
                Button("Regenerate", systemImage: "arrow.clockwise") { Task { await controller.regenerate() } }
                    .disabled(!controller.canSend)
            }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { controller.delete(messageID: message.id) }
            .disabled(controller.isReplying)
    }
}

/// A quiet note from the app (for example when a model declined to answer). Never sent to the model.
private struct ChatNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(HearthFont.caption)
            .foregroundStyle(.hearthMuted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(Color.hearthSurface.opacity(0.7), in: Capsule())
            .frame(maxWidth: .infinity)
    }
}

// MARK: - The user's messages

private struct ChatUserMessage: View {
    let message: Message
    let controller: ChatController
    let onOpenPicture: (ChatPictureViewer.Item) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let photo = message.attachment, photo.kind == .photo {
                ChatPhotoBubble(attachment: photo) {
                    if let file = photo.file { onOpenPicture(.init(file: file, caption: nil, canSave: false)) }
                }
            }
            if let voice = ChatPipeline.playableVoice(message) {
                ChatVoiceBubble(message: message, attachment: voice, isUser: true) { controller.play(messageID: message.id) }
            } else if !message.text.isEmpty {
                Text(ChatMarkup.attributed(message.text, actionColor: .hearthText2))
                    .font(HearthFont.body)
                    .foregroundStyle(.hearthText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.hearthSurface2, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
                    .accessibilityLabel("You: \(ChatMarkup.plain(message.text))")
            }
            if message.pinned { ChatPinnedTag() }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 44)
    }
}

// MARK: - The character's messages

/// Avatar on the left, name above, then the content. Used for messages and for the reply being written.
private struct ChatCharacterLine<Content: View>: View {
    let character: Character
    var pinned = false
    @ViewBuilder let content: () -> Content
    @Environment(Router.self) private var router

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { router.open(.profile(characterID: character.id)) } label: {
                AvatarView(character.avatar, size: 32)
            }
            .buttonStyle(.pressable)
            .accessibilityHidden(true) // the chat header opens the profile too

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(character.name)
                        .font(HearthFont.caption.weight(.semibold))
                        .foregroundStyle(.hearthText2)
                    if pinned { ChatPinnedTag() }
                }
                .accessibilityHidden(true)
                content()
            }
            Spacer(minLength: 24)
        }
    }
}

private struct ChatCharacterMessage: View {
    let message: Message
    let character: Character
    let controller: ChatController
    let isLastReply: Bool
    let isGreeting: Bool
    let onOpenPicture: (ChatPictureViewer.Item) -> Void

    @Environment(AppModel.self) private var app
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        let isRewriting = controller.regeneratingID == message.id
        ChatCharacterLine(character: character, pinned: message.pinned) {
            Group {
                if isRewriting {
                    ChatLiveText(controller: controller, character: character, onGrow: {})
                } else {
                    content
                }
            }
            .offset(x: dragOffset)

            if isLastReply && !isRewriting {
                ChatReplyControls(message: message, controller: controller, isGreeting: isGreeting)
                if app.settings.showEngineStats, let stats = message.stats {
                    Text(ChatPipeline.statsLine(stats))
                        .font(HearthFont.small.monospacedDigit())
                        .foregroundStyle(.hearthMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(swipe, isEnabled: isLastReply && !controller.isReplying)
        .accessibilityActions {
            if isLastReply {
                Button("Next reply") { Task { await controller.showAlternate(delta: 1) } }
                Button("Previous reply") { Task { await controller.showAlternate(delta: -1) } }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let voice = ChatPipeline.playableVoice(message)
        if let voice {
            ChatVoiceBubble(message: message, attachment: voice, isUser: false, senderName: character.name) {
                controller.play(messageID: message.id)
            }
        } else if !message.text.isEmpty {
            Text(ChatMarkup.attributed(message.text, actionColor: .hearthText2))
                .font(HearthFont.body)
                .foregroundStyle(.hearthText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("\(character.name): \(ChatMarkup.plain(message.text))")
        }
        if message.stats?.engine == "mock" {
            // Canned lines from the demo engine (Simulator and test runs) never pass for the character's own words.
            Label("Demo reply, a canned line with no AI", systemImage: "theatermasks")
                .font(HearthFont.small)
                .foregroundStyle(.hearthMuted)
        }
        if let attachment = message.attachment {
            switch (attachment.kind, attachment.status) {
            case (.picture, .pending):
                ChatDrawingPlaceholder()
            case (.picture, .ready):
                if let file = attachment.file {
                    ChatPictureBubble(file: file, caption: attachment.caption) {
                        onOpenPicture(.init(file: file, caption: attachment.caption, canSave: true))
                    }
                }
            case (.picture, .failed):
                Label("The picture didn't come out this time.", systemImage: "photo")
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthMuted)
            case (.voice, .pending) where voice == nil:
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Recording a voice note…")
                }
                .font(HearthFont.caption)
                .foregroundStyle(.hearthMuted)
            default:
                EmptyView()
            }
        }
    }

    /// Swipe left for the next alternate (a new one past the end), right for the previous one.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) * 1.5 else { return }
                dragOffset = max(-60, min(60, dx * 0.35))
            }
            .onEnded { value in
                let dx = value.translation.width
                withAnimation(.snappy(duration: 0.25)) { dragOffset = 0 }
                guard abs(dx) > 70, abs(dx) > abs(value.translation.height) * 1.5 else { return }
                Task { await controller.showAlternate(delta: dx < 0 ? 1 : -1) }
            }
    }
}

/// "‹ 2/3 ›", the stars and regenerate, under the last reply.
private struct ChatReplyControls: View {
    let message: Message
    let controller: ChatController
    let isGreeting: Bool
    @Environment(AppModel.self) private var app

    var body: some View {
        // One row when it fits; with very large text the stars move to a second row.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                alternates
                Spacer(minLength: Spacing.s)
                rating
            }
            VStack(alignment: .leading, spacing: 0) {
                alternates
                rating
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.hearthText2)
        .buttonStyle(.plain)
        .padding(.leading, -12) // line the first arrow up with the text
        .sensoryFeedback(.selection, trigger: message.selected) { _, _ in app.settings.haptics }
    }

    @ViewBuilder
    private var alternates: some View {
        let count = message.variants.count
        let selected = min(message.selected, max(0, count - 1))
        if count > 1 || !isGreeting {
            HStack(spacing: 0) {
                Button { Task { await controller.showAlternate(delta: -1) } } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .disabled(selected == 0 || controller.isReplying)
                .accessibilityLabel("Previous reply")

                Text("\(selected + 1)/\(count)")
                    .font(HearthFont.caption.monospacedDigit())
                    .foregroundStyle(.hearthText2)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .fixedSize()
                    .accessibilityLabel("Reply \(selected + 1) of \(count)")

                Button { Task { await controller.showAlternate(delta: 1) } } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .disabled(selected >= count - 1 && (isGreeting || !controller.canSend))
                .accessibilityLabel(selected >= count - 1 ? "Write another reply" : "Next reply")
            }
        }
    }

    @ViewBuilder
    private var rating: some View {
        if !isGreeting {
            HStack(spacing: 0) {
                StarRatingView(rating: Binding(get: { message.rating },
                                               set: { controller.rate(messageID: message.id, stars: $0) }))
                    .sensoryFeedback(.selection, trigger: message.rating) { _, _ in app.settings.haptics }
                Button { Task { await controller.regenerate() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .disabled(!controller.canSend)
                .accessibilityLabel("Regenerate reply")
            }
        }
    }
}

/// The reply being written: typing dots until the first words arrive, then the live text.
private struct ChatPendingReply: View {
    let controller: ChatController
    let character: Character
    let onGrow: () -> Void

    var body: some View {
        ChatCharacterLine(character: character) {
            ChatLiveText(controller: controller, character: character, onGrow: onGrow)
        }
    }
}

/// Reads `streamingText` in its own view, so only this part redraws for every new word.
private struct ChatLiveText: View {
    let controller: ChatController
    let character: Character
    let onGrow: () -> Void

    var body: some View {
        let text = controller.streamingText ?? ""
        Group {
            if text.isEmpty {
                TypingIndicator()
                    .accessibilityLabel("\(character.name) is writing")
            } else {
                Text(ChatMarkup.attributed(text, actionColor: .hearthText2))
                    .font(HearthFont.body)
                    .foregroundStyle(.hearthText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(character.name): \(ChatMarkup.plain(text))")
            }
        }
        .onChange(of: text) { onGrow() }
    }
}

/// A small "Remembered" tag on pinned messages.
private struct ChatPinnedTag: View {
    var body: some View {
        Label("Remembered", systemImage: "pin.fill")
            .labelStyle(.iconOnly)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.hearthGold)
            .accessibilityLabel("Remembered")
    }
}
