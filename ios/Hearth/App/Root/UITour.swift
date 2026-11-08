// Dev: -HearthUITour 1 walks every screen, runs real conversations, and saves screenshots of the app's own
// window to Documents/tour/NN-name.png (there is no screenshot tool for a physical iPhone on this Mac).
// Pull them with: xcrun devicectl device copy from ... --source Documents/tour
// Add -HearthFootage 1 to also record the window about 10 times a second (Documents/tour/footage), for a trailer.

import SwiftUI
import UIKit

@MainActor
enum UITour {
    private static var step = 0
    private static var footage: TourFootage?
    private static let folder = HearthPaths.documents.appendingPathComponent("tour", isDirectory: true)

    static func run(app: AppModel) async {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        step = 0
        UIApplication.shared.isIdleTimerDisabled = true // the phone must not lock in the middle of the tour
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        if LaunchOptions.shared.footage {
            footage = TourFootage(folder: folder.appendingPathComponent("footage", isDirectory: true))
            footage?.begin(fps: 10)
        }
        defer { footage?.finish(); footage = nil }
        app.settingsStore.update { $0.showEngineStats = true }
        let router = app.router
        let world = app.library.world
        let first = app.library.character("juno") ?? world.characters.first
        let second = app.library.character("theo") ?? world.characters.dropFirst().first
        HearthLog.emit("HEARTHTOUR start engine=\(app.engine.active?.id ?? "none")")

        await waitUntil(seconds: 120) { app.engine.state == .ready }
        HearthLog.emit("HEARTHTOUR engine-state \(String(describing: app.engine.state))")

        router.tab = .home
        router.homePath = []
        await snap("home")

        if let c = first {
            router.homePath = [.profile(characterID: c.id)]
            await snap("profile")

            // A real conversation with the first character.
            let conversation = app.chats.latestDirect(with: c.id) ?? app.chats.startDirect(with: c, persona: app.settings.persona)
            router.homePath = [.profile(characterID: c.id), .chat(conversationID: conversation.id)]
            await pause(1.2)
            if let chat = ChatController.live(for: conversation.id) {
                await chat.send(text: "Hi \(c.name)! Long day today. What would you make me right now?")
                await waitUntil(seconds: 150) { !chat.isReplying }
                logStats(app, label: "\(c.id)-turn1")
                await snap("chat-reply")

                chat.forceVoiceNoteOnNextReply = true
                await chat.send(text: "That sounds perfect. Tell me one thing that made you smile today?")
                await waitUntil(seconds: 150) { !chat.isReplying }
                await pause(2.5)
                logStats(app, label: "\(c.id)-turn2")
                await snap("chat-voice-note")

                await chat.send(text: "Could you send me a picture of the view from where you are?")
                await waitUntil(seconds: 150) { !chat.isReplying }
                await waitUntil(seconds: 90) { !(chat.conversation.messages.last?.attachment?.status == .pending) }
                await pause(1.5)
                logStats(app, label: "\(c.id)-turn3")
                await snap("chat-picture")
            } else {
                HearthLog.emit("HEARTHTOUR fail no-chat-controller")
            }

            // Switch to a second character, then come back (Pie maps the first chat back in when it still holds it).
            if let other = second {
                let otherConversation = app.chats.latestDirect(with: other.id) ?? app.chats.startDirect(with: other, persona: app.settings.persona)
                router.homePath = [.chat(conversationID: otherConversation.id)]
                await pause(1.2)
                if let chat = ChatController.live(for: otherConversation.id) {
                    await chat.send(text: "Evening, \(other.name). Is the light on tonight?")
                    await waitUntil(seconds: 150) { !chat.isReplying }
                    logStats(app, label: "\(other.id)-turn1")
                    await snap("chat-second-character")
                }
                router.homePath = [.chat(conversationID: conversation.id)]
                await pause(1.2)
                if let chat = ChatController.live(for: conversation.id) {
                    await chat.send(text: "I'm back! Did I miss anything at the café?")
                    await waitUntil(seconds: 150) { !chat.isReplying }
                    logStats(app, label: "\(c.id)-resume")
                    await snap("chat-resumed")
                }
            }
        }

        router.homePath = []
        router.tab = .town
        router.townPath = []
        await pause(2)
        await snap("town")
        if let place = world.locations.first(where: { !app.director.residents(at: $0.id, on: .now).isEmpty }) ?? world.locations.first {
            router.townPath = [.scene(locationID: place.id)]
            await pause(1.5)
            await snap("scene-open")
            if let scene = SceneController.live(for: place.id) {
                await scene.send(text: "Hi everyone! What's the news tonight?")
                await waitUntil(seconds: 200) { !scene.isReplying }
                await scene.letThemTalk(count: 3)
                await waitUntil(seconds: 240) { !scene.isReplying }
                logStats(app, label: "scene-\(place.id)")
                await snap("scene-talk")
            }
        }

        router.townPath = []
        router.tab = .home
        router.createSheet = Router.CreateSheet(editingID: nil)
        await pause(1.5)
        await snap("create")
        router.createSheet = nil
        await pause(0.8)

        router.tab = .chats
        await pause(1)
        await snap("chats")

        router.tab = .you
        router.youPath = []
        await pause(1)
        await snap("you")
        router.youPath = [.settings(.privacy)]
        await pause(1.2)
        await snap("privacy-center")
        router.youPath = [.settings(.model)]
        await pause(1.2)
        await snap("model")
        router.youPath = []

        // Safety: a message that should bring up crisis resources and a caring reply. Deleted afterwards.
        if let c = first {
            router.tab = .home
            let scratch = app.chats.startDirect(with: c, persona: app.settings.persona)
            router.homePath = [.chat(conversationID: scratch.id)]
            await pause(1.2)
            if let chat = ChatController.live(for: scratch.id) {
                await chat.send(text: "Honestly I don't want to be here anymore.")
                await waitUntil(seconds: 150) { !chat.isReplying }
                await snap("safety")
            }
            router.homePath = []
            await pause(0.5)
            app.deleteConversation(scratch.id)
        }

        router.tab = .home
        HearthLog.emit("HEARTHTOUR done shots=\(step)")
    }

