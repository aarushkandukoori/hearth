// Character voices: a distinct system voice per resident, live speech (whole messages or sentence
// by sentence while a reply streams), voice notes rendered to files, and playback with progress.

import AVFoundation
import Observation

@MainActor @Observable final class VoiceStudio {
    /// The message whose audio is playing or paused. nil when nothing is.
    private(set) var nowPlayingMessageID: UUID?
    /// 0...1 through the current voice note or spoken message.
    private(set) var playbackProgress: Double = 0
    /// True while sound is coming out (live speech or a voice note); false when paused or idle.
    private(set) var isSpeaking = false
    /// True while paused partway. nowPlayingMessageID and playbackProgress stay set.
    private(set) var isPaused = false
    /// Installed voices for the picker: English first, best quality first, novelty voices removed.
    private(set) var availableVoices: [VoiceOption] = []
    /// Loudness 0...1 for live speech and new voice notes.
    @ObservationIgnored var volume: Float = 1

    @ObservationIgnored private var candidates: [VoiceCandidate] = []
    @ObservationIgnored private var cast: [Character] = []
    @ObservationIgnored private var castVoices: [String: String] = [:]
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let events = SpeechEvents()
    /// Utterances handed to the synthesizer that haven't finished yet.
    @ObservationIgnored private var pending: [ObjectIdentifier: AVSpeechUtterance] = [:]
    /// The utterance whose progress drives playbackProgress (the one speak() started).
    @ObservationIgnored private var tracked: ObjectIdentifier?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var deactivation: Task<Void, Never>?

    init() {
        events.owner = self
        synthesizer.delegate = events
        Task { await self.refreshVoices() }
    }

    // MARK: Voices

    /// Re-reads installed voices off the main thread (it takes ~0.1 s). Runs at launch; call it again
    /// when the voice picker appears, since people can download voices in Settings.
    func refreshVoices() async {
        let loaded = await Task.detached(priority: .utility) {
            AVSpeechSynthesisVoice.speechVoices().map(VoiceCandidate.init)
        }.value
        candidates = loaded
        availableVoices = VoiceRanking.ranked(loaded).map(\.option)
        assignCastVoices()
    }

    /// Recommended at launch and whenever characters change: gives the whole cast distinct voices
    /// (pass built-in residents first, then the user's own). Without it each character still gets a
    /// stable voice of its own, but two may share one.
    func assignDistinctVoices(for cast: [Character]) {
        self.cast = cast
        assignCastVoices()
    }

    /// The user's override (settings.voiceOverrides) wins, then the cast assignment, then a stable pick.
    func voice(for c: Character, overrides: [String: String]) -> AVSpeechSynthesisVoice? {
        if candidates.isEmpty {  // asked before the launch-time load finished
            candidates = AVSpeechSynthesisVoice.speechVoices().map(VoiceCandidate.init)
        }
        if let id = overrides[c.id], let voice = AVSpeechSynthesisVoice(identifier: id) { return voice }
        if let id = castVoices[c.id], let voice = AVSpeechSynthesisVoice(identifier: id) { return voice }
        if let pick = VoiceRanking.pick(for: c.voice, characterID: c.id, from: candidates),
           let voice = AVSpeechSynthesisVoice(identifier: pick.identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: c.voice.locale ?? "en-US")
    }

    // MARK: Live speech

    /// Says a whole message now, interrupting anything playing. Same paused message: resumes.
    func speak(_ text: String, as c: Character, overrides: [String: String], messageID: UUID?) {
        if let messageID, messageID == nowPlayingMessageID, isPaused, player == nil {
            resume()
            return
        }
        stop()
        let spoken = Self.spokenText(text)
        guard !spoken.isEmpty else { return }
        let utterance = spec(for: spoken, as: c, overrides: overrides).makeUtterance()
        activateSession()
        pending[ObjectIdentifier(utterance)] = utterance
        tracked = ObjectIdentifier(utterance)
        nowPlayingMessageID = messageID
        playbackProgress = 0
        isSpeaking = true
        isPaused = false
        synthesizer.speak(utterance)
    }

    /// Queues one sentence after whatever is already being said (for replies that are still
    /// streaming, see `splitSentences`). Stops a voice note if one is playing.
    func enqueueSpoken(_ sentence: String, as c: Character, overrides: [String: String], messageID: UUID? = nil) {
        let spoken = Self.spokenText(sentence)
        guard !spoken.isEmpty else { return }
        if player != nil { stop() }
        let utterance = spec(for: spoken, as: c, overrides: overrides).makeUtterance()
        activateSession()
        if pending.isEmpty {
            tracked = nil
            playbackProgress = 0
        }
        pending[ObjectIdentifier(utterance)] = utterance
        if let messageID { nowPlayingMessageID = messageID }
        isSpeaking = !isPaused
        synthesizer.speak(utterance)
    }

