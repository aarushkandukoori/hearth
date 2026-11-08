// Developer tool (launch argument -HearthArtGen 1): draws the cast and town art with Image Playground
// on this iPhone, saving Documents/art/<id>.png and printing HEARTHART lines for the build scripts.

import CoreGraphics
import Foundation
import ImagePlayground

enum ArtGen {
    struct Job: Decodable {
        var id: String
        var prompt: String
        /// "animation" (default), "illustration" or "sketch".
        var style: String?
    }

    /// Reads Documents/art-jobs.json if present, else the bundled art-jobs.json. Skips ids that
    /// already have a PNG, so it can be re-run after a failure.
    static func run() async {
        let jobs = loadJobs()
        let folder = HearthPaths.documents.appendingPathComponent("art", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        HearthLog.emit("HEARTHART start jobs=\(jobs.count)")

        var ok = 0, failed = 0, skipped = 0
        let creator: ImageCreator
        do {
            creator = try await ImageCreator()
        } catch {
            let reason = PictureMaker.errorName(error)
            for job in jobs {
                HearthLog.emit("HEARTHART fail \(job.id) \(reason)")
            }
            HearthLog.emit("HEARTHART done ok=0 fail=\(jobs.count) skip=0")
            return
        }

        for job in jobs {
            let url = folder.appendingPathComponent("\(job.id).png")
            if FileManager.default.fileExists(atPath: url.path) {
                skipped += 1
                HearthLog.emit("HEARTHART skip \(job.id)")
                continue
            }
            let started = Date()
            switch await draw(job, with: creator) {
            case .success(let image):
                if let png = MediaFiles.pngData(image), (try? png.write(to: url, options: .atomic)) != nil {
                    ok += 1
                    HearthLog.emit("HEARTHART ok \(job.id) \(image.width)x\(image.height)")
                    HearthLog.info("artgen", "\(job.id) took \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                } else {
                    failed += 1
                    HearthLog.emit("HEARTHART fail \(job.id) writeFailed")
                }
            case .failure(let reason):
                failed += 1
                HearthLog.emit("HEARTHART fail \(job.id) \(reason.name)")
            }
        }
        HearthLog.emit("HEARTHART done ok=\(ok) fail=\(failed) skip=\(skipped)")
    }

    struct Failure: Error {
        var name: String
    }

    /// One image, retried up to 3 times (2 s apart) if the app wasn't frontmost.
    private static func draw(_ job: Job, with creator: ImageCreator) async -> Result<CGImage, Failure> {
        let style = playgroundStyle(job.style)
        guard creator.availableStyles.contains(style) else { return .failure(Failure(name: "styleUnavailable")) }
        var attempt = 0
        while true {
            attempt += 1
            do {
                for try await created in creator.images(for: [.text(job.prompt)], style: style, limit: 1) {
                    return .success(created.cgImage)
                }
                return .failure(Failure(name: "noImage"))
            } catch {
                if PictureMaker.isBackgroundForbidden(error), attempt <= 3 {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                return .failure(Failure(name: PictureMaker.errorName(error)))
            }
        }
    }

    private static func playgroundStyle(_ name: String?) -> ImagePlaygroundStyle {
        switch name?.lowercased() {
        case "illustration": return .illustration
        case "sketch": return .sketch
        default: return .animation
        }
    }

    private static func loadJobs() -> [Job] {
        let override = HearthPaths.documents.appendingPathComponent("art-jobs.json")
        let url = FileManager.default.fileExists(atPath: override.path)
            ? override
            : Bundle.main.url(forResource: "art-jobs", withExtension: "json")
        guard let url else {
            HearthLog.error("artgen", "no art-jobs.json found")
            return []
        }
        do {
            return try JSONDecoder().decode([Job].self, from: Data(contentsOf: url))
        } catch {
            HearthLog.error("artgen", "art-jobs.json couldn't be read: \(error)")
            return []
        }
    }
}
