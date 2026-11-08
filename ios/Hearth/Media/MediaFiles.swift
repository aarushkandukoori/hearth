// File helpers for Media: where voice notes, photos and pictures live under HearthPaths.media,
// image encoding with ImageIO (never copies metadata), and audio files for recordings.

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MediaFiles {
    enum Folder: String {
        case voice, photos, pictures
    }

    /// A fresh media-relative path like "photos/1F2E....jpg". Creates the folder if needed.
    static func newPath(in folder: Folder, ext: String) -> String {
        HearthPaths.ensure(HearthPaths.media.appendingPathComponent(folder.rawValue, isDirectory: true))
        return "\(folder.rawValue)/\(UUID().uuidString).\(ext)"
    }

    /// A fresh file URL without extension in a media folder (the audio writer picks .m4a or .caf).
    static func newBase(in folder: Folder) -> URL {
        let dir = HearthPaths.ensure(HearthPaths.media.appendingPathComponent(folder.rawValue, isDirectory: true))
        return dir.appendingPathComponent(UUID().uuidString)
    }

    /// The media-relative path of a file inside HearthPaths.media, e.g. "voice/abc.m4a".
    static func relativePath(of url: URL, in folder: Folder) -> String {
        "\(folder.rawValue)/\(url.lastPathComponent)"
    }

    /// Applies complete file protection to a file written by another API (such as AVAudioFile).
    static func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }

    // MARK: Images

    static func pngData(_ image: CGImage) -> Data? {
        encode(image, type: .png, properties: [:])
    }

    static func jpegData(_ image: CGImage, quality: Double = 0.82) -> Data? {
        encode(image, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    /// Only the pixels go in: adding a bare CGImage (not CGImageDestinationAddImageFromSource) means no
    /// EXIF, GPS, camera or date metadata can be carried over.
    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: Audio

    /// Opens `<base>.m4a` (AAC, about a tenth the size) for writing buffers of `format`,
    /// or `<base>.caf` (plain PCM) if AAC can't be set up for that format.
    static func makeAudioFile(at base: URL, for format: AVAudioFormat) throws -> AVAudioFile {
        HearthPaths.ensure(base.deletingLastPathComponent())
        let aacURL = base.appendingPathExtension("m4a")
        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        if let file = try? AVAudioFile(forWriting: aacURL, settings: aac, commonFormat: format.commonFormat,
                                       interleaved: format.isInterleaved) {
            return file
        }
        try? FileManager.default.removeItem(at: aacURL)
        return try AVAudioFile(forWriting: base.appendingPathExtension("caf"), settings: format.settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }
}

/// Who owns the shared audio session right now.
@MainActor enum MediaSession {
    /// True while Dictation is recording. VoiceStudio then leaves the session's category alone.
    static var isRecording = false
}
