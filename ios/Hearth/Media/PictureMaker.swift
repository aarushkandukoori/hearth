// Pictures characters send: a picture from the town's own art that matches the caption, else a postcard
// drawn on the phone. Hearth no longer uses another company's image model; Pie can draw (FLUX.2 klein runs
// on Pie), but Pie runs one model per process, and on the iPhone that model is the characters' language
// model, so drawing new pictures waits for Pie to host two models at once.

import CoreGraphics
import Foundation
import Observation

enum PictureError: LocalizedError {
    case unavailable, needsAnimalOrPlace, appInBackground, failed

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Hearth can't draw new pictures on this iPhone yet. Characters send pictures from the town's own art and postcards instead."
        case .needsAnimalOrPlace: return "Pictures show animals, places and things, but not people. Try describing an animal friend."
        case .appInBackground: return "Pictures can only be made while Hearth is open on screen."
        case .failed: return "That picture didn't come out. Please try again."
        }
    }
}

@MainActor @Observable final class PictureMaker {
    /// True while a picture is being made (or waiting its turn).
    private(set) var isWorking = false

    /// Whether new pictures can be drawn on this iPhone. Always false for now (see the file comment).
    var isAvailable: Bool { false }

    @ObservationIgnored private var queueTail: Task<Void, Never>?
    @ObservationIgnored private var jobs = 0

    /// A picture for a character's message: matching town art, else a postcard (status .failed only if
    /// even that failed).
    func makePicture(caption: String, for c: Character?, style: PictureStyle) async -> Attachment {
        _ = style
        return await oneAtATime { await self.pickPicture(caption: caption, for: c) }
    }

    /// PNG data for a new character's avatar (Create). Drawing isn't available, so this always throws.
    func makeAvatar(prompt: String, style: PictureStyle) async throws -> Data {
        _ = (prompt, style)
        throw PictureError.unavailable
    }

    // MARK: Picking

    private func pickPicture(caption: String, for c: Character?) async -> Attachment {
        let shown = Self.cleanCaption(caption)
        if let relative = await fallbackFile(for: shown, character: c) {
            return Attachment(kind: .picture, file: relative, caption: shown, status: .ready)
        }
        HearthLog.error("picture", "even the postcard fallback failed")
        return Attachment(kind: .picture, file: nil, caption: shown, status: .failed)
    }

    /// Bundled art that matches the caption, copied into media/pictures, else a postcard PNG.
    private func fallbackFile(for caption: String, character c: Character?) async -> String? {
        if let asset = Self.fallbackAsset(for: caption, character: c, assets: Self.bundledArtNames),
           let source = HearthPaths.bundledArt(asset), let data = try? Data(contentsOf: source) {
            let relative = MediaFiles.newPath(in: .pictures, ext: source.pathExtension)
            if (try? HearthPaths.write(data, to: HearthPaths.mediaURL(relative))) != nil {
                HearthLog.info("picture", "used bundled art instead")
                return relative
            }
        }
        if let image = Postcard.render(caption: caption, character: c), let relative = await Self.savePNG(image) {
            HearthLog.info("picture", "used a postcard instead")
            return relative
        }
        return nil
    }

    /// Saves a PNG as media/pictures/<uuid>.png (off the main actor) and returns its relative path.
    @concurrent nonisolated private static func savePNG(_ image: CGImage) async -> String? {
        guard let png = MediaFiles.pngData(image) else { return nil }
        let relative = MediaFiles.newPath(in: .pictures, ext: "png")
        return (try? HearthPaths.write(png, to: HearthPaths.mediaURL(relative))) != nil ? relative : nil
    }

