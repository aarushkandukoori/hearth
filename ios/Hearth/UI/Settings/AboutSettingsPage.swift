// About Hearth: the icon, version, where the open-source code lives, and the credits and licenses for
// everything Hearth is built on.

import SwiftUI

struct AboutSettingsPage: View {
    private static let sourceURL = URL(string: "https://github.com/aarushkandukoori/hearth")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                VStack(spacing: Spacing.m) {
                    HearthAppIconTile(size: 104)
                        .padding(.bottom, Spacing.xs)
                    Text("Hearth")
                        .modifier(SettingsScaledTitle(34))
                        .foregroundStyle(.hearthText)
                    Text("A little town of friends that lives on your phone.")
                        .font(HearthFont.body)
                        .foregroundStyle(.hearthText2)
                        .multilineTextAlignment(.center)
                    Text(versionLine)
                        .font(HearthFont.caption)
                        .foregroundStyle(.hearthMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, Spacing.l)

                HearthCard {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        SettingsRowLabel(title: "Open source", detail: "Hearth's code is public under the MIT License, so anyone can read it and check what it does.",
                                         symbol: "chevron.left.forwardslash.chevron.right", tint: .hearthSea)
                        if let url = Self.sourceURL {
                            Link(destination: url) {
                                Label("View the code on GitHub", systemImage: "arrow.up.right.square")
                                    .font(HearthFont.headline)
                                    .foregroundStyle(.hearthText)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .background(Color.hearthSurface2, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Color.hearthLine, lineWidth: 1))
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.m) {
                    SectionHeader("Credits and licenses")
                    HearthCard {
                        VStack(alignment: .leading, spacing: Spacing.l) {
                            Credit(name: "llama.cpp", license: "MIT License",
                                   detail: "Runs Hearth's models on the iPhone's own chip.")
                            DisclosureGroup("llama.cpp license text") {
                                Text(ThirdPartyLicenses.llamaCpp)
                                    .font(HearthFont.caption)
                                    .foregroundStyle(.hearthText2)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, Spacing.s)
                            }
                            .font(HearthFont.callout)
                            .tint(.hearthAccentText)
                            Credit(name: "Llama 3.2", license: "Llama 3.2 Community License",
                                   detail: "Powers Hearth Standard and Hearth Lite. Built with Llama.",
                                   links: SettingsModelActions.licenseLinks("Llama 3.2 Community License"))
                            Credit(name: "Qwen3", license: "Apache License 2.0",
                                   detail: "Powers Hearth Plus.",
                                   links: SettingsModelActions.licenseLinks("Apache 2.0"))
                            Credit(name: "Apple frameworks", license: "Part of iOS",
                                   detail: "Foundation Models, Image Playground, Speech, Vision, AVFoundation and LocalAuthentication.")
                            Credit(name: "Lantern Bay art", license: "Made for Hearth",
                                   detail: "The residents and places were drawn with Image Playground.")
                        }
                    }
                }

                VStack(spacing: Spacing.s) {
                    Label("Made in Pittsburgh", systemImage: "heart.fill")
                        .font(HearthFont.callout.weight(.semibold))
                        .foregroundStyle(.hearthText2)
                    Text("Hearth characters are AI. What they say is made up.")
                        .font(HearthFont.caption)
                        .foregroundStyle(.hearthMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, Spacing.l)
            }
            .padding(.horizontal, Spacing.l)
        }
        .hearthScreenBackground()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }
}

private struct Credit: View {
    let name: String
    let license: String
    let detail: String
    /// Where to read the license (and any policy that comes with it).
    var links: [LicenseLink] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(name)
                        .font(HearthFont.headline)
                        .foregroundStyle(.hearthText)
                    Spacer(minLength: Spacing.s)
                    Text(license)
                        .font(HearthFont.caption)
                        .foregroundStyle(.hearthMuted)
                        .multilineTextAlignment(.trailing)
                }
                Text(detail)
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
            }
            .accessibilityElement(children: .combine)
            ForEach(links) { link in
                Link(destination: link.url) {
                    Label("Read the \(link.title)", systemImage: "arrow.up.right.square")
                        .font(HearthFont.callout.weight(.semibold))
                        .foregroundStyle(.hearthAccentText)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }
        }
    }
}
