// App-wide navigation. Every screen pushes `AppRoute` values; RootView maps them to views.

import SwiftUI

enum AppTab: String, Hashable, CaseIterable {
    case home, town, create, chats, you
}

enum AppRoute: Hashable {
    /// Character profile page.
    case profile(characterID: String)
    /// Open an existing conversation.
    case chat(conversationID: UUID)
    /// Open the latest chat with this character, or start one.
    case startChat(characterID: String)
    /// Always start a fresh chat with this character.
    case newChat(characterID: String)
    /// Group scene at a town location.
    case scene(locationID: String)
    /// Create a character (nil) or edit a user character.
    case create(editingID: String?)
    /// What a character remembers about the user.
    case memories(characterID: String)
    /// Search results page.
    case search(query: String)
    /// A Settings sub-page.
    case settings(SettingsPage)
}

enum SettingsPage: String, Hashable, CaseIterable {
    case persona, model, voice, pictures, privacy, safety, about
}

/// Navigation state shared by all tabs. Views read it with `@Environment(Router.self)`.
@MainActor @Observable final class Router {
    var tab: AppTab = .home
    var homePath: [AppRoute] = []
    var townPath: [AppRoute] = []
    var chatsPath: [AppRoute] = []
    var youPath: [AppRoute] = []
    /// Conversation shown in the full-screen voice call, if any.
    var callConversationID: UUID?
    /// Create sheet (the Create tab opens this instead of switching tabs).
    var createSheet: CreateSheet?

    struct CreateSheet: Identifiable, Hashable {
        var id = UUID()
        var editingID: String?
    }

    /// Push a route on the current tab's stack (Create routes open the sheet instead).
    func open(_ route: AppRoute) {
        if case .create(let editingID) = route {
            createSheet = CreateSheet(editingID: editingID)
            return
        }
        switch tab {
        case .home, .create: homePath.append(route)
        case .town: townPath.append(route)
        case .chats: chatsPath.append(route)
        case .you: youPath.append(route)
        }
    }

    /// Switch tab and show a route there.
    func show(_ route: AppRoute, in tab: AppTab) {
        guard tab != self.tab else { open(route); return }
        self.tab = tab
        // Switching the tab and pushing on its stack in one transaction can leave the tab bar hidden,
        // so the push waits for the next main-queue turn.
        DispatchQueue.main.async { self.open(route) }
    }

    func popToRoot() {
        switch tab {
        case .home, .create: homePath.removeAll()
        case .town: townPath.removeAll()
        case .chats: chatsPath.removeAll()
        case .you: youPath.removeAll()
        }
    }

    func startCall(conversationID: UUID) { callConversationID = conversationID }
    func endCall() { callConversationID = nil }
}
