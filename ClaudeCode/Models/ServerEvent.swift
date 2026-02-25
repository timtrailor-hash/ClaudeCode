import Foundation

/// Events received from the conversation server WebSocket
struct ServerEvent: Decodable {
    let type: String
    let content: String?
    let offset: Int?
    let truncated: Bool?
    let sessionId: String?
    let pid: Int?

    enum CodingKeys: String, CodingKey {
        case type, content, offset, truncated, pid
        case sessionId = "session_id"
    }
}
