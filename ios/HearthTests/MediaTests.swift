// Unit tests for Media's pure pieces: spoken text, sentence splitting, voice ranking, waveforms,
// picture prompt rules, bundled-art fallback, photo captions and metadata stripping.

import AVFoundation
import ImageIO
import Speech
import UniformTypeIdentifiers
import XCTest
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import Hearth

final class MediaTests: XCTestCase {

    // MARK: Spoken text

    func testSpokenTextDropsActionsEmojiPhotoTagsAndMarkdown() {
        let reply = "*waves* Morning! 😊\n[photo: the harbor at dawn]\nThe tea is **really** good *sips*"
        XCTAssertEqual(VoiceStudio.spokenText(reply), "Morning! The tea is really good.")
    }

    func testSpokenTextOfOnlyAnActionIsEmpty() {
        XCTAssertEqual(VoiceStudio.spokenText("*nods slowly*"), "")
        XCTAssertEqual(VoiceStudio.spokenText("[photo: a cup of tea]"), "")
    }

    func testSpokenTextTidiesSpacesLinksHeadingsAndKeepsDigits() {
        XCTAssertEqual(VoiceStudio.spokenText("Oh *laughs*, that's lovely"), "Oh, that's lovely.")
        XCTAssertEqual(VoiceStudio.spokenText("# Hello\n- [Lantern Bay](https://example.com) is lovely ❤️"),
                       "Hello. Lantern Bay is lovely.")
        XCTAssertEqual(VoiceStudio.spokenText("I have 3 cats, #1 is Moss 👍🏽"), "I have 3 cats, #1 is Moss.")
    }

    func testSplitSentencesWaitsForSpaceAndRespectsActions() {
        var split = VoiceStudio.splitSentences("Hi there! How are")
        XCTAssertEqual(split.ready, ["Hi there!"])
        XCTAssertEqual(split.remainder, " How are")

        split = VoiceStudio.splitSentences("*She pours tea. Then sits.* Lovely")
        XCTAssertEqual(split.ready, [])

        split = VoiceStudio.splitSentences("Mr. Bramble says hi. It costs 3.50 today.")
        XCTAssertEqual(split.ready, ["Mr. Bramble says hi."])
        XCTAssertEqual(split.remainder, " It costs 3.50 today.")

        split = VoiceStudio.splitSentences("Really?! Yes.\nOkay ")
        XCTAssertEqual(split.ready, ["Really?!", "Yes."])
        XCTAssertEqual(split.remainder, "Okay ")
    }

    func testSpeechRateStaysComfortable() {
        XCTAssertEqual(VoiceStudio.speechRate(for: 0.5), 0.5)
        XCTAssertEqual(VoiceStudio.speechRate(for: 0.05), 0.32)
        XCTAssertEqual(VoiceStudio.speechRate(for: 0.95), 0.62)
    }

    // MARK: Voice ranking

    private func voices(_ list: [(name: String, quality: Int, language: String, gender: String)]) -> [VoiceCandidate] {
        list.map { VoiceCandidate(name: $0.name, quality: $0.quality, language: $0.language, gender: $0.gender) }
    }

    func testRankingPutsEnglishAndQualityFirstAndDropsNoveltyVoices() {
        var list = voices([
            ("Fred", 1, "en-US", "male"), ("Samantha", 1, "en-US", "female"), ("Ava (Premium)", 3, "en-US", "female"),
            ("Daniel (Enhanced)", 2, "en-GB", "male"), ("Anna (Premium)", 3, "de-DE", "female"),
            ("Bubbles", 1, "en-US", "neutral"), ("Eddy (English (US))", 1, "en-US", "neutral"),
            ("Karen", 1, "en-AU", "female"), ("Moira", 1, "en-IE", "female"),
        ])
        list.append(VoiceCandidate(name: "Zoe", quality: 3, language: "en-US", isNovelty: true))
        list.append(VoiceCandidate(name: "My Voice", quality: 3, language: "en-US", isPersonal: true))
        list.append(VoiceCandidate(identifier: "com.apple.eloquence.en-US.Rocko", name: "Rocko", quality: 1, language: "en-US"))

        let ranked = VoiceRanking.ranked(list, region: "US").map(\.option)
        XCTAssertEqual(ranked.map(\.name), ["Ava", "Daniel", "Samantha", "Karen", "Moira", "Anna"])
        XCTAssertEqual(ranked.map(\.quality), ["Premium", "Enhanced", "Default", "Default", "Default", "Premium"])
    }

