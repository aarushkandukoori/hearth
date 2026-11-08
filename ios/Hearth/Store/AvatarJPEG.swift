// Turns any picture (HEIC, PNG, JPEG...) into a small, clean avatar JPEG: the right way up, at most
// 1024 px, on an opaque background, and with no metadata at all (no location, camera or date).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AvatarJPEG {
    static func make(from data: Data, maxPixels: Int = 1024, quality: Double = 0.85) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw LibraryError.imageUnreadable
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // applies the photo's rotation
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw LibraryError.imageUnreadable }

        // JPEG has no transparency, so transparent parts show Hearth's dark surface color.
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(red: 0x1D / 255.0, green: 0x19 / 255.0, blue: 0x16 / 255.0, alpha: 1)
        context.fill(rect)
        context.draw(image, in: rect)
        guard let flat = context.makeImage() else { throw LibraryError.imageUnreadable }

        // Only the pixels go in (a bare CGImage), so no metadata from the original can come along.
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LibraryError.imageUnreadable
        }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LibraryError.imageUnreadable }
        return output as Data
    }
}
