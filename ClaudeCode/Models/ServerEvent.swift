import Foundation

/// Events received from the conversation server WebSocket
struct ServerEvent: Decodable {
    let type: String
    let content: String?
    let offset: Int?
    let truncated: Bool?
    let sessionId: String?
    let pid: Int?
    // Permission request fields
    let requestId: String?
    let toolName: String?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case type, content, offset, truncated, pid, summary
        case sessionId = "session_id"
        case requestId = "request_id"
        case toolName = "tool_name"
    }
}
