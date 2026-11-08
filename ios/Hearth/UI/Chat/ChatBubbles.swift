// Media inside chat messages: voice notes (play, waveform, transcript), pictures characters send,
// photos the user sends, the "Drawing…" placeholder, and a full-screen viewer with Share and Save.

import Photos
import SwiftUI

/// A voice note bubble for either side. Playback state comes from VoiceStudio.
struct ChatVoiceBubble: View {
    let message: Message
    let attachment: Attachment
    let isUser: Bool
    /// Who sent it, so VoiceOver can say "Juno's voice note" (the person's own are "your voice message").
    var senderName = ""
    let onPlay: () -> Void
    @Environment(AppModel.self) private var app
    @State private var showsTranscript = false

    private var spokenName: String {
        if isUser { return "your voice message" }
        return senderName.isEmpty ? "voice note" : "\(senderName)'s voice note"
    }

    var body: some View {
        let isCurrent = app.voice.nowPlayingMessageID == message.id
        let isPlaying = isCurrent && app.voice.isSpeaking
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.hearthOnAccent)
                        .frame(width: 44, height: 44)
                        .background(Color.hearthAccent, in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(isPlaying ? "Pause \(spokenName)" : "Play \(spokenName)")
                .accessibilityValue(ChatPipeline.durationLabel(attachment.duration ?? 0))

                ChatVoiceWave(messageID: message.id, samples: attachment.waveform ?? [], isCurrent: isCurrent)
                    .frame(height: 28)
                    .frame(minWidth: 90, maxWidth: 170)

                Text(ChatPipeline.durationLabel(attachment.duration ?? 0))
                    .font(HearthFont.caption.monospacedDigit())
                    .foregroundStyle(.hearthText2)
                    .accessibilityHidden(true)
            }

            let transcript = isUser ? (attachment.caption ?? message.text) : message.text
            if !transcript.isEmpty {
                Button {
                    withAnimation(.snappy) { showsTranscript.toggle() }
                } label: {
                    Text(showsTranscript ? "Hide transcript" : "Show transcript")
                        .font(HearthFont.caption.weight(.semibold))
                        .foregroundStyle(.hearthText2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showsTranscript {
                    Text(ChatMarkup.attributed(transcript, actionColor: .hearthText2))
                        .font(HearthFont.body)
                        .foregroundStyle(.hearthText)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, 10)
        .background(isUser ? Color.hearthSurface2 : Color.hearthSurface,
                    in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
        .overlay {
            if !isUser {
                RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous)
                    .strokeBorder(Color.hearthLine.opacity(0.8), lineWidth: 1)
            }
        }
    }
}

/// The waveform reads playback progress only for the note that is playing, so other bubbles stay still.
private struct ChatVoiceWave: View {
    let messageID: UUID
    let samples: [Float]
    let isCurrent: Bool
    @Environment(AppModel.self) private var app

    var body: some View {
        WaveformView(samples: samples, progress: isCurrent ? app.voice.playbackProgress : 0, tint: .hearthAccent)
    }
}

/// A picture a character sent (Image Playground, bundled art or a postcard). Tap to see it big.
struct ChatPictureBubble: View {
    let file: String
    let caption: String?
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onOpen) {
                MediaImage(relativePath: file, contentMode: .fill)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 260)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous)
                        .strokeBorder(Color.hearthLine.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(caption.map { "Picture of \($0)" } ?? "Picture")
            .accessibilityHint("Opens the picture full screen")

            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthMuted)
                    .lineLimit(3)
                    .frame(maxWidth: 260, alignment: .leading)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A photo the user sent, shown at its own shape.
struct ChatPhotoBubble: View {
    let attachment: Attachment
    let onOpen: () -> Void

