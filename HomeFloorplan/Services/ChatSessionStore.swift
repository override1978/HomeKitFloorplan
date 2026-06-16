import Foundation

// MARK: - PersistedChatMessage

struct PersistedChatMessage: Codable {
    let role: String    // "user" | "assistant"
    let content: String
}

// MARK: - PersistedChatSession

struct PersistedChatSession: Codable {
    let messages: [PersistedChatMessage]
    let turns: [ConversationTurn]
    let savedAt: Date

    var isEmpty: Bool { messages.isEmpty }
    var messageCount: Int { messages.count }
}

// MARK: - ChatSessionStore

enum ChatSessionStore {
    private static let userDefaultsKey = "chatbot.lastSession"
    private static let maxMessages = 40
    private static let maxTurns = 20

    static func save(messages: [ChatMessage], turns: [ConversationTurn]) {
        guard !messages.isEmpty else { return }
        let persisted = PersistedChatSession(
            messages: Array(messages.suffix(maxMessages)).map {
                PersistedChatMessage(
                    role: $0.role == .user ? "user" : "assistant",
                    content: $0.content
                )
            },
            turns: Array(turns.suffix(maxTurns)),
            savedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    static func load() -> PersistedChatSession? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let session = try? JSONDecoder().decode(PersistedChatSession.self, from: data),
              !session.isEmpty else { return nil }
        return session
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}
