// App entry point.

import SwiftUI

@main
struct HearthApp: App {
    @UIApplicationDelegateAdaptor(HearthAppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.router)
        }
    }
}

final class HearthAppDelegate: NSObject, UIApplicationDelegate {
    /// Lets the background model download finish while Hearth is suspended.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        ModelDownloader.handleEventsForBackgroundURLSession(identifier: identifier, completion: completionHandler)
    }
}
