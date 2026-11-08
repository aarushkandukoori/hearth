// Push-to-talk voice input: on-device speech recognition only (never the network), plus a
// recording of what was said, kept as the user's voice note. Problems come back as friendly states.

import AVFoundation
import Observation
import Speech

@MainActor @Observable final class Dictation {
    enum State: Equatable {
        case idle, requestingPermission, listening, finishing
        /// This iPhone can't do it at all (the message says why).
        case unavailable(String)
        /// Something the user can fix or retry (permission, a hiccup).
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Live words while listening; the final text after stop().
    private(set) var transcript = ""
    /// 0...1 microphone loudness for a live meter.
    private(set) var level: Float = 0

    static let onDeviceUnavailableMessage =
        "On-device speech isn't available on this iPhone, so Hearth won't send your voice anywhere."

    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var sink: DictationSink?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Bumped by stop()/cancel() so a start() still waiting on permission knows to give up.
    @ObservationIgnored private var attempt = 0

    var isListening: Bool { state == .listening }

    /// Hold-to-talk begins. Asks for Speech Recognition and Microphone permission the first time.
    func start() async {
        switch state {
        case .listening, .finishing, .requestingPermission: return
        default: break
        }
        attempt += 1
        let thisAttempt = attempt
        transcript = ""
        level = 0
        state = .requestingPermission
        let problem = await Self.requestPermissions()
        guard thisAttempt == attempt else { return }  // let go before the prompts were answered
        if let problem {
            state = problem
            return
        }
        guard let recognizer = Self.onDeviceRecognizer() else {
            state = .unavailable(Self.onDeviceUnavailableMessage)
            return
        }
        guard recognizer.isAvailable else {
            state = .failed("Speech recognition isn't ready on this iPhone right now. Please try again in a moment.")
            return
        }
        do {
            try begin(with: recognizer)
            state = .listening
            startPolling()
        } catch {
            HearthLog.error("dictation", "couldn't start (\((error as NSError).code))")
            teardown(deleteRecording: true)
            state = .failed(error is DictationError ? "Hearth couldn't find a microphone."
                                                    : "Hearth couldn't start listening. Please try again.")
        }
    }

    /// Let go: returns the final transcript and the recording as a voice note (nil if under half a
    /// second). The transcript can be empty when nothing was understood. If start() had failed, the
    /// .failed/.unavailable message stays up so the user can read it.
    func stop() async -> (transcript: String, attachment: Attachment?) {
        guard state == .listening, let engine, let sink else {
            if state == .requestingPermission { cancel() }  // let go before the prompts were answered
            return ("", nil)
        }
        state = .finishing
        pollTask?.cancel()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sink.endAudio()

        // On-device recognition usually settles well under a second after the audio ends.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let snapshot = sink.snapshot
            if snapshot.isFinal || snapshot.failed { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let text = sink.snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let recording = sink.closeRecording()

        var attachment: Attachment?
        if recording.duration >= 0.5, let url = recording.url {
            MediaFiles.protect(url)
            attachment = Attachment(kind: .voice, file: MediaFiles.relativePath(of: url, in: .voice),
                                    caption: text, duration: recording.duration, status: .ready,
                                    waveform: recording.waveform)
        }
        HearthLog.info("dictation", "\(String(format: "%.1f", recording.duration)) s, \(text.split(separator: " ").count) words")
        teardown(deleteRecording: attachment == nil)
        transcript = text
        level = 0
        state = .idle
        return (text, attachment)
    }

    /// Throws the recording away (also ends a start() that is still asking for permission).
    func cancel() {
        attempt += 1
        teardown(deleteRecording: true)
        transcript = ""
        level = 0
        state = .idle
    }

    // MARK: Private

    private func begin(with recognizer: SFSpeechRecognizer) throws {
        MediaSession.isRecording = true
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.noMicrophone }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true  // never the network
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        let sink = DictationSink(request: request, base: MediaFiles.newBase(in: .voice))
        self.recognizer = recognizer
        self.engine = engine
        self.sink = sink
        // format nil = whatever the mic delivers right now. Passing a format read a moment earlier
        // crashes if the route changes in between (say, AirPods connect).
        input.installTap(onBus: 0, bufferSize: 2048, format: nil, block: Self.tapBlock(into: sink))
        engine.prepare()
        try engine.start()
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(into: sink))
    }

