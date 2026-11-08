// Renders a character's line to an audio file with AVSpeechSynthesizer.write (nothing plays out
// loud) and measures it for the voice-note bubble. File work happens off the main actor.

import AVFoundation

/// Everything needed to say one line in a character's voice (plain values, safe to pass around).
struct SpeechSpec: Sendable {
    var text: String
    var voiceIdentifier: String?
    var pitch: Float
    var rate: Float
    var volume: Float = 1

    func makeUtterance() -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        if let voiceIdentifier { utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) }
        utterance.pitchMultiplier = pitch
        utterance.rate = rate
        utterance.volume = volume
        return utterance
    }
}

struct RenderedSpeech: Sendable {
    var url: URL
    var duration: Double
    var waveform: [Float]
}

enum VoiceNoteError: LocalizedError {
    case nothingToSay, renderFailed, playbackFailed

    var errorDescription: String? {
        switch self {
        case .nothingToSay: return "There's nothing to say out loud in that message."
        case .renderFailed: return "That voice note couldn't be made. The message is still here as text."
        case .playbackFailed: return "That voice note couldn't be played."
        }
    }
}

/// One-shot writer: `render` once, then let it go. State is shared with AVFoundation's callback
/// queue, so every mutable field is guarded by `lock`.
final class SpeechFileWriter: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let base: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var waveform: WaveformBuilder?
    private var frames: Int64 = 0
    private var sampleRate: Double = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<RenderedSpeech, Error>?
    private var done = false

    /// `base` is the file URL without extension; the result is `<base>.m4a` (or `.caf`).
    init(base: URL) {
        self.base = base
        super.init()
        synthesizer.delegate = self
    }

    /// Writers stay alive a few seconds past the end: TextToSpeech can still deliver callbacks for the
    /// synthesizer on the main queue after the last buffer, and freeing it early crashes inside the framework.
    private static let keepAliveLock = NSLock()
    private static var keepAlive: [ObjectIdentifier: SpeechFileWriter] = [:]

    private static func hold(_ writer: SpeechFileWriter) {
        keepAliveLock.withLock { keepAlive[ObjectIdentifier(writer)] = writer }
    }

    private static func letGo(_ writer: SpeechFileWriter, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            _ = keepAliveLock.withLock { keepAlive.removeValue(forKey: ObjectIdentifier(writer)) }
        }
    }

    func render(_ spec: SpeechSpec, timeout: TimeInterval) async throws -> RenderedSpeech {
        Self.hold(self)
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            // Started on the main queue like live speech; buffers arrive on AVFoundation's own queue.
            DispatchQueue.main.async { [self] in
                synthesizer.write(spec.makeUtterance(), toBufferCallback: makeBufferCallback())
            }
            // Safety net in case the synthesizer never signals the end.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(stopSynthesizer: true)
            }
        }
    }

    private func makeBufferCallback() -> AVSpeechSynthesizer.BufferCallback {
        { [weak self] buffer in self?.receive(buffer) }
    }

    private func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        // An empty buffer is the synthesizer's "that's everything".
        if pcm.frameLength == 0 {
            finish(stopSynthesizer: false)
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard !done, failure == nil else { return }
        do {
            if file == nil {
                file = try MediaFiles.makeAudioFile(at: base, for: pcm.format)
                waveform = WaveformBuilder(sampleRate: pcm.format.sampleRate)
                sampleRate = pcm.format.sampleRate
            }
            try file?.write(from: pcm)
            waveform?.add(pcm)
            frames += Int64(pcm.frameLength)
        } catch {
            failure = error
        }
    }

    // Backup end signal: some systems finish the utterance without sending the empty buffer.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.finish(stopSynthesizer: false)
        }
    }

    private func finish(stopSynthesizer: Bool) {
        lock.lock()
        guard !done, let continuation else {
            lock.unlock()
            return
        }
        done = true
        self.continuation = nil
        let file = self.file
        self.file = nil
        let outcome: Result<RenderedSpeech, Error>
        if let failure {
            outcome = .failure(failure)
        } else if let file, frames > 0, sampleRate > 0 {
            outcome = .success(RenderedSpeech(url: file.url, duration: Double(frames) / sampleRate,
                                              waveform: waveform?.bars() ?? []))
        } else {
            outcome = .failure(VoiceNoteError.renderFailed)
        }
        lock.unlock()

        file?.close()
        if case .failure = outcome, let url = file?.url {
            try? FileManager.default.removeItem(at: url)
        }
        if stopSynthesizer {
            DispatchQueue.main.async { [self] in _ = synthesizer.stopSpeaking(at: .immediate) }
        }
        continuation.resume(with: outcome)
        Self.letGo(self, after: 5)
    }
}
