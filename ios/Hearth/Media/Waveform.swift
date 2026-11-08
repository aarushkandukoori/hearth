// Turns audio into the 32 bars a voice-note bubble draws, and microphone loudness into a 0...1
// meter value. Works on buffers as they stream in, so long recordings never sit in memory.

import AVFoundation

struct WaveformBuilder: Sendable {
    /// Loudness (RMS) of each short window seen so far.
    private(set) var levels: [Float] = []
    private(set) var frameCount = 0
    /// RMS of the most recent buffer, for a live meter.
    private(set) var lastRMS: Float = 0

    private let windowFrames: Int
    private var windowSum: Float = 0
    private var windowFilled = 0

    init(sampleRate: Double, windowSeconds: Double = 0.05) {
        windowFrames = max(1, Int(sampleRate * windowSeconds))
    }

    mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        var bufferSum: Float = 0
        for sample in samples {
            let square = sample * sample
            bufferSum += square
            windowSum += square
            windowFilled += 1
            if windowFilled == windowFrames {
                levels.append((windowSum / Float(windowFilled)).squareRoot())
                windowSum = 0
                windowFilled = 0
            }
        }
        frameCount += samples.count
        lastRMS = (bufferSum / Float(samples.count)).squareRoot()
    }

    mutating func add(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { add($0) }
    }

    /// Reads channel 0 of a float or integer PCM buffer (interleaved or not).
    mutating func add(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let step = buffer.stride
        if let channels = buffer.floatChannelData {
            if step == 1 {
                add(UnsafeBufferPointer(start: channels[0], count: count))
            } else {
                add((0..<count).map { channels[0][$0 * step] })
            }
        } else if let channels = buffer.int16ChannelData {
            add((0..<count).map { Float(channels[0][$0 * step]) / 32768 })
        } else if let channels = buffer.int32ChannelData {
            add((0..<count).map { Float(channels[0][$0 * step]) / 2_147_483_648 })
        }
    }

    /// `count` bars in 0...1 (the loudest part is 1). A last partial window counts only if it holds
    /// at least half a window (a few stray samples would make a noisy last bar).
    func bars(count: Int = 32) -> [Float] {
        var all = levels
        if windowFilled > 0, windowFilled * 2 >= windowFrames || levels.isEmpty {
            all.append((windowSum / Float(windowFilled)).squareRoot())
        }
        return Self.bars(fromLevels: all, count: count)
    }

    /// Squeezes (or stretches) window levels into `count` bars, normalized to the peak.
    /// The square root lifts quiet parts so speech doesn't look like a flat line.
    static func bars(fromLevels levels: [Float], count: Int = 32) -> [Float] {
        guard count > 0 else { return [] }
        guard let peak = levels.max(), peak > 0.0005 else { return Array(repeating: 0, count: count) }
        return (0..<count).map { index in
            let start = index * levels.count / count
            let end = min(levels.count, max(start + 1, (index + 1) * levels.count / count))
            let loudest = levels[start..<end].max() ?? 0
            return min(1, (loudest / peak).squareRoot())
        }
    }

    /// Maps an RMS value to a 0...1 meter reading on a -50...0 dB scale.
    static func meterLevel(rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(1, max(0, (decibels + 50) / 50))
    }
}