    var body: some View {
        if attachment.status == .pending || attachment.file == nil {
            RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous)
                .fill(Color.hearthSurface2)
                .frame(width: 200, height: 150)
                .overlay { ProgressView().tint(.hearthText2) }
                .accessibilityLabel("Sending your photo")
        } else if let file = attachment.file {
            Button(action: onOpen) {
                MediaImage(relativePath: file, contentMode: .fit)
                    .frame(maxWidth: 240, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Your photo")
            .accessibilityHint("Opens the photo full screen")
        }
    }
}

/// Shown while a picture is being drawn on this iPhone.
struct ChatDrawingPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous)
        shape
            .fill(Color.hearthSurface2)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 240)
            .overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                        LinearGradient(colors: [.clear, Color.hearthGold.opacity(0.16), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: width * 0.6)
                            .offset(x: reduceMotion ? width * 0.2 : -width * 0.6 + phase * width * 1.6)
                    }
                }
                .clipShape(shape)
            }
            .overlay {
                VStack(spacing: Spacing.s) {
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(.title2)
                        .foregroundStyle(.hearthGold)
                    Text("Drawing…")
                        .font(HearthFont.callout.weight(.semibold))
                        .foregroundStyle(.hearthText2)
                }
            }
            .overlay(shape.strokeBorder(Color.hearthLine.opacity(0.6), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Drawing a picture")
    }
}

/// Full-screen view of a picture or photo, with pinch to zoom (it stays zoomed), drag to look around while
/// zoomed, double-tap to zoom in or back out, Share and (for pictures) Save to Photos.
struct ChatPictureViewer: View {
    struct Item: Identifiable {
        let id = UUID()
        let file: String
        let caption: String?
        /// A character's picture can be saved to Photos; the user's own photo is already there.
        let canSave: Bool
    }

    let item: Item
    @Environment(\.dismiss) private var dismiss
    /// Zoom and pan once the fingers lift; the gesture states hold what is happening right now.
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    @State private var toast: String?
    @State private var saving = false

    private static let maxZoom: CGFloat = 4

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                GeometryReader { proxy in
                    MediaImage(relativePath: item.file, contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(min(Self.maxZoom, max(1, zoom * pinch)))
                        .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                        .gesture(
                            MagnifyGesture()
                                .updating($pinch) { value, state, _ in state = value.magnification }
                                .onEnded { value in
                                    zoom = min(Self.maxZoom, max(1, zoom * value.magnification))
                                    withAnimation(.snappy) { offset = clamped(offset, zoom: zoom, in: proxy.size) }
                                }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .updating($drag) { value, state, _ in state = value.translation }
                                .onEnded { value in
                                    let moved = CGSize(width: offset.width + value.translation.width,
                                                       height: offset.height + value.translation.height)
                                    withAnimation(.snappy) { offset = clamped(moved, zoom: zoom, in: proxy.size) }
                                },
                            isEnabled: zoom > 1
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.snappy) {
                                zoom = zoom > 1 ? 1 : 2
                                offset = .zero
                            }
                        }
                        .accessibilityLabel(item.caption.map { "Picture of \($0)" } ?? "Picture")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let caption = item.caption, !caption.isEmpty {
                    Text(caption)
                        .font(HearthFont.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.xl)
                        .padding(.bottom, Spacing.l)
                        .accessibilityHidden(true)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: HearthPaths.mediaURL(item.file)) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share")
                    if item.canSave {
                        Button { Task { await save() } } label: { Image(systemName: "square.and.arrow.down") }
                            .disabled(saving)
                            .accessibilityLabel("Save to Photos")
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .hearthToast($toast)
        }
        .environment(\.colorScheme, .dark)
    }

    /// Keeps a zoomed picture from being dragged in past the edges of the screen.
    private func clamped(_ offset: CGSize, zoom: CGFloat, in size: CGSize) -> CGSize {
        let limitX = size.width * (zoom - 1) / 2
        let limitY = size.height * (zoom - 1) / 2
        return CGSize(width: min(limitX, max(-limitX, offset.width)), height: min(limitY, max(-limitY, offset.height)))
    }

    /// Asks only for add-only access: Hearth can put the picture in Photos but never read the library.
    private func save() async {
        saving = true
        defer { saving = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            toast = "Hearth can't add to Photos. You can allow it in Settings > Hearth > Photos."
            return
        }
        let url = HearthPaths.mediaURL(item.file)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
            }
            toast = "Saved to Photos"
        } catch {
            toast = "That picture couldn't be saved."
        }
    }
}
