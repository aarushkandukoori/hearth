// Shows the lock screen and the app-switcher shield in their own window above the app,
// so they also cover sheets (Create) and the full-screen call, which a view in RootView can't.
// While locked, that window also takes the keyboard and VoiceOver, so nothing underneath can be reached.

import SwiftUI
import UIKit

@MainActor
final class PrivacyOverlay {
    static let shared = PrivacyOverlay()
    private var window: UIWindow?

    /// Call whenever the vault's lock or shield state changes.
    func update(app: AppModel) {
        let locked = app.vault.isLocked
        if locked || app.vault.shieldVisible {
            if window == nil, let scene = activeScene() {
                let overlay = UIWindow(windowScene: scene)
                overlay.windowLevel = .alert + 1
                let host = UIHostingController(rootView: PrivacyOverlayView().environment(app).environment(app.router))
                host.view.backgroundColor = .clear
                host.view.accessibilityViewIsModal = true
                overlay.rootViewController = host
                overlay.isHidden = false
                window = overlay
            }
        } else if let overlay = window {
            overlay.isHidden = true
            window = nil
        }
        fenceOffApp(locked && window != nil)
    }

    /// While locked: VoiceOver can't move into the chats underneath, and a composer that had focus can't bring
    /// its keyboard (with QuickType guesses from the draft) back above the lock screen. Undone on unlock.
    private func fenceOffApp(_ fenced: Bool) {
        guard let scene = window?.windowScene ?? activeScene() else { return }
        let appWindows = scene.windows.filter { $0 !== window && $0.windowLevel == .normal }
        for appWindow in appWindows { appWindow.accessibilityElementsHidden = fenced }
        if fenced {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            window?.makeKey()
        } else if let main = appWindows.first, !main.isKeyWindow {
            main.makeKey()
        }
    }

    private func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
}

private struct PrivacyOverlayView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            if app.vault.isLocked {
                LockView()
                    .transition(.opacity)
            } else if app.vault.shieldVisible {
                PrivacyShieldView()
            }
        }
        .animation(.smooth(duration: 0.25), value: app.vault.isLocked)
    }
}
