// Opens the latest chat with a character, or starts one (always a new one when `fresh`), exactly once,
// then shows it. A "fresh" chat reuses the latest one if nobody has written in it yet.

import SwiftUI

struct StartChatView: View {
    let characterID: String
    let fresh: Bool
    @Environment(AppModel.self) private var app
    @State private var conversationID: UUID?
    @State private var missing = false

    var body: some View {
        Group {
            if let conversationID {
                ChatView(conversationID: conversationID)
            } else if missing {
                EmptyStateView(symbol: "person.crop.circle.badge.questionmark",
                               title: "This character isn't here",
                               message: "They may have been deleted. Everyone else in Lantern Bay is still around.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .hearthScreenBackground()
        .onAppear(perform: resolve)
    }

    /// Runs on the first appearance only, so going back and forth never makes a second chat.
    private func resolve() {
        guard conversationID == nil, !missing else { return }
        guard let character = app.library.character(characterID) else {
            missing = true
            return
        }
        let latest = app.chats.latestDirect(with: characterID)
        if let latest, !fresh || !latest.messages.contains(where: { $0.role == .user }) {
            conversationID = latest.id
        } else {
            conversationID = app.chats.startDirect(with: character, persona: app.settings.persona).id
        }
    }
}
