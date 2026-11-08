// One page of the You tab, picked by `SettingsPage` (RootView maps `.settings(page)` here).

import SwiftUI

struct SettingsPageView: View {
    let page: SettingsPage

    var body: some View {
        Group {
            switch page {
            case .persona: PersonaSettingsPage()
            case .model: ModelSettingsPage()
            case .voice: VoiceSettingsPage()
            case .pictures: PicturesSettingsPage()
            case .privacy: PrivacyCenterPage()
            case .safety: SafetySettingsPage()
            case .about: AboutSettingsPage()
            }
        }
        // The Models buttons in chats, scenes and calls jump straight here from a screen that hid the tab bar.
        .toolbarVisibility(.visible, for: .tabBar)
    }
}