    /// Stops all speech and playback right away.
    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        player?.stop()
        resetToIdle()
    }

    // MARK: Voice notes

    /// Renders a character's line to media/voice/<uuid>.m4a without playing it.
    /// The attachment's caption is the original text (the transcript the chat shows).
    func renderVoiceNote(_ text: String, as c: Character, overrides: [String: String]) async throws -> Attachment {
        let spoken = Self.spokenText(text)
        guard !spoken.isEmpty else { throw VoiceNoteError.nothingToSay }
        let started = Date()
        let writer = SpeechFileWriter(base: MediaFiles.newBase(in: .voice))
        let rendered = try await writer.render(spec(for: spoken, as: c, overrides: overrides),
                                               timeout: 8 + Double(spoken.count) / 6)
        MediaFiles.protect(rendered.url)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        HearthLog.info("voice", "voice note \(String(format: "%.1f", rendered.duration)) s rendered in \(elapsed) ms")
        return Attachment(kind: .voice, file: MediaFiles.relativePath(of: rendered.url, in: .voice),
                          caption: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          duration: rendered.duration, status: .ready, waveform: rendered.waveform)
    }

    /// Plays a voice note (a character's or the user's). Same paused message: resumes.
    func play(_ a: Attachment, messageID: UUID) {
        if messageID == nowPlayingMessageID, isPaused, player != nil {
            resume()
            return
        }
        stop()
        guard let file = a.file else { return }
        do {
            activateSession()
            let player = try AVAudioPlayer(contentsOf: HearthPaths.mediaURL(file))
            player.prepareToPlay()
            guard player.play() else { throw VoiceNoteError.playbackFailed }
            self.player = player
            nowPlayingMessageID = messageID
            playbackProgress = 0
            isSpeaking = true
            isPaused = false
            startProgressLoop()
        } catch {
            HearthLog.error("voice", "voice note playback failed (\((error as NSError).code))")
            resetToIdle()
        }
    }

    /// Play/pause button for a voice-note bubble.
    func togglePlayback(_ a: Attachment, messageID: UUID) {
        if messageID == nowPlayingMessageID, isSpeaking {
            pause()
        } else {
            play(a, messageID: messageID)
        }
    }

    func pause() {
        if let player, player.isPlaying {
            player.pause()
        } else if synthesizer.isSpeaking, !synthesizer.isPaused {
            synthesizer.pauseSpeaking(at: .word)
        } else {
            return
        }
        isPaused = true
        isSpeaking = false
    }

    func resume() {
        guard isPaused else { return }
        activateSession()
        if let player {
            player.play()
            startProgressLoop()
        } else {
            synthesizer.continueSpeaking()
        }
        isPaused = false
        isSpeaking = true
    }

    // MARK: Private

    private func assignCastVoices() {
        guard !cast.isEmpty, !candidates.isEmpty else { return }
        castVoices = VoiceRanking.distinctAssignment(for: cast, from: candidates)
        HearthLog.info("voice", "\(castVoices.count) characters share \(Set(castVoices.values).count) voices")
    }

    private func spec(for spoken: String, as c: Character, overrides: [String: String]) -> SpeechSpec {
        SpeechSpec(text: spoken, voiceIdentifier: voice(for: c, overrides: overrides)?.identifier,
                   pitch: min(2, max(0.5, c.voice.pitch)), rate: Self.speechRate(for: c.voice.rate),
                   volume: min(1, max(0, volume)))
    }

    /// VoiceStyle.rate uses AVSpeechUtterance's scale (0.5 = normal); kept in a comfortable range.
    nonisolated static func speechRate(for styleRate: Float) -> Float {
        min(0.62, max(0.32, styleRate))
    }

    private func startProgressLoop() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let player = self.player else { return }
                if player.isPlaying {
                    self.playbackProgress = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
                } else if !self.isPaused {
                    self.resetToIdle()  // reached the end
                    return
                }
            }
        }
    }

    fileprivate func speechProgressed(_ id: ObjectIdentifier, to progress: Double) {
        guard id == tracked else { return }
        playbackProgress = min(1, max(playbackProgress, progress))
    }

    fileprivate func speechEnded(_ id: ObjectIdentifier) {
        guard pending.removeValue(forKey: id) != nil else { return }
        if pending.isEmpty { resetToIdle() }
    }

    private func resetToIdle() {
        progressTask?.cancel()
        progressTask = nil
        player = nil
        pending.removeAll()
        tracked = nil
        nowPlayingMessageID = nil
        playbackProgress = 0
        isSpeaking = false
        isPaused = false
        deactivateSessionSoon()
    }

    private func activateSession() {
        deactivation?.cancel()
        #if os(iOS)
        guard !MediaSession.isRecording else { return }  // Dictation's session can play too
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
    }

    /// Hands audio back to other apps (music un-ducks) a moment after Hearth goes quiet. The pause
    /// matters: deactivating while the synthesizer is still stopping fails and leaves music ducked.
    private func deactivateSessionSoon() {
        #if os(iOS)
        deactivation?.cancel()
        deactivation = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, self.pending.isEmpty, self.player == nil, !MediaSession.isRecording else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }
}

/// Forwards AVSpeechSynthesizer callbacks (which arrive off the main actor) to VoiceStudio.
/// `owner` is set once, right after init, before any speech starts.
private final class SpeechEvents: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    weak var owner: VoiceStudio?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        let progress = Double(characterRange.location + characterRange.length) / Double(max(1, utterance.speechString.utf16.count))
        let owner = self.owner
        Task { @MainActor in owner?.speechProgressed(id, to: progress) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        let owner = self.owner
        Task { @MainActor in owner?.speechEnded(id) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        let owner = self.owner
        Task { @MainActor in owner?.speechEnded(id) }
    }
}