    /// Runs jobs strictly one after another.
    private func oneAtATime<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = queueTail
        let job = Task { @MainActor in
            await previous?.value
            return await work()
        }
        queueTail = Task { _ = await job.value }
        jobs += 1
        isWorking = true
        let result = await job.value
        jobs -= 1
        isWorking = jobs > 0
        return result
    }

    /// Names of bundled art files (Resources/Art), e.g. "loc-harbor", "char-juno".
    private static let bundledArtNames: [String] = {
        let urls = Bundle.main.urls(forResourcesWithExtension: nil, subdirectory: "Art") ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.filter { !$0.hasPrefix(".") }
    }()

    // MARK: Prompt rules (pure, unit-tested)

    /// "[photo: A photo of the harbor at dawn.]" -> "the harbor at dawn"
    nonisolated static func cleanCaption(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tag = s.range(of: #"\[(?:photo|picture|image)\s*:[^\]]*\]"#, options: [.regularExpression, .caseInsensitive]) {
            s = String(s[tag]).replacingOccurrences(of: #"^\[(?:photo|picture|image)\s*:"#, with: "",
                                                    options: [.regularExpression, .caseInsensitive])
            s = String(s.dropLast())
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"^(?:a |an )?(?:photo|picture|pic|snapshot|image|shot)\s+of\s+"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.").union(.whitespacesAndNewlines))
        return String(s.prefix(200))
    }

    /// Makes a caption safe for a picture prompt (pictures never show people): removes words for
    /// people and the pronouns that stand for them. Returns "" when nothing drawable is left
    /// ("a selfie of a person"), so the caller goes straight to the fallback.
    nonisolated static func sanitize(_ prompt: String) -> String {
        var s = " " + cleanCaption(prompt) + " "
        let personWords = "person|persons|people|man|men|woman|women|boy|boys|girl|girls|child|children|kid|kids|"
            + "baby|babies|toddler|toddlers|teen|teens|teenager|teenagers|human|humans|lady|ladies|guy|guys|"
            + "gentleman|gentlemen|someone|somebody|anyone|everyone|everybody|crowd|family|families|friend|friends|"
            + "couple|husband|wife|mom|mum|dad|mother|father|brother|sister|son|daughter|grandma|grandpa|"
            + "grandmother|grandfather|aunt|uncle|cousin|neighbor|neighbour|neighbors|neighbours|stranger|strangers|"
            + "tourist|tourists|fisherman|fishermen|farmer|farmers|baker|chef|doctor|nurse|teacher|student|students|"
            + "hand|hands|selfie|selfies"
        let rules = [
            #"\b(?:a |an |the |my |your )?(?:selfie|self[- ]portrait)s?(?: of)?\b"#,
            #"\b(?:a |an )?(?:photo|picture|pic|image|portrait)s? of (?:me|myself|us|you|yourself)\b"#,
            #"\b(?:(?:a|an|the|some|my|your|our|their|his|her|one|two|three|four|five|another|other)\s+)?"#
                + #"(?:(?:young|old|little|small|tall|smiling|happy|cute|sweet|lovely|kind|local|elderly)\s+)?"#
                + "(?:\(personWords))(?:'s|’s)?\\b",
            #"\b(?:me|myself|us|you|yourself|i|we|he|she|him|his|her|hers|they|them|their)\b"#,
        ]
        for rule in rules {
            s = s.replacingOccurrences(of: rule, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // Tidy what's left: spaces, articles stranded before a preposition, dangling connectors.
        let connectors = "of|with|and|or|by|for|to|from|featuring|showing"
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b(?:a|an|the)\s+(?=(?:of|with|and|or|at|in|on|by|to|from)\b)"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"^[\s,;:]*(?:(?:\#(connectors))\b[\s,;:]*)+"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"[\s,;:]*(?:\b(?:\#(connectors)|the|a|an|at|in|on)\b[\s,;:]*)+$"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ",;:-").union(.whitespacesAndNewlines))

        let filler: Set<String> = ["a", "an", "the", "of", "with", "and", "or", "at", "in", "on", "to", "by", "for",
                                   "from", "is", "are", "it", "this", "that", "my", "your", "our", "some", "very"]
        let words = s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.allSatisfy({ filler.contains($0) }) { return "" }
        return String(s.prefix(180))
    }

    /// The bundled art that best fits a caption, by keyword: a location ("loc-harbor" for "boats at
    /// dawn") or a resident ("char-juno" when Juno sends a picture of herself). nil if nothing fits.
    nonisolated static func fallbackAsset(for caption: String, character: Character?, assets: [String]) -> String? {
        let words = keywords(in: caption)
        guard !words.isEmpty else { return nil }
        var best: (asset: String, score: Int)?
        for asset in assets.sorted() {
            let score = matchScore(asset: asset.lowercased(), words: words, character: character)
            if score >= 2, score > (best?.score ?? 0) { best = (asset, score) }
        }
        return best?.asset
    }

    /// Lowercased words of 2+ letters, plus the singular of simple plurals ("boats" -> "boat").
    nonisolated static func keywords(in text: String) -> Set<String> {
        var out = Set<String>()
        for piece in text.lowercased().split(whereSeparator: { !$0.isLetter }) where piece.count > 1 {
            let word = String(piece)
            out.insert(word)
            if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { out.insert(String(word.dropLast())) }
        }
        return out
    }

    nonisolated private static func matchScore(asset: String, words: Set<String>, character: Character?) -> Int {
        if asset.hasPrefix("loc-") {
            var score = 0
            for part in asset.dropFirst(4).split(separator: "-").map(String.init) {
                if words.contains(part) {
                    score += 3
                } else if let related = placeKeywords[part], !related.isDisjoint(with: words) {
                    score += 2
                }
            }
            // A small nudge toward the sender's own home.
            if score > 0, let home = character?.homeLocationID, asset == "loc-" + home.lowercased() { score += 1 }
            return score
        }
        if asset.hasPrefix("char-") {
            let id = String(asset.dropFirst(5))
            var score = id.split(separator: "-").contains { words.contains(String($0)) } ? 3 : 0
            if let character, character.id.lowercased() == id {
                if !keywords(in: character.name).isDisjoint(with: words) { score = max(score, 3) }
                if !words.isDisjoint(with: ["me", "myself", "selfie", "self"]) { score += 3 }
            }
            return score
        }
        return 0
    }

    /// Caption words that point at a kind of place, keyed by words likely to appear in location ids.
    nonisolated private static let placeKeywords: [String: Set<String>] = {
        let groups: [([String], [String])] = [
            (["lighthouse", "beacon"], ["lighthouse", "beacon", "keeper", "lamp", "foghorn"]),
            (["harbor", "harbour", "port", "docks", "dock", "pier", "wharf", "marina", "jetty", "boathouse"],
             ["harbor", "harbour", "boat", "dock", "pier", "port", "ship", "sail", "sailboat", "fishing", "net", "wharf",
              "jetty", "rowboat", "buoy", "gull", "seagull"]),
            (["beach", "shore", "cove", "bay", "sands", "dunes", "tidepools", "tidepool", "seawall", "boardwalk"],
             ["beach", "sand", "shore", "shell", "seashell", "wave", "tide", "sea", "ocean", "surf", "sandcastle",
              "driftwood", "crab", "starfish"]),
            (["bakery", "bakehouse", "oven"],
             ["bakery", "bread", "loaf", "pastry", "bun", "croissant", "cake", "pie", "oven", "baking", "baked", "scone",
              "muffin", "cookie", "flour"]),
            (["cafe", "teahouse", "tearoom", "tea", "coffee", "kettle"],
             ["tea", "teapot", "cafe", "coffee", "cup", "mug", "kettle", "cocoa", "latte", "biscuit"]),
            (["library", "bookshop", "bookstore", "books", "archive"],
             ["book", "library", "reading", "shelf", "shelves", "story", "page", "novel", "bookshop"]),
            (["garden", "gardens", "greenhouse", "allotment", "nursery"],
             ["garden", "flower", "plant", "greenhouse", "vegetable", "seedling", "bloom", "blossom", "rose", "tulip",
              "watering", "herb", "tomato", "sunflower"]),
            (["market", "square", "plaza", "green", "commons", "fountain"],
             ["market", "stall", "fruit", "produce", "square", "plaza", "fountain", "bench", "lamppost", "town"]),
            (["forest", "woods", "wood", "grove", "glade", "thicket"],
             ["forest", "wood", "woods", "tree", "moss", "mushroom", "fern", "pine", "oak", "trail", "owl"]),
            (["meadow", "field", "fields", "hill", "hills", "orchard", "farm"],
             ["meadow", "field", "grass", "wildflower", "hill", "orchard", "apple", "farm", "picnic", "kite"]),
            (["observatory", "lookout", "overlook", "cliff", "cliffs", "point", "peak"],
             ["star", "telescope", "night", "sky", "moon", "constellation", "comet", "view", "cliff", "lookout"]),
            (["pond", "lake", "river", "creek", "stream", "falls", "bridge", "mill"],
             ["pond", "lake", "river", "creek", "stream", "duck", "frog", "lily", "bridge", "waterfall", "reed"]),
            (["station", "railway", "depot"], ["train", "station", "track", "platform", "railway", "ticket"]),
            (["workshop", "forge", "smithy", "studio", "shed"],
             ["workshop", "tool", "forge", "hammer", "carving", "paint", "painting", "easel", "canvas", "clay"]),
            (["inn", "tavern", "pub", "hall"], ["inn", "tavern", "fireplace", "hearth", "stew", "soup", "supper"]),
            (["bandstand", "stage", "theater", "theatre", "music"],
             ["music", "song", "guitar", "fiddle", "band", "concert", "stage", "piano", "violin"]),
            (["post", "postoffice", "mail"], ["letter", "mail", "post", "stamp", "parcel", "envelope", "postcard"]),
            (["school", "schoolhouse", "classroom"], ["school", "classroom", "chalkboard", "lesson", "desk"]),
            (["clinic", "apothecary", "pharmacy"], ["clinic", "medicine", "bandage", "remedy", "tonic"]),
            (["cottage", "house", "home", "burrow", "den", "nook", "attic"],
             ["home", "cottage", "house", "porch", "window", "kitchen", "bed", "blanket", "armchair", "burrow"]),
        ]
        var table: [String: Set<String>] = [:]
        for (ids, words) in groups {
            for id in ids { table[id, default: []].formUnion(words) }
        }
        return table
    }()
}
