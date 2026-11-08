// Reads the text chunks of a PNG file. Character cards hide their JSON (usually base64) in a tEXt or
// iTXt chunk named "chara" (V2) or "ccv3" (V3), next to the character's picture.

import Foundation

enum CardPNGText {
    static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    static func isPNG(_ data: Data) -> Bool {
        data.starts(with: signature)
    }

    /// Text chunks as lowercased keyword -> text. The first chunk wins when a keyword repeats.
    static func textChunks(in data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var result: [String: String] = [:]
        var offset = signature.count
        // Each chunk: 4-byte big-endian length, 4-byte type, body, 4-byte CRC.
        while offset + 12 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            let bodyStart = offset + 8
            guard bodyStart + length + 4 <= bytes.count else { break }
            let body = Array(bytes[bodyStart..<bodyStart + length])
            let entry: (keyword: String, text: String)?
            switch type {
            case "tEXt": entry = parseText(body)
            case "iTXt": entry = parseInternationalText(body)
            case "IEND": return result
            default: entry = nil
            }
            if let entry, result[entry.keyword] == nil { result[entry.keyword] = entry.text }
            offset = bodyStart + length + 4
        }
        return result
    }

    /// The card JSON inside a chunk: base64 (the usual form, standard or URL-safe) or plain JSON.
    static func cardJSON(fromChunkText text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return Data(trimmed.utf8) }
        var base64 = trimmed.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    // tEXt: keyword, 0, Latin-1 text.
    private static func parseText(_ body: [UInt8]) -> (keyword: String, text: String)? {
        guard let zero = body.firstIndex(of: 0),
              let keyword = String(bytes: body[..<zero], encoding: .isoLatin1),
              let text = String(bytes: body[(zero + 1)...], encoding: .isoLatin1) else { return nil }
        return (keyword.lowercased(), text)
    }

    // iTXt: keyword, 0, compressed flag, method, language tag, 0, translated keyword, 0, UTF-8 text
    // (zlib-compressed when the flag is 1).
    private static func parseInternationalText(_ body: [UInt8]) -> (keyword: String, text: String)? {
        guard let keywordEnd = body.firstIndex(of: 0), keywordEnd + 2 < body.count else { return nil }
        let keyword = String(decoding: body[..<keywordEnd], as: UTF8.self)
        let compressed = body[keywordEnd + 1] == 1
        let afterMethod = body[(keywordEnd + 3)...]
        guard let languageEnd = afterMethod.firstIndex(of: 0) else { return nil }
        let afterLanguage = body[(languageEnd + 1)...]
        guard let translatedEnd = afterLanguage.firstIndex(of: 0) else { return nil }
        let raw = Data(body[(translatedEnd + 1)...])
        guard let textData = compressed ? inflateZlib(raw) : raw,
              let text = String(data: textData, encoding: .utf8) else { return nil }
        return (keyword.lowercased(), text)
    }

    /// zlib = 2-byte header + DEFLATE data + 4-byte checksum. Apple's .zlib codec reads the DEFLATE part.
    private static func inflateZlib(_ data: Data) -> Data? {
        guard data.count > 6 else { return nil }
        let deflate = Data(data.dropFirst(2).dropLast(4))
        return try? (deflate as NSData).decompressed(using: .zlib) as Data
    }
}
