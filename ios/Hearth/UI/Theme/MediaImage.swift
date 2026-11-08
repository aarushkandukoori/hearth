// A photo or picture from the private media folder, decoded off the main thread, fading in when ready.
// With `.fill` it fills (and clips to) the frame you give it; with `.fit` it keeps the image's shape.

import SwiftUI

struct MediaImage: View {
    private let relativePath: String
    private let contentMode: ContentMode

    /// Pictures are saved at most 1600 px wide, so this decodes them at full quality.
    private static let maxPixel = 1600

    init(relativePath: String, contentMode: ContentMode = .fill) {
        self.relativePath = relativePath
        self.contentMode = contentMode
    }

    var body: some View {
        HearthCachedImage(source: .media(relativePath), maxPixel: Self.maxPixel) { phase in
            switch phase {
            case .loaded(let image):
                picture(image).transition(.opacity)
            case .loading:
                placeholder(symbol: nil)
            case .failed:
                placeholder(symbol: "photo")
            }
        }
    }

    @ViewBuilder
    private func picture(_ image: UIImage) -> some View {
        if contentMode == .fill {
            Color.clear
                .overlay { Image(uiImage: image).resizable().scaledToFill() }
                .clipped()
        } else {
            Image(uiImage: image).resizable().scaledToFit()
        }
    }

    @ViewBuilder
    private func placeholder(symbol: String?) -> some View {
        let box = Rectangle()
            .fill(Color.hearthSurface2)
            .overlay {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(.hearthMuted)
                        .accessibilityLabel("Picture unavailable")
                }
            }
        if contentMode == .fit {
            box.aspectRatio(4.0 / 3.0, contentMode: .fit) // size unknown until it loads
        } else {
            box
        }
    }
}
