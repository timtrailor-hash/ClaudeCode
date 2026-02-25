import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: String
    var isStreaming: Bool
    var toolUse: [ToolEvent]
    var cost: String?
    var imageURLs: [String]
    let timestamp: Date

    enum MessageRole: String {
        case user, assistant, system
    }

    init(role: MessageRole, content: String, isStreaming: Bool = false) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.toolUse = []
        self.cost = nil
        self.imageURLs = []
        self.timestamp = Date()
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content && lhs.isStreaming == rhs.isStreaming && lhs.imageURLs == rhs.imageURLs
    }
}

struct ToolEvent: Identifiable, Equatable {
    let id = UUID()
    let content: String
}
