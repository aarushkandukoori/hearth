// The message box under a chat: a photo button, a field that grows to five lines, and one round
// button that is Send when there is text, Stop while the character writes, and otherwise a mic you
// hold to record a voice message (slide left to cancel). Speech is recognized on this iPhone only.

import PhotosUI
import SwiftUI

struct ChatComposer: View {
    let controller: ChatController
    let character: Character

    @Environment(AppModel.self) private var app
    @State private var draft = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var recording = false
    @State private var cancelArmed = false
    @State private var waitingOnDictation = false
    @State private var problem: DictationProblem?
    @GestureState private var pressing = false
    @FocusState private var focused: Bool

    private struct DictationProblem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            photoButton
            Group {
                if recording { recordingStrip } else { field }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            trailingButton
        }
        .padding(5)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 27, style: .continuous))
        .animation(.snappy(duration: 0.2), value: recording)
        .onChange(of: photoItem) { _, item in
            if let item { sendPhoto(item) }
        }
        .onChange(of: pressing) { _, isPressing in
            if isPressing {
                startRecording()
            } else if recording {
                if cancelArmed { cancelRecording() } else { finishRecording() }
            }
        }
        .onChange(of: app.dictation.state) { _, state in noticeProblem(state) }
        .alert(problem?.title ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } }),
               presenting: problem) { _ in
            Button("OK", role: .cancel) {}
        } message: { problem in
            Text(problem.message + "\n\nYou can still type to \(character.name).")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: recording) { _, isOn in isOn && app.settings.haptics }
        .onDisappear {
            if recording { cancelRecording() }
        }
    }

    // MARK: Pieces

    private var field: some View {
        TextField("Message \(character.name)…", text: $draft, axis: .vertical)
            .font(HearthFont.body)
            .foregroundStyle(.hearthText)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .focused($focused)
            .padding(.horizontal, 6)
            .padding(.vertical, 11)
    }

    private var photoButton: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.hearthText2)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!controller.canSend || recording)
        .opacity(recording ? 0 : 1)
        .accessibilityLabel("Send a photo")
    }

    @ViewBuilder
    private var trailingButton: some View {
        if controller.isReplying && !recording {
            Button { controller.stop() } label: {
                round(symbol: "stop.fill", fill: .hearthSurface2, tint: .hearthText)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Stop")
        } else if !trimmed.isEmpty && !recording {
            Button(action: send) {
                round(symbol: "arrow.up", fill: .hearthAccent, tint: .hearthOnAccent)
            }
            .buttonStyle(.pressable)
            .disabled(!controller.canSend)
            .accessibilityLabel("Send")
        } else {
            micButton
        }
    }

    private func round(symbol: String, fill: Color, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .background(fill, in: Circle())
    }

    private var micButton: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(recording ? Color.white : Color.hearthText2)
            .frame(width: 44, height: 44)
            .background(recording ? (cancelArmed ? Color.hearthMuted : Color.hearthDanger) : Color.clear, in: Circle())
            .scaleEffect(recording ? 1.12 : 1)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { _, state, _ in state = true }
                    .onChanged { value in
                        cancelArmed = value.translation.width < -80 || value.translation.height < -110
                    }
            )
            .opacity(controller.canSend || recording ? 1 : 0.45)
            .allowsHitTesting(controller.canSend || recording)
            .accessibilityElement()
            .accessibilityLabel(recording ? "Send voice message" : "Record a voice message")
            .accessibilityHint("Hold to record and let go to send. With VoiceOver, double-tap to start and again to send.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if recording { finishRecording() } else { startRecording() }
            }
    }

    private var recordingStrip: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.s) {
                ChatLevelMeter(level: app.dictation.level, armed: cancelArmed)
                Text(cancelArmed ? "Let go to cancel" : "Slide left to cancel")
                    .font(HearthFont.small)
                    .foregroundStyle(cancelArmed ? Color.hearthDanger : Color.hearthMuted)
            }
            Text(app.dictation.transcript.isEmpty ? "Listening…" : app.dictation.transcript)
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText)
                .lineLimit(2)
                .truncationMode(.head)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: Actions

    private func send() {
        let text = trimmed
        guard !text.isEmpty, controller.canSend else { return }
        draft = ""
        Task { await controller.send(text: text) }
    }

    private func sendPhoto(_ item: PhotosPickerItem) {
        photoItem = nil
        let caption = draft
        draft = ""
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                if draft.isEmpty { draft = caption }
                controller.notice = "That photo couldn't be opened. Try a different one."
                return
            }
            let sent = await controller.sendPhoto(data, caption: caption)
            if !sent, draft.isEmpty { draft = caption }
        }
    }

    private func startRecording() {
        guard !recording, controller.canSend else { return }
        focused = false
        app.voice.stop() // never record over the character talking
        recording = true
        cancelArmed = false
        waitingOnDictation = true
        Task { await app.dictation.start() }
    }

    private func cancelRecording() {
        recording = false
        cancelArmed = false
        waitingOnDictation = false
        app.dictation.cancel()
    }

    private func finishRecording() {
        guard recording else { return }
        recording = false
        cancelArmed = false
        let wasAsking = app.dictation.state == .requestingPermission
        Task {
            let result = await app.dictation.stop()
            waitingOnDictation = false
            guard let attachment = result.attachment else {
                if !wasAsking, app.dictation.state == .idle {
                    controller.notice = "Hold the mic a little longer to record."
                }
                return
            }
            guard !result.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                ChatController.removeMediaFile(attachment.file)
                controller.notice = "Hearth couldn't make out any words. Try again a little closer to the mic."
                return
            }
            await controller.sendVoice(attachment)
        }
    }

    /// Dictation never falls back to a server, so when it can't run here we explain instead.
    private func noticeProblem(_ state: Dictation.State) {
        guard waitingOnDictation else { return }
        switch state {
        case .unavailable(let message):
            problem = DictationProblem(title: "Voice messages stay on this iPhone", message: message)
        case .failed(let message):
            problem = DictationProblem(title: "Hearth couldn't listen", message: message)
        default:
            return
        }
        recording = false
        cancelArmed = false
        waitingOnDictation = false
    }
}

/// Five small bars that follow the microphone level while recording.
private struct ChatLevelMeter: View {
    let level: Float
    let armed: Bool
    private static let weights: [CGFloat] = [0.45, 0.75, 1, 0.75, 0.45]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .fill(armed ? Color.hearthMuted : Color.hearthDanger)
                    .frame(width: 3, height: 5 + 15 * CGFloat(min(max(level, 0), 1)) * Self.weights[index])
            }
        }
        .frame(height: 22)
        .animation(.smooth(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}
