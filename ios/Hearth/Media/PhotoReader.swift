// Photos the user sends: shrunk to 1600 px, stripped of every bit of metadata (GPS, camera, dates),
// saved as a JPEG on this iPhone, and described on-device with Vision so the character can react.

import CoreGraphics
import Foundation
import ImageIO
import Vision

enum PhotoReaderError: LocalizedError {
    case unreadable, saveFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: return "That photo couldn't be opened. Try a different one."
        case .saveFailed: return "Hearth couldn't save that photo on this iPhone."
        }
    }
}

/// What Vision saw, before it becomes a sentence.
struct PhotoScene: Equatable, Sendable {
    /// Classifier labels above 0.3 confidence, most confident first (e.g. "dog", "grass", "outdoor").
    var labels: [String] = []
    /// One entry per recognized animal ("dog", "cat").
    var animals: [String] = []
    /// Faces are only counted, never identified.
    var faceCount = 0
    /// Recognized text, most prominent (largest) first.
    var textLines: [String] = []
    /// Average brightness, 0 (black) to 1 (white).
    var brightness: Double?
    var isScreenshot = false
}

enum PhotoReader {
    static let maxPixelSize = 1600

    /// Re-encodes and saves the photo as media/photos/<uuid>.jpg and writes a caption for it.
    /// @concurrent: always runs off the main actor (decoding plus Vision take a few hundred ms).
    @concurrent static func importPhoto(_ data: Data) async throws -> Attachment {
        let started = Date()
        let prepared = try prepare(data)
        let relative = MediaFiles.newPath(in: .photos, ext: "jpg")
        do {
            try HearthPaths.write(prepared.jpeg, to: HearthPaths.mediaURL(relative))
        } catch {
            throw PhotoReaderError.saveFailed
        }
        var scene = analyze(prepared.image)
        scene.isScreenshot = scene.isScreenshot || prepared.isScreenshot
        let caption = caption(for: scene)
        HearthLog.info("photo", "imported \(prepared.image.width)x\(prepared.image.height), \(scene.labels.count) labels, "
                       + "\(scene.faceCount) faces in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return Attachment(kind: .photo, file: relative, caption: caption, status: .ready)
    }

    /// One short, natural sentence about the image, made on this iPhone (off the main actor).
    @concurrent static func describe(_ image: CGImage) async -> String {
        caption(for: analyze(image))
    }

    /// Downscales (never upscales) to `maxPixelSize`, applies the EXIF rotation, and encodes a JPEG
    /// that holds only pixels. Also notes whether the original was an iPhone screenshot.
    static func prepare(_ data: Data, maxPixelSize: Int = maxPixelSize) throws -> (image: CGImage, jpeg: Data, isScreenshot: Bool) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw PhotoReaderError.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PhotoReaderError.unreadable
        }
        let image = flattened(thumbnail) ?? thumbnail
        guard let jpeg = MediaFiles.jpegData(image, quality: 0.82) else { throw PhotoReaderError.unreadable }
        return (image, jpeg, wasScreenshot(source))
    }

    // MARK: Vision

    /// Runs each request on its own so one failing (some need hardware the Simulator lacks)
    /// doesn't lose the others.
    static func analyze(_ image: CGImage) -> PhotoScene {
        var scene = PhotoScene()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let classify = VNClassifyImageRequest()
        if (try? handler.perform([classify])) != nil {
            scene.labels = (classify.results ?? [])
                .filter { $0.confidence > 0.3 }
                .sorted { $0.confidence > $1.confidence }
                .prefix(15)
                .map(\.identifier)
        }

        let animals = VNRecognizeAnimalsRequest()
        if (try? handler.perform([animals])) != nil {
            scene.animals = (animals.results ?? []).compactMap { observation in
                observation.labels.first { $0.confidence > 0.5 }?.identifier.lowercased()
            }
        }

        let faces = VNDetectFaceRectanglesRequest()
        if (try? handler.perform([faces])) != nil {
            scene.faceCount = faces.results?.count ?? 0
        }

        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        if (try? handler.perform([text])) != nil {
            let lines = (text.results ?? []).compactMap { observation -> (text: String, height: CGFloat)? in
                guard let string = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
                      looksLikeWords(string) else { return nil }
                return (string, observation.boundingBox.height)
            }
            scene.textLines = lines.sorted { $0.height > $1.height }.prefix(4).map(\.text)
        }

        scene.brightness = averageBrightness(image)
        scene.isScreenshot = scene.labels.contains("screenshot")
        return scene
    }

    // MARK: Caption

    /// Turns what Vision saw into one short phrase, e.g. "a photo of a dog on grass outdoors in
    /// daylight" or "a screenshot with the text "Flight delayed"". Pure, so it's unit-tested.
    static func caption(for scene: PhotoScene) -> String {
        let labels = scene.labels
        let headline = scene.textLines.first.map(shortQuote)

        if scene.isScreenshot {
            return headline.map { "a screenshot with the text \"\($0)\"" } ?? "a screenshot"
        }
        if let kind = documentKind(labels: labels, lineCount: scene.textLines.count, hasSubject: hasLivingSubject(scene)) {
            return headline.map { "a photo of \(kind) that says \"\($0)\"" } ?? "a photo of \(kind)"
        }

        let setting = labels.lazy.compactMap { settings[$0] }.first
        let subject = subject(for: scene)
        var parts: [String] = []
        if let subject {
            parts.append("a photo of \(subject)")
            if let setting { parts.append(setting.phrase) }
        } else if let setting {
            parts.append("a photo of \(setting.noun)")
        } else if let generic = labels.lazy.compactMap({ genericNouns[$0] }).first {
            parts.append("a photo of \(generic)")
        } else {
            parts.append("a photo")
        }

        let outdoor = labels.contains("outdoor") || (setting?.outdoors ?? false)
        let indoor = !outdoor && (labels.contains("interior_room") || labels.contains("interior_shop") || setting?.indoors == true)
        if subject != nil, labels.contains("outdoor"), setting?.outdoors != true { parts.append("outdoors") }
        if subject != nil, indoor, setting == nil { parts.append("indoors") }
        if let time = timeOfDay(labels: labels, brightness: scene.brightness, outdoor: outdoor),
           !parts[0].contains("sunset"), !parts[0].contains("night sky") {
            parts.append(time)
        }
        if let headline { parts.append("with the words \"\(headline)\"") }
        return parts.joined(separator: " ")
    }

    /// Animals and people first (counted), else the most confident label that names a thing.
    private static func subject(for scene: PhotoScene) -> String? {
        var subjects: [String] = []
        if !scene.animals.isEmpty {
            let counts = Dictionary(grouping: scene.animals, by: { $0 }).mapValues(\.count)
            subjects += counts.keys.sorted().map { counted($0, counts[$0] ?? 1) }
        }
        if scene.faceCount > 0 {
            subjects.append(scene.faceCount >= 5 ? "a group of people" : counted("person", scene.faceCount, plural: "people"))
        } else if let person = scene.labels.first(where: { peopleNouns[$0] != nil }).flatMap({ peopleNouns[$0] }) {
            subjects.append(person)
        }
        if subjects.isEmpty, let label = scene.labels.first(where: { isSpecific($0) && settings[$0] == nil }) {
            subjects.append(withArticle(displayName(label)))
        }
        guard !subjects.isEmpty else { return nil }
        return subjects.prefix(2).joined(separator: " and ")
    }

    private static func hasLivingSubject(_ scene: PhotoScene) -> Bool {
        !scene.animals.isEmpty || scene.faceCount > 0
    }

    private static func documentKind(labels: [String], lineCount: Int, hasSubject: Bool) -> String? {
        if labels.contains("receipt") { return "a receipt" }
        if labels.contains("handwriting") { return "a handwritten note" }
        if labels.contains("document") || labels.contains("printed_page") || (lineCount >= 3 && !hasSubject) {
            return "a page of text"
        }
        return nil
    }

    private static func timeOfDay(labels: [String], brightness: Double?, outdoor: Bool) -> String? {
        if labels.contains("sunset_sunrise") { return "at sunset" }
        if labels.contains("night_sky") || (brightness ?? 0.5) < 0.15 { return outdoor ? "at night" : "in dim light" }
        if labels.contains("daytime") || labels.contains("blue_sky") || (outdoor && (brightness ?? 0) > 0.45) {
            return outdoor || labels.contains("blue_sky") ? "in daylight" : nil
        }
        return nil
    }

    /// Fast text recognition also "reads" patterns and tiny print as junk like "kgml Vnh&bYq". Keep a
    /// line only if at least half its pieces look like words (letters, a vowel, 2+ long).
    static func looksLikeWords(_ line: String) -> Bool {
        let pieces = line.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
        guard line.filter(\.isLetter).count >= 3, !pieces.isEmpty else { return false }
        let words = pieces.filter { piece in
            piece.count >= 2 && piece.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" }
                && piece.lowercased().contains { "aeiouy".contains($0) }
        }
        return words.count * 2 >= pieces.count
    }

    /// "Flight delayed to 9:40 because of weather" -> "Flight delayed to 9:40 because of..."
    private static func shortQuote(_ text: String) -> String {
        let words = text.replacingOccurrences(of: "\"", with: "'").split(separator: " ")
        let short = words.prefix(6).joined(separator: " ")
        return words.count > 6 ? short + "..." : short
    }

    private static func counted(_ noun: String, _ count: Int, plural: String? = nil) -> String {
        let numbers = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        if count == 1 { return withArticle(noun) }
        let word = count < numbers.count ? numbers[count] : "\(count)"
        return "\(word) \(plural ?? noun + "s")"
    }

    private static func withArticle(_ noun: String) -> String {
        if massNouns.contains(noun) { return noun }
        let vowel = noun.first.map { "aeiou".contains($0) } ?? false
        return (vowel ? "an " : "a ") + noun
    }

    private static func isSpecific(_ label: String) -> Bool {
        genericNouns[label] == nil && !ignoredLabels.contains(label) && peopleNouns[label] == nil
    }

    private static func displayName(_ label: String) -> String {
        renamed[label] ?? label.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: Pixels

    private static func wasScreenshot(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let comment = exif[kCGImagePropertyExifUserComment] as? String else { return false }
        return comment.localizedCaseInsensitiveContains("screenshot")
    }

    /// JPEG has no transparency, so see-through pixels go on white instead of black.
    private static func flattened(_ image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return nil
        default: break
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    static func averageBrightness(_ image: CGImage) -> Double? {
        let side = 16
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var total = 0.0
        for pixel in 0..<(side * side) {
            let r = Double(pixels[pixel * 4]), g = Double(pixels[pixel * 4 + 1]), b = Double(pixels[pixel * 4 + 2])
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return total / Double(side * side) / 255
    }

    // MARK: Vocabulary (Vision classifier identifiers)

    /// Places: the noun when the place is the photo, the phrase when something is in it.
    private static let settings: [String: (noun: String, phrase: String, outdoors: Bool, indoors: Bool)] = [
        "beach": ("a beach", "at the beach", true, false), "shore": ("the shore", "by the shore", true, false),
        "ocean": ("the sea", "by the sea", true, false), "lake": ("a lake", "by a lake", true, false),
        "river": ("a river", "by a river", true, false), "creek": ("a creek", "by a creek", true, false),
        "waterfall": ("a waterfall", "by a waterfall", true, false), "harbour": ("a harbor", "at a harbor", true, false),
        "pier": ("a pier", "on a pier", true, false), "dock": ("a dock", "on a dock", true, false),
        "forest": ("a forest", "in a forest", true, false), "jungle": ("a jungle", "in a jungle", true, false),
        "mountain": ("mountains", "in the mountains", true, false), "hill": ("a hill", "on a hill", true, false),
        "canyon": ("a canyon", "in a canyon", true, false), "desert": ("a desert", "in the desert", true, false),
        "cliff": ("a cliff", "on a cliff", true, false), "island": ("an island", "on an island", true, false),
        "park": ("a park", "in a park", true, false), "garden": ("a garden", "in a garden", true, false),
        "grass": ("grass", "on grass", false, false), "snow": ("snow", "in the snow", true, false),
        "sand": ("sand", "on sand", false, false), "trail": ("a trail", "on a trail", true, false),
        "farm": ("a farm", "on a farm", true, false), "orchard": ("an orchard", "in an orchard", true, false),
        "street": ("a street", "on a street", true, false), "road": ("a road", "on a road", true, false),
        "alley": ("an alley", "in an alley", true, false), "cityscape": ("a city", "in a city", true, false),
        "sidewalk": ("a sidewalk", "on a sidewalk", true, false), "playground": ("a playground", "at a playground", true, false),
        "underwater": ("the water", "underwater", false, false),
        "kitchen_room": ("a kitchen", "in a kitchen", false, true), "kitchen": ("a kitchen", "in a kitchen", false, true),
        "bedroom": ("a bedroom", "in a bedroom", false, true), "living_room": ("a living room", "in a living room", false, true),
        "dining_room": ("a dining room", "in a dining room", false, true), "bathroom_room": ("a bathroom", "in a bathroom", false, true),
        "classroom": ("a classroom", "in a classroom", false, true), "library": ("a library", "in a library", false, true),
        "restaurant": ("a restaurant", "at a restaurant", false, true), "museum": ("a museum", "at a museum", false, true),
        "interior_shop": ("a shop", "in a shop", false, true), "cubicle": ("an office", "at an office", false, true),
        "bed": ("a bed", "on a bed", false, true), "sofa": ("a sofa", "on a sofa", false, true),
        "desk": ("a desk", "on a desk", false, true), "table": ("a table", "on a table", false, true),
    ]

    /// Labels too broad to name the subject, with a friendly noun for when nothing better shows up.
    private static let genericNouns: [String: String] = [
        "food": "some food", "drink": "a drink", "fruit": "some fruit", "vegetable": "some vegetables",
        "dessert": "a dessert", "baked_goods": "some baked goods", "plant": "some plants", "vegetation": "some plants",
        "foliage": "some leaves", "flower": "a flower", "building": "a building",
        "vehicle": "a vehicle", "conveyance": "a vehicle", "sky": "the sky", "blue_sky": "a blue sky",
        "cloudy": "a cloudy sky", "night_sky": "the night sky", "sunset_sunrise": "a sunset", "water": "water",
        "water_body": "water", "art": "some art", "illustrations": "a drawing", "furniture": "some furniture",
        "clothing": "some clothes", "animal": "an animal", "bird": "a bird", "insect": "an insect",
        "fish": "a fish", "toy": "a toy", "games": "a game",
    ]

    /// Labels that never name anything (they describe the scene, which is handled elsewhere).
    private static let ignoredLabels: Set<String> = [
        "mammal", "canine", "feline", "arthropods", "reptile", "material", "liquid", "machine", "consumer_electronics",
        "housewares", "tableware", "utensil", "container", "sport", "recreation", "entertainer", "celebration",
        "performance", "light", "land", "daytime", "outdoor", "interior_room", "domicile", "decoration",
        "wood_natural", "wood_processed", "textile", "raw_glass", "celestial_body", "celestial_body_other",
        "document", "screenshot", "printed_page", "handwriting", "receipt", "media", "waterways", "haze", "frozen",
        "adult_cat", "ungulates", "rodent", "marsupial", "cetacean", "cephalopod", "gastropod", "mollusk", "shellfish",
        "poultry", "seasonings", "herb", "spice", "grain", "nut", "berry", "citrus_fruit", "string_instrument",
        "woodwind", "brass_music", "musical_instrument", "sports_equipment", "ballgames", "watersport",
        "winter_sport", "engine_vehicle", "watercraft", "aircraft", "road_safety_equipment",
        // Parent labels that would hide the specific one ("raptor" over "owl", "music" over "guitar").
        "raptor", "music", "structure",
    ]

    private static let peopleNouns: [String: String] = [
        "people": "people", "adult": "a person", "child": "a child", "baby": "a baby", "teen": "a teenager",
        "crowd": "a crowd of people",
    ]

    private static let renamed: [String: String] = [
        "tea_drink": "tea", "cake_regular": "cake", "house_single": "house", "pot_cooking": "cooking pot",
        "computer_monitor": "computer screen", "coyote_wolf": "wolf", "alligator_crocodile": "crocodile",
        "pepper_veggie": "pepper", "snake_other": "snake", "chair_other": "chair", "candy_other": "candy",
        "road_other": "road", "glove_other": "glove", "train_real": "train", "basket_container": "basket",
        "balloon_hotair": "hot air balloon", "christmas_decoration": "holiday decoration",
        "straw_drinking": "drinking straw", "straw_hay": "hay", "play_card": "playing card",
        "jack_o_lantern": "jack-o'-lantern", "stuffed_animals": "stuffed animal", "swing_playground": "swing",
        "slide_toy": "slide", "train_toy": "toy train", "vehicle_toy": "toy car", "drinking_glass": "glass",
        "electric_fan": "fan", "coffee_bean": "coffee beans", "chocolate_chip": "chocolate chips",
        "speakers_music": "speakers", "organ_instrument": "organ", "health_club": "gym",
        "crane_construction": "crane", "weight_scale": "scale", "track_rail": "railway track",
        "shellfish_prepared": "shellfish", "steamer_cookware": "steamer", "iron_clothing": "iron",
        "jockey_horse": "horse", "drone_machine": "drone", "formula_one_car": "race car",
        "submarine_water": "submarine", "bernese_mountain": "Bernese mountain dog", "fencing_sport": "fencing",
        "cricket_sport": "cricket",
    ]

    private static let massNouns: Set<String> = [
        "coffee", "tea", "soup", "rice", "pasta", "salad", "bread", "cheese", "ice cream", "chocolate", "popcorn",
        "sushi", "spaghetti", "cereal", "oatmeal", "yogurt", "honey", "juice", "wine", "beer", "red wine",
        "white wine", "fries", "nachos", "fireworks", "seaweed", "moss", "ivy", "ramen", "curry", "risotto", "paella",
        "hummus", "guacamole", "candy", "meat", "seafood", "jewelry", "money", "currency", "music", "graffiti",
        "cake", "pie", "steak", "bacon", "pizza", "toast", "laundry", "luggage", "jeans", "rain", "lava", "smoke",
        "hay", "bubble tea", "coffee beans", "chocolate chips", "stained glass", "green beans", "grilled chicken",
        "white bread", "sunflower seeds", "tapioca pearls", "office supplies", "fencing", "cricket", "ping pong",
        "rock climbing", "ice skating", "speakers", "shellfish",
        // Plural labels and activities read wrong with "a" in front.
        "rocks", "oranges", "puzzles", "blocks", "billboards", "dice", "sunglasses", "eyeglasses", "headphones",
        "earmuffs", "goggles", "scissors", "pliers", "binoculars", "chopsticks", "shoes", "rollerskates", "stairs",
        "bowling", "golf", "archery", "tennis", "soccer", "hockey", "skiing", "surfing", "swimming", "cycling",
        "hiking", "camping", "fishing", "sailing", "yoga", "dancing", "karaoke", "ballet", "boxing", "wrestling",
        "badminton", "gingerbread", "origami",
    ]
}