    func testPickIsStableAndFollowsStyle() {
        let list = voices([
            ("Samantha", 1, "en-US", "female"), ("Samantha (Enhanced)", 2, "en-US", "female"),
            ("Aaron", 1, "en-US", "male"), ("Daniel", 1, "en-GB", "male"), ("Moira", 1, "en-IE", "female"),
            ("Karen", 1, "en-AU", "female"), ("Fred", 1, "en-US", "male"),
        ])
        let male = VoiceStyle(gender: "male")
        let first = VoiceRanking.pick(for: male, characterID: "bramble", from: list)
        XCTAssertEqual(first, VoiceRanking.pick(for: male, characterID: "bramble", from: list.reversed()))
        XCTAssertEqual(first?.gender, "male")
        XCTAssertNotEqual(first?.family, "Fred")

        // A locale narrows the pool; the best installed quality of a voice is used.
        let usFemale = VoiceStyle(gender: "female", locale: "en_US")
        XCTAssertEqual(VoiceRanking.pick(for: usFemale, characterID: "juno", from: list)?.name, "Samantha (Enhanced)")

        // An installed preferred name wins over gender and hashing.
        let preferred = VoiceStyle(gender: "male", preferredVoiceNames: ["Nobody", "moira"])
        XCTAssertEqual(VoiceRanking.pick(for: preferred, characterID: "x", from: list)?.family, "Moira")
    }

    func testDistinctAssignmentGivesEveryoneTheirOwnVoiceUntilTheyRunOut() {
        let list = voices([("Samantha", 1, "en-US", "female"), ("Moira", 1, "en-IE", "female"), ("Karen", 1, "en-AU", "female")])
        func resident(_ id: String) -> Character {
            Character(id: id, name: id.capitalized, tagline: "", bio: "", greeting: "", personality: "", speakingStyle: "",
                      avatar: AvatarRef(), accentHex: "#FF8A4C", voice: VoiceStyle(gender: "female"))
        }
        let three = VoiceRanking.distinctAssignment(for: ["juno", "pip", "wren"].map(resident), from: list)
        XCTAssertEqual(three.count, 3)
        XCTAssertEqual(Set(three.values).count, 3)

        let four = VoiceRanking.distinctAssignment(for: ["juno", "pip", "wren", "maple"].map(resident), from: list)
        XCTAssertEqual(Set(four.values).count, 3)
        XCTAssertEqual(four["juno"], three["juno"], "adding a character must not move earlier ones")
    }

