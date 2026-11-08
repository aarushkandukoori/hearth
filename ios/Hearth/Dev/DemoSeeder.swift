// Dev: fills a few chats with sample messages for screenshots (-HearthSeedDemo 1). Never runs otherwise.

import Foundation

@MainActor
enum DemoSeeder {
    static func seed(_ app: AppModel) {
        guard app.chats.recent.isEmpty else { return }
        let persona = app.settings.persona
        let lines: [(String, [(MessageRole, String)])] = [
            ("juno", [
                (.user, "Long day. Is the café still open?"),
                (.character, "*flips the sign back to OPEN* For you? Always. Rough one?"),
                (.user, "Kind of. My interview got moved to Friday."),
                (.character, "Then Friday-you gets a cinnamon roll on the house. Want to practice your answers with me while the milk steams?"),
            ]),
            ("theo", [
                (.user, "Can't sleep. Tell me about the lighthouse?"),
                (.character, "*sets down his tea* She's older than me, and I'm very old. Every night at nine I wind the clockwork and she starts to turn."),
            ]),
            ("luna", [
                (.user, "Are you awake?"),
                (.character, "Always, at this hour. You're listening to the night shift on Lantern Bay radio. What's keeping you up?"),
            ]),
        ]
        for (id, messages) in lines {
            guard let character = app.library.character(id) ?? app.library.allCharacters.first else { continue }
            var conversation = app.chats.startDirect(with: character, persona: persona)
            for (offset, item) in messages.enumerated() {
                var message = Message(role: item.0, speakerID: item.0 == .character ? character.id : nil, text: item.1)
                message.createdAt = Date().addingTimeInterval(Double(offset - messages.count) * 90)
                conversation.messages.append(message)
            }
            conversation.updatedAt = Date()
            app.chats.update(conversation)
        }
        app.chats.flush()
        HearthLog.info("demo", "seeded \(lines.count) demo chats")
    }
}
