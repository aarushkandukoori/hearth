// The Pictures page: whether characters send pictures. Pictures come from the town's own art or are
// postcards drawn on the phone; Hearth uses no image model from another company.

import SwiftUI

struct PicturesSettingsPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var store = app.settingsStore
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                HearthCard {
                    Toggle(isOn: $store.settings.picturesEnabled) {
                        SettingsRowLabel(title: "Pictures from characters",
                                         detail: "Now and then a friend sends a picture: one from the town's own art that fits what they're talking about, or a postcard.",
                                         symbol: "photo.on.rectangle.angled.fill", tint: .hearthGold)
                    }
                }

                HearthCard {
                    Label {
                        Text("Pictures come from the town's own art or a postcard. Pie, the engine Hearth runs on, can draw pictures too, but on a phone it runs one model at a time, and that model is your friends' voice.")
                            .font(HearthFont.callout)
                            .foregroundStyle(.hearthText2)
                    } icon: {
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(.hearthGold)
                    }
                }

                Text("Pictures never show people. Lantern Bay is a town of animal folk. Nothing is drawn or sent in the cloud.")
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthMuted)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.l)
        }
        .hearthScreenBackground()
        .navigationTitle("Pictures")
        .navigationBarTitleDisplayMode(.inline)
    }
}