    /// Copies what the audio thread and recognizer collected onto the main actor ~16 times a second.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.state == .listening, let sink = self.sink else { return }
                let snapshot = sink.snapshot
                self.level = snapshot.level
                if self.transcript != snapshot.text { self.transcript = snapshot.text }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    private func teardown(deleteRecording: Bool) {
        pollTask?.cancel()
        pollTask = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        task?.cancel()
        if let sink {
            sink.endAudio()
            let recording = sink.closeRecording()
            if deleteRecording, let url = recording.url { try? FileManager.default.removeItem(at: url) }
        }
        engine = nil
        task = nil
        sink = nil
        recognizer = nil
        if MediaSession.isRecording {
            MediaSession.isRecording = false
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }

    // These build closures outside the main actor on purpose: the audio thread and the recognizer
    // call them on their own queues, and they only touch the thread-safe sink.
    nonisolated private static func tapBlock(into sink: DictationSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.consume(buffer) }
    }

    nonisolated private static func resultHandler(into sink: DictationSink) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            sink.receive(text: result?.bestTranscription.formattedString, isFinal: result?.isFinal ?? false,
                         failed: error != nil)
        }
    }

    /// The user's own language if it can be recognized on-device, else US English, else nil.
    nonisolated static func onDeviceRecognizer() -> SFSpeechRecognizer? {
        for locale in [Locale.current, Locale(identifier: "en-US")] {
            if let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition {
                return recognizer
            }
        }
        return nil
    }

    /// nil when both permissions are granted, else the state to show.
    nonisolated private static func requestPermissions() async -> State? {
        switch await speechAuthorization() {
        case .authorized:
            break
        case .restricted:
            return .unavailable("Speech recognition is turned off on this iPhone, so Hearth can't listen.")
        default:
            return .failed("Hearth needs Speech Recognition to hear you. You can turn it on in Settings > Hearth. Your voice stays on this iPhone.")
        }
        guard await microphonePermission() else {
            return .failed("Hearth needs the microphone to hear you. You can turn it on in Settings > Hearth.")
        }
        return nil
    }

    nonisolated private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    nonisolated private static func microphonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }
}

enum DictationError: Error {
    case noMicrophone
}

/// Shared by the audio thread (consume), the recognizer (receive) and Dictation (snapshot).
/// Every field is guarded by `lock`.
final class DictationSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    /// Where the recording goes, without extension (the file is opened on the first buffer).
    private let base: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var fileFailed = false
    private var sampleRate: Double = 0
    private var waveform = WaveformBuilder(sampleRate: 48000)
    private var frames: Int64 = 0
    private var level: Float = 0
    private var text = ""
    private var isFinal = false
    private var failed = false
    private var ended = false

    init(request: SFSpeechAudioBufferRecognitionRequest, base: URL) {
        self.request = request
        self.base = base
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !ended, buffer.frameLength > 0 else { return }
        request.append(buffer)
        if file == nil, !fileFailed {
            // Opened here so the file always matches what the microphone really sends.
            do {
                let opened = try MediaFiles.makeAudioFile(at: base, for: buffer.format)
                file = opened
                fileURL = opened.url
                sampleRate = buffer.format.sampleRate
                waveform = WaveformBuilder(sampleRate: sampleRate)
            } catch {
                fileFailed = true
            }
        }
        if let file, (try? file.write(from: buffer)) != nil {
            frames += Int64(buffer.frameLength)
        }
        waveform.add(buffer)
        level = WaveformBuilder.meterLevel(rms: waveform.lastRMS)
    }

    func receive(text: String?, isFinal: Bool, failed: Bool) {
        lock.withLock {
            if let text { self.text = text }
            if isFinal { self.isFinal = true }
            if failed { self.failed = true }
        }
    }

    var snapshot: (level: Float, text: String, isFinal: Bool, failed: Bool) {
        lock.withLock { (level, text, isFinal, failed) }
    }

    /// No more audio goes to the recognizer after this.
    func endAudio() {
        let shouldEnd = lock.withLock { () -> Bool in
            defer { ended = true }
            return !ended
        }
        if shouldEnd { request.endAudio() }
    }

    /// Finishes the file and returns where it is, its length and waveform. Safe to call more than once.
    func closeRecording() -> (url: URL?, duration: Double, waveform: [Float]) {
        lock.withLock {
            file?.close()
            file = nil
            return (fileURL, sampleRate > 0 ? Double(frames) / sampleRate : 0, waveform.bars())
        }
    }
}