    func testStableHashNeverChanges() {
        XCTAssertEqual(VoiceRanking.stableHash(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(VoiceRanking.stableHash("a"), 0xaf63_dc4c_8601_ec8c)
    }

    // MARK: Waveforms

    /// One second of a 440 Hz tone that gets louder from silence to full scale.
    private func rampBuffer(_ format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / format.sampleRate
            let sample = sin(2 * .pi * 440 * t) * t
            if let data = buffer.floatChannelData {
                data[0][i * buffer.stride] = Float(sample)
            } else if let data = buffer.int16ChannelData {
                data[0][i * buffer.stride] = Int16(sample * 32767)
            }
        }
        return buffer
    }

    func testWaveformFromSyntheticBuffers() throws {
        for format in [AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1),
                       AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22050, channels: 1, interleaved: true)] {
            let format = try XCTUnwrap(format)
            var builder = WaveformBuilder(sampleRate: format.sampleRate)
            builder.add(try rampBuffer(format))
            let bars = builder.bars()
            XCTAssertEqual(bars.count, 32)
            XCTAssertEqual(builder.frameCount, 22050)
            XCTAssertEqual(bars.last ?? 0, 1, accuracy: 0.001)
            XCTAssertLessThan(bars[0], 0.35)
            for (earlier, later) in zip(bars, bars.dropFirst()) {
                XCTAssertLessThanOrEqual(earlier, later + 0.02)
            }
        }
    }

    func testWaveformOfSilenceIsFlatAndShortAudioStretches() {
        var silent = WaveformBuilder(sampleRate: 22050)
        silent.add([Float](repeating: 0, count: 5000))
        XCTAssertEqual(silent.bars(), Array(repeating: 0, count: 32))

        let stretched = WaveformBuilder.bars(fromLevels: [0.1, 0.4], count: 4)
        XCTAssertEqual(stretched.count, 4)
        XCTAssertEqual(stretched[3], 1, accuracy: 0.0001)
        XCTAssertEqual(stretched[0], 0.5, accuracy: 0.0001)
    }

    func testMeterLevel() {
        XCTAssertEqual(WaveformBuilder.meterLevel(rms: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(WaveformBuilder.meterLevel(rms: 0), 0)
        XCTAssertEqual(WaveformBuilder.meterLevel(rms: 0.01), 0.2, accuracy: 0.001)
    }

    func testAudioFileIsSmallAACAndKeepsItsLength() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-media-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try MediaFiles.makeAudioFile(at: folder.appendingPathComponent("note"), for: format)
        XCTAssertEqual(file.url.pathExtension, "m4a")
        let second = try rampBuffer(format)
        try file.write(from: second)
        try file.write(from: second)
        let url = file.url
        file.close()

        let reopened = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(reopened.length) / reopened.fileFormat.sampleRate, 2, accuracy: 0.1)
        let bytes = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThan(bytes, 2 * 48000 * 4 / 4, "AAC should be far smaller than raw float PCM")
    }

    func testDictationSinkRecordsWhatTheMicSends() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-dictation-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let sink = DictationSink(request: SFSpeechAudioBufferRecognitionRequest(), base: folder.appendingPathComponent("mine"))
        let second = try rampBuffer(format)
        sink.consume(second)
        XCTAssertGreaterThan(sink.snapshot.level, 0.5)
        sink.consume(second)
        sink.receive(text: "Hello Juno", isFinal: false, failed: false)
        sink.receive(text: "Hello Juno.", isFinal: true, failed: false)
        XCTAssertEqual(sink.snapshot.text, "Hello Juno.")
        XCTAssertTrue(sink.snapshot.isFinal)

        sink.endAudio()
        sink.endAudio()  // second call is a no-op
        sink.consume(second)  // ignored after the end
        let recording = sink.closeRecording()
        XCTAssertEqual(recording.duration, 2, accuracy: 0.01)
        XCTAssertEqual(recording.waveform.count, 32)
        let url = try XCTUnwrap(recording.url)
        XCTAssertEqual(url.pathExtension, "m4a")
        let reopened = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(reopened.length) / reopened.fileFormat.sampleRate, 2, accuracy: 0.1)
        XCTAssertEqual(sink.closeRecording().url, url, "closing twice is safe")
    }

    func testVoiceNoteRendersToAnAudioFile() async throws {
        let voice = AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix("en") }
        try XCTSkipIf(voice == nil, "No English voice installed")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-voice-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = SpeechFileWriter(base: folder.appendingPathComponent("note"))
        let spec = SpeechSpec(text: "Hello from Lantern Bay. The kettle is on.", voiceIdentifier: voice?.identifier, pitch: 1, rate: 0.5)
        let rendered = try await writer.render(spec, timeout: 30)
        XCTAssertGreaterThan(rendered.duration, 1)
        XCTAssertLessThan(rendered.duration, 15)
        XCTAssertEqual(rendered.waveform.count, 32)
        XCTAssertEqual(rendered.waveform.max() ?? 0, 1, accuracy: 0.001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rendered.url.path))
    }

    // MARK: Picture prompts

    func testSanitizeRemovesPeople() {
        XCTAssertEqual(PictureMaker.sanitize("a selfie of a person"), "")
        XCTAssertEqual(PictureMaker.sanitize("a photo of me"), "")
        XCTAssertEqual(PictureMaker.sanitize("[photo: a man fishing at the pier at sunset]"), "fishing at the pier at sunset")
        XCTAssertEqual(PictureMaker.sanitize("me and Juno on the dock"), "Juno on the dock")
        XCTAssertEqual(PictureMaker.sanitize("two kids building a sandcastle"), "building a sandcastle")
        XCTAssertEqual(PictureMaker.sanitize("a family of ducks on the pond"), "ducks on the pond")
        XCTAssertEqual(PictureMaker.sanitize("selfie with Theo at the cafe"), "Theo at the cafe")
        XCTAssertEqual(PictureMaker.sanitize("the baker's fresh bread"), "fresh bread")
    }

    func testSanitizeKeepsAnimalsPlacesAndThings() {
        XCTAssertEqual(PictureMaker.sanitize("the lighthouse at dusk"), "the lighthouse at dusk")
        XCTAssertEqual(PictureMaker.sanitize("Juno the otter holding a cup of tea"), "Juno the otter holding a cup of tea")
        XCTAssertEqual(PictureMaker.sanitize("snowman in the garden"), "snowman in the garden")
        XCTAssertEqual(PictureMaker.cleanCaption("[photo: A photo of the harbor at dawn.]"), "the harbor at dawn")
    }

    func testFallbackAssetMatchesPlacesAndResidents() {
        let assets = ["loc-harbor", "loc-lighthouse", "loc-bakery", "char-juno", "char-theo", "hero-town"]
        XCTAssertEqual(PictureMaker.fallbackAsset(for: "boats bobbing at dawn", character: nil, assets: assets), "loc-harbor")
        XCTAssertEqual(PictureMaker.fallbackAsset(for: "the lighthouse beam tonight", character: nil, assets: assets), "loc-lighthouse")
        XCTAssertEqual(PictureMaker.fallbackAsset(for: "fresh bread this morning", character: nil, assets: assets), "loc-bakery")
        XCTAssertEqual(PictureMaker.fallbackAsset(for: "Theo napping in the sun", character: nil, assets: assets), "char-theo")
        XCTAssertNil(PictureMaker.fallbackAsset(for: "something abstract", character: nil, assets: assets))
        XCTAssertNil(PictureMaker.fallbackAsset(for: "", character: nil, assets: assets))

        let juno = Character(id: "juno", name: "Juno", tagline: "", bio: "", greeting: "", personality: "", speakingStyle: "",
                             avatar: AvatarRef(), accentHex: "#6FB7C9")
        XCTAssertEqual(PictureMaker.fallbackAsset(for: "a selfie by the window", character: juno, assets: assets), "char-juno")
    }

    @MainActor
    func testPicturesUseNoImageModel() async {
        let maker = PictureMaker()
        XCTAssertFalse(maker.isAvailable, "no image model: town art and postcards only")
        do {
            _ = try await maker.makeAvatar(prompt: "an otter barista", style: .animation)
            XCTFail("drawing should be unavailable")
        } catch {
            XCTAssertEqual(error as? PictureError, .unavailable)
        }
    }

    func testPostcardSymbolsFitCaptionsAndExist() {
        XCTAssertEqual(Postcard.symbol(for: "tea at dawn"), "cup.and.saucer.fill")
        XCTAssertEqual(Postcard.symbol(for: "the moon over the bay"), "moon.stars.fill")
        XCTAssertEqual(Postcard.symbol(for: "boats in the harbor at sunset"), "sailboat.fill")
        XCTAssertEqual(Postcard.symbol(for: "something new"), "sparkles")
        XCTAssertEqual(Postcard.displayCaption("[photo: the harbor at dawn]"), "The harbor at dawn")
        for name in Postcard.symbolKeywords.map(\.symbol) + ["sparkles"] {
            #if canImport(UIKit)
            XCTAssertNotNil(UIImage(systemName: name), name)
            #elseif canImport(AppKit)
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
            #endif
        }
    }

    // MARK: Photos

    func testCaptionComposition() {
        let dog = PhotoScene(labels: ["dog", "animal", "canine", "grass", "outdoor", "daytime"], animals: ["dog"], brightness: 0.6)
        XCTAssertEqual(PhotoReader.caption(for: dog), "a photo of a dog on grass outdoors in daylight")

        let screenshot = PhotoScene(textLines: ["Flight delayed", "Gate B12"], isScreenshot: true)
        XCTAssertEqual(PhotoReader.caption(for: screenshot), "a screenshot with the text \"Flight delayed\"")

        let friends = PhotoScene(labels: ["people", "beach", "outdoor"], faceCount: 2, brightness: 0.7)
        XCTAssertEqual(PhotoReader.caption(for: friends), "a photo of two people at the beach in daylight")

        let pets = PhotoScene(labels: ["cat", "sofa"], animals: ["dog", "cat"], brightness: 0.1)
        XCTAssertEqual(PhotoReader.caption(for: pets), "a photo of a cat and a dog on a sofa in dim light")

        let coffee = PhotoScene(labels: ["coffee", "cup", "table"], textLines: ["OPEN"], brightness: 0.5)
        XCTAssertEqual(PhotoReader.caption(for: coffee), "a photo of coffee on a table with the words \"OPEN\"")

        // Specific labels win over parent ones; plurals and places read naturally.
        XCTAssertEqual(PhotoReader.caption(for: PhotoScene(labels: ["animal", "bird", "raptor", "owl"])), "a photo of an owl")
        XCTAssertEqual(PhotoReader.caption(for: PhotoScene(labels: ["liquid", "water", "underwater", "animal", "jellyfish"])),
                       "a photo of a jellyfish underwater")
        XCTAssertEqual(PhotoReader.caption(for: PhotoScene(labels: ["structure", "rocks"])), "a photo of rocks")
        XCTAssertEqual(PhotoReader.caption(for: PhotoScene(labels: ["sunset_sunrise", "sky"])), "a photo of a sunset")
        XCTAssertEqual(PhotoReader.caption(for: PhotoScene()), "a photo")
        XCTAssertLessThanOrEqual(PhotoReader.caption(for: PhotoScene(textLines: [String(repeating: "word ", count: 40)],
                                                                     isScreenshot: true)).split(separator: " ").count, 30)
    }

    func testRecognizedTextMustLookLikeWords() {
        XCTAssertTrue(PhotoReader.looksLikeWords("Flight delayed"))
        XCTAssertTrue(PhotoReader.looksLikeWords("Gate B12"))
        XCTAssertTrue(PhotoReader.looksLikeWords("We're sorry for the wait."))
        XCTAssertFalse(PhotoReader.looksLikeWords("3. kgml 4. Vnh&bYqbli"))
        XCTAssertFalse(PhotoReader.looksLikeWords("9:41"))
    }

    func testPrepareStripsLocationAndCameraDataAndShrinks() throws {
        // A 3000 x 2000 JPEG carrying GPS, camera and date metadata.
        let context = try XCTUnwrap(CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        let image = try XCTUnwrap(context.makeImage())
        let original = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(original, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 40.44, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 79.99, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:06 08:00:00"],
        ]
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let before = try XCTUnwrap(CGImageSourceCreateWithData(original, nil))
        let beforeProps = CGImageSourceCopyPropertiesAtIndex(before, 0, nil) as? [CFString: Any]
        XCTAssertNotNil(beforeProps?[kCGImagePropertyGPSDictionary], "test image should start with GPS")

        let prepared = try PhotoReader.prepare(original as Data)
        XCTAssertEqual(max(prepared.image.width, prepared.image.height), 1600)
        XCTAssertFalse(prepared.isScreenshot)
        let after = try XCTUnwrap(CGImageSourceCreateWithData(prepared.jpeg as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(after, 0, nil) as? [CFString: Any])
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake])
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel])
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal])

        // Small images are never blown up.
        let small = try PhotoReader.prepare(XCTUnwrap(MediaFiles.jpegData(XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: 800, height: 600))))))
        XCTAssertEqual(small.image.width, 800)
        XCTAssertEqual(small.image.height, 600)
    }

    func testUnreadablePhotoThrowsFriendlyError() {
        XCTAssertThrowsError(try PhotoReader.prepare(Data("not a photo".utf8))) { error in
            XCTAssertEqual(error as? PhotoReaderError, .unreadable)
        }
    }
}