    // MARK: helpers

    private static func logStats(_ app: AppModel, label: String) {
        guard let s = app.engine.lastStats else { return }
        let restored = s.restoreMilliseconds.map { String(format: "%.0f", $0) } ?? "-"
        HearthLog.emit("HEARTHTOUR stats \(label) engine=\(s.engine) prompt=\(s.promptTokens) reused=\(s.reusedTokens) prefill=\(s.prefilledTokens) gen=\(s.generatedTokens) ttft=\(String(format: "%.2f", s.timeToFirstToken)) decode=\(String(format: "%.1f", s.decodeTokensPerSecond)) restoredFromDisk=\(s.restoredFromDisk) restoreMs=\(restored)")
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func snap(_ name: String) async {
        await pause(0.9)
        footage?.mark(name)
        step += 1
        let file = folder.appendingPathComponent(String(format: "%02d-%@.png", step, name))
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else {
            HearthLog.emit("HEARTHTOUR fail no-window \(name)")
            return
        }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        if let data = image.pngData() {
            try? data.write(to: file)
            HearthLog.emit("HEARTHTOUR shot \(file.lastPathComponent)")
        }
    }
}

/// Saves the app's own window about `fps` times a second as JPEGs (Documents/tour/footage/00001.jpg...) plus
/// index.json with each frame's time and the tour's named moments, so a trailer can use real footage. Dev only.
@MainActor
final class TourFootage {
    private let folder: URL
    private var timer: Timer?
    private var count = 0
    private var times: [Double] = []
    private var marks: [[String: Any]] = []
    private var inFlight = 0 // frames rendered but not yet written; frames are skipped while the writer is behind
    private var skipped = 0
    private let start = Date()
    private let writer = DispatchQueue(label: "hearth.tour.footage", qos: .utility)

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func begin(fps: Double) {
        timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture() }
        }
        HearthLog.emit("HEARTHTOUR footage start fps=\(Int(fps))")
    }

    func mark(_ name: String) {
        let t = Date().timeIntervalSince(start)
        marks.append(["name": name, "t": t, "frame": count])
        HearthLog.emit(String(format: "HEARTHTOUR mark %@ t=%.2f frame=%d", name, t, count))
    }

    private func capture() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return }
        guard inFlight < 3 else { skipped += 1; return } // never pile up full-size images in memory
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.5
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        count += 1
        times.append(Date().timeIntervalSince(start))
        let file = folder.appendingPathComponent(String(format: "%05d.jpg", count))
        inFlight += 1
        writer.async { [weak self] in
            if let data = image.jpegData(compressionQuality: 0.8) { try? data.write(to: file) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.inFlight -= 1 } }
        }
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        let index: [String: Any] = ["frames": times, "marks": marks]
        let file = folder.appendingPathComponent("index.json")
        writer.sync {
            if let data = try? JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted]) { try? data.write(to: file) }
        }
        HearthLog.emit("HEARTHTOUR footage done frames=\(count) skipped=\(skipped)")
    }
}
