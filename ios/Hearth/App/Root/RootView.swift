// Root of the app: onboarding gate, the five tabs, create sheet, call cover, lock and shield.

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var router = app.router
        ZStack {
            if app.settings.onboardingDone {
                tabs(router: router)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: app.settings.onboardingDone)
        .tint(.hearthAccentText)
        // Lock screen and app-switcher shield live in their own window above sheets and calls. Both are watched:
        // locking while the shield already shows still has to fence off the app underneath.
        .onChange(of: [app.vault.isLocked, app.vault.shieldVisible], initial: true) { _, _ in
            PrivacyOverlay.shared.update(app: app)
        }
        .task {
            await app.boot()
            if LaunchOptions.shared.uiTour { await UITour.run(app: app) }
        }
        .onChange(of: scenePhase) { _, phase in app.handleScenePhase(phase) }
    }

    @ViewBuilder
    private func tabs(router: Router) -> some View {
        @Bindable var router = router
        TabView(selection: tabSelection(router)) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack(path: $router.homePath) {
                    HomeView().withRoutes()
                }
            }
            Tab("Town", systemImage: "map.fill", value: AppTab.town) {
                NavigationStack(path: $router.townPath) {
                    TownView().withRoutes()
                }
            }
            .badge(app.events.unseenCount)
            Tab("Create", systemImage: "plus.circle.fill", value: AppTab.create) {
                Color.clear
            }
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: AppTab.chats) {
                NavigationStack(path: $router.chatsPath) {
                    ChatsListView().withRoutes()
                }
            }
            Tab("You", systemImage: "person.crop.circle.fill", value: AppTab.you) {
                NavigationStack(path: $router.youPath) {
                    SettingsView().withRoutes()
                }
            }
        }
        .sheet(item: $router.createSheet) { sheet in
            NavigationStack {
                CreateCharacterView(editingID: sheet.editingID)
            }
        }
        .fullScreenCover(item: callBinding(router)) { call in
            CallView(conversationID: call.id)
        }
    }

    /// The Create tab acts like a button: it opens the create sheet and keeps the current tab.
    private func tabSelection(_ router: Router) -> Binding<AppTab> {
        Binding(
            get: { router.tab },
            set: { newTab in
                if newTab == .create {
                    router.createSheet = Router.CreateSheet(editingID: nil)
                } else {
                    router.tab = newTab
                }
            }
        )
    }

    private struct CallItem: Identifiable { let id: UUID }

    private func callBinding(_ router: Router) -> Binding<CallItem?> {
        Binding(
            get: { router.callConversationID.map(CallItem.init) },
            set: { router.callConversationID = $0?.id }
        )
    }
}

/// Maps every AppRoute to its screen.
struct RouteDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .profile(let id): CharacterProfileView(characterID: id)
        case .chat(let id): ChatView(conversationID: id)
        case .startChat(let id): StartChatView(characterID: id, fresh: false)
        case .newChat(let id): StartChatView(characterID: id, fresh: true)
        case .scene(let id): SceneView(locationID: id)
        case .create(let id): CreateCharacterView(editingID: id)
        case .memories(let id): MemoriesView(characterID: id)
        case .search(let query): SearchResultsView(query: query)
        case .settings(let page): SettingsPageView(page: page)
        }
    }
}

extension View {
    /// Attach the app's route table to a NavigationStack root.
    func withRoutes() -> some View {
        navigationDestination(for: AppRoute.self) { RouteDestination(route: $0) }
    }
}
