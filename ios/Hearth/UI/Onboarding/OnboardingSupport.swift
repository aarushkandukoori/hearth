// Shared onboarding pieces: the answers gathered along the way, full-bleed town art, the scrolling page
// layout (art under the status bar, then text), and the icon-and-text fact rows.

import SwiftUI

/// What the person has chosen so far. Saved to settings only when they finish.
struct OnboardingDraft {
    var name = ""
    var about = ""
    var isAdult = false
    /// Off unless the person turns it on: what they tell one resident stays with that resident.
    var townGossip = false
    var engine: OnboardingEngineChoice?
    var friendID: String?

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedAbout: String { about.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The voice step's choice: a catalog model (by id), which Pie runs once it is downloaded.
enum OnboardingEngineChoice: Hashable {
    case model(String)
}

/// Bundled town art that fills whatever frame it gets (decoded off the main thread, faded in).
struct OnboardingArt: View {
    let name: String

    var body: some View {
        Color.hearthSurface2
            .overlay {
                HearthCachedImage(source: .bundled(name), maxPixel: 1024) { phase in
                    if case .loaded(let image) = phase {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    }
                }
            }
            .clipped()
            .accessibilityHidden(true)
    }
}

/// Art across the top of a page that fades into the background, with a light scrim so the status bar reads.
struct OnboardingArtBand: View {
    let name: String
    let height: CGFloat

    var body: some View {
        OnboardingArt(name: name)
            .frame(height: height)
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 110)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, Color.hearthBackground], startPoint: .top, endPoint: .bottom)
                    .frame(height: height * 0.5)
            }
    }
}

/// A page body that scrolls: optional art at the very top (behind the status bar), then the content.
/// Pages without art leave room at the top for the back button.
struct OnboardingPageScroll<Content: View>: View {
    var art: String?
    var artHeight: CGFloat = 320
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if let art {
                    OnboardingArtBand(name: art, height: artHeight)
                        .padding(.bottom, -Spacing.xxl) // let the title sit on the faded edge
                } else {
                    Color.clear.frame(height: 52)
                }
                content
                    .padding(.horizontal, Spacing.xl)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .ignoresSafeArea(edges: art == nil ? [] : .top)
    }
}

/// The big serif title and the line under it.
struct OnboardingTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title)
                .modifier(SettingsScaledTitle(32, cap: 1.6))
                .foregroundStyle(.hearthText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(HearthFont.body)
                    .foregroundStyle(.hearthText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// An icon with a short title and a line of detail.
struct OnboardingFactRow: View {
    let symbol: String
    var tint: Color = .hearthSuccess
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            SettingsIcon(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText)
                Text(detail)
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
