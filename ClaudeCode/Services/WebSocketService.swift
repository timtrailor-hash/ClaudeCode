import Foundation
import Combine

/// Represents a pending permission request from Claude
struct PermissionRequest: Identifiable {
    let id: String          // request_id from server
    let toolName: String    // e.g. "Bash", "Write", "Edit"
    let summary: String     // Human-readable description
    let timestamp: Date
}

/// Controls which tool operations require user approval.
/// Ordered most permissive → least permissive.
enum PermissionLevel: String, CaseIterable, Identifiable {
    case approveAll = "approve_all"
    case terminalOnly = "terminal_only"
    case terminalAndWeb = "terminal_and_web"
    case mostActions = "most_actions"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .approveAll: return "No Prompts"
        case .terminalOnly: return "Terminal Only"
        case .terminalAndWeb: return "Terminal & Web"
        case .mostActions: return "Most Actions"
        }
    }

    var description: String {
        switch self {
        case .approveAll: return "Claude runs everything without asking. Full trust."
        case .terminalOnly: return "Ask before running terminal commands. File operations and web access run freely."
        case .terminalAndWeb: return "Ask before running terminal commands or accessing the web. File operations run freely."
        case .mostActions: return "Ask before writing files, running terminal commands, or accessing the web. Only reading files runs freely."
        }
    }
}

@MainActor
class WebSocketService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var connectionState: ConnectionState = .disconnected
    @Published var isGenerating: Bool = false
    @Published var generationStartTime: Date?
    @Published var lastActivity: String = ""
    @Published var permissionQueue: [PermissionRequest] = []
    var pendingPermission: PermissionRequest? { permissionQueue.first }
    @Published var permissionLevel: PermissionLevel = .terminalOnly

    /// Highest event offset seen — used to skip replayed events on reconnect
    private var lastSeenOffset: Int = -1

    enum ConnectionState: String {
        case connected, disconnected, reconnecting
    }

    // Server config — stored in UserDefaults
    var serverHost: String {
        get { UserDefaults.standard.string(forKey: "serverHost") ?? "100.112.125.42:8081" }
        set {
            UserDefaults.standard.set(newValue, forKey: "serverHost")
            reconnect()
        }
    }

    var authToken: String {
        get { UserDefaults.standard.string(forKey: "authToken") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "authToken")
            reconnect()
        }
    }

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    private var watchdogTimer: Timer?
    private var reconnectDelay: TimeInterval = 1.0
    private var autoContCount = 0
    private let maxAutoContinue = 3
    private var messageQueue: [String] = []
    private var pendingMessage: (text: String, imagePaths: [String])?
    private var reconnectTask: Task<Void, Never>?
    private var lastPongTime: Date = Date()
    private var lastEventTime: Date?

    init() {
        // Restore saved permission level
        if let saved = UserDefaults.standard.string(forKey: "permissionLevel"),
           let level = PermissionLevel(rawValue: saved) {
            permissionLevel = level
        }
        connect()
    }

    func setPermissionLevel(_ level: PermissionLevel) {
        permissionLevel = level
        UserDefaults.standard.set(level.rawValue, forKey: "permissionLevel")
        sendJSON([
            "type": "set_permission_level",
            "level": level.rawValue
        ])
    }

    func connect() {
        disconnect()

        let urlString = "ws://\(serverHost)/ws?token=\(authToken)"
        guard let url = URL(string: urlString) else {
            connectionState = .disconnected
            return
        }

        // Custom config with long timeout — default 60s kills WebSocket
        // connections during silent periods (tool execution, thinking).
        // Server sends keepalives every 15s, so 300s is very generous.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        session = URLSession(configuration: config)
        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()

        // Don't set .connected yet — wait for first successful message
        connectionState = .reconnecting
        reconnectDelay = 1.0

        startPingTimer()
        receiveMessage()
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTimer?.invalidate()
        pingTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func reconnect() {
        connectionState = .reconnecting
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            connect()
        }
        reconnectDelay = min(reconnectDelay * 2, 30)
    }

    /// Force immediate reconnect (e.g., when app returns to foreground)
    func forceReconnect() {
        reconnectTask?.cancel()
        reconnectDelay = 1.0
        connect()
    }

    func sendMessage(_ text: String, imagePaths: [String] = []) {
        if isGenerating {
            messageQueue.append(text)
            return
        }

        let displayText = imagePaths.isEmpty ? text : "\(text)\n[\(imagePaths.count) image(s) attached]"
        let userMsg = ChatMessage(role: .user, content: displayText)
        messages.append(userMsg)

        // Create assistant placeholder
        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMsg)
        isGenerating = true
        generationStartTime = Date()
        lastActivity = "Connecting..."
        autoContCount = 0

        // Prune old messages to prevent unbounded memory growth
        if messages.count > 500 {
            messages.removeFirst(messages.count - 400)
        }

        // If not connected, queue and force reconnect
        if connectionState != .connected {
            pendingMessage = (text: text, imagePaths: imagePaths)
            lastActivity = "Reconnecting..."
            reconnect()
            return
        }

        var payload: [String: Any] = ["type": "message", "text": text]
        if !imagePaths.isEmpty {
            payload["image_paths"] = imagePaths
        }
        sendJSON(payload)
    }

    func cancelGeneration() {
        sendJSON(["type": "cancel"])
    }

    func newSession() {
        sendJSON(["type": "new_session"])
        messages.removeAll()
        isGenerating = false
        autoContCount = 0
        permissionQueue.removeAll()
        lastSeenOffset = -1
    }

    // MARK: - Permission responses

    func allowPermission(_ requestId: String) {
        sendJSON([
            "type": "permission_response",
            "request_id": requestId,
            "allow": true
        ])
        permissionQueue.removeAll { $0.id == requestId }
        lastActivity = permissionQueue.isEmpty
            ? "Permission granted, running..."
            : "Waiting for your permission..."
    }

    func denyPermission(_ requestId: String) {
        sendJSON([
            "type": "permission_response",
            "request_id": requestId,
            "allow": false,
            "message": "User denied permission"
        ])
        permissionQueue.removeAll { $0.id == requestId }
        lastActivity = permissionQueue.isEmpty
            ? "Permission denied"
            : "Waiting for your permission..."
    }

    // MARK: - Private

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(str)) { [weak self] error in
            if error != nil {
                Task { @MainActor in
                    self?.handleDisconnect()
                }
            }
        }
    }

    private func receiveMessage() {
        let currentWS = webSocket // Capture reference to detect stale callbacks
        webSocket?.receive { [weak self] result in
            Task { @MainActor in
                // Ignore callbacks from old/cancelled WebSocket connections
                guard self?.webSocket === currentWS else { return }

                switch result {
                case .success(let message):
                    // Connection confirmed working — mark as connected
                    if self?.connectionState != .connected {
                        self?.connectionState = .connected
                        self?.reconnectDelay = 1.0
                        // Auto-dismiss "Connection lost" system messages from previous disconnect
                        self?.messages.removeAll { $0.role == .system && $0.content.contains("Connection to Claude lost") }
                        // Sync permission level on connect
                        if let level = self?.permissionLevel {
                            self?.sendJSON([
                                "type": "set_permission_level",
                                "level": level.rawValue
                            ])
                        }
                        // Send any pending message that was queued while disconnected
                        if let pending = self?.pendingMessage {
                            self?.pendingMessage = nil
                            self?.lastActivity = "Starting..."
                            var payload: [String: Any] = ["type": "message", "text": pending.text]
                            if !pending.imagePaths.isEmpty {
                                payload["image_paths"] = pending.imagePaths
                            }
                            self?.sendJSON(payload)
                        }
                    }
                    switch message {
                    case .string(let text):
                        self?.handleServerMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self?.handleServerMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    self?.receiveMessage() // Continue listening

                case .failure:
                    self?.handleDisconnect()
                }
            }
        }
    }

    private func handleServerMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(ServerEvent.self, from: data) else { return }

        lastEventTime = Date()

        // Skip events we've already processed (prevents duplication on reconnect)
        if let offset = event.offset {
            if offset <= lastSeenOffset {
                // Already processed this event — but still process "done" to ensure
                // we don't miss the end-of-generation signal
                if event.type == "done" {
                    if let idx = currentAssistantIndex() {
                        messages[idx].isStreaming = false
                    }
                    isGenerating = false
                    generationStartTime = nil
                    lastActivity = ""
                    permissionQueue.removeAll()
                }
                return
            }
            lastSeenOffset = offset
        }

        switch event.type {
        case "text":
            appendToCurrentAssistant(event.content ?? "")
            lastActivity = "Writing..."

        case "tool":
            if let content = event.content {
                appendToolToCurrentAssistant(content)
                lastActivity = content
            }

        case "activity":
            if let content = event.content {
                switch content {
                case "tool_result": lastActivity = "Processing tool result..."
                case "processing": lastActivity = "Processing..."
                case "rate_limited": lastActivity = "Rate limited, waiting..."
                case "requesting_permission": lastActivity = "Waiting for permission..."
                default: lastActivity = content.capitalized + "..."
                }
            }

        case "permission_request":
            // Claude wants to use a tool and needs user approval
            if let requestId = event.requestId {
                let req = PermissionRequest(
                    id: requestId,
                    toolName: event.toolName ?? "Unknown",
                    summary: event.summary ?? "Use a tool",
                    timestamp: Date()
                )
                // Queue instead of overwrite — multiple tools may need approval
                if !permissionQueue.contains(where: { $0.id == requestId }) {
                    permissionQueue.append(req)
                }
                lastActivity = "Waiting for your permission..."
            }

        case "permission_acknowledged":
            // Server confirmed it received our permission response
            break

        case "permission_level_set":
            // Server confirmed the new permission level
            break

        case "keepalive":
            // Server-sent keepalive to prevent URLSession idle timeout
            lastPongTime = Date()
            return

        case "image":
            if let urlPath = event.content, let idx = currentAssistantIndex() {
                let fullURL = "http://\(serverHost)\(urlPath)"
                messages[idx].imageURLs.append(fullURL)
            }

        case "cost":
            if let content = event.content, let idx = currentAssistantIndex() {
                messages[idx].cost = content
            }

        case "done":
            if let idx = currentAssistantIndex() {
                messages[idx].isStreaming = false
            }
            isGenerating = false
            generationStartTime = nil
            lastActivity = ""

            // Only clear permissions if we're truly done (not auto-continuing)
            if !(event.truncated == true && autoContCount < maxAutoContinue) {
                permissionQueue.removeAll()
            }

            // Auto-continue on truncation
            if event.truncated == true && autoContCount < maxAutoContinue {
                autoContCount += 1
                let continueMsg = ChatMessage(role: .system, content: "Auto-continuing (\(autoContCount)/\(maxAutoContinue))...")
                messages.append(continueMsg)

                // Send continue message
                let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
                messages.append(assistantMsg)
                isGenerating = true
                sendJSON(["type": "message", "text": "Continue from where you left off"])
            }

            // Send queued message
            if !isGenerating, let queued = messageQueue.first {
                messageQueue.removeFirst()
                sendMessage(queued)
            }

            // Post notification only when truly finished (not auto-continuing or queued)
            if !isGenerating {
                NotificationService.shared?.postIfBackgrounded(
                    title: "Claude finished",
                    body: String((messages.last(where: { $0.role == .assistant })?.content ?? "").prefix(100))
                )
            }

        case "session_started":
            // Session confirmed
            break

        case "ws_error":
            let content = event.content ?? "Unknown"
            // Stale permission responses are harmless — just clean up quietly
            if content.contains("Unknown permission request") {
                // Request already handled/expired on server, remove from local queue
                let staleId = content.components(separatedBy: ": ").last ?? ""
                permissionQueue.removeAll { $0.id == staleId }
                break
            }
            let errorMsg = ChatMessage(role: .system, content: "Error: \(content)")
            messages.append(errorMsg)
            isGenerating = false
            generationStartTime = nil
            lastActivity = ""

        case "cancelled":
            if let idx = currentAssistantIndex() {
                messages[idx].isStreaming = false
                messages[idx].content += "\n\n[Cancelled]"
            }
            isGenerating = false
            generationStartTime = nil
            lastActivity = ""
            permissionQueue.removeAll()

        case "new_session_ok":
            break

        case "pong":
            lastPongTime = Date()
            break

        case "push_message":
            // Standalone message pushed from terminal session — create its own assistant bubble
            if let content = event.content {
                let msg = ChatMessage(role: .assistant, content: content, isStreaming: false)
                messages.append(msg)
            }

        case "printer_alert":
            let printer = event.content ?? ""
            let alertMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? printer
            let alertEvent = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["event"] as? String ?? ""
            let printerName = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["printer"] as? String ?? ""

            // Post notification based on user preferences
            let prefs = NotificationPreferences.shared
            if prefs.shouldNotify(event: alertEvent, printer: printerName) {
                NotificationService.shared?.postPrinterAlert(title: "Printer Alert", body: alertMsg)
            }

        default:
            break
        }
    }

    private func appendToCurrentAssistant(_ text: String) {
        if let idx = currentOrRecoverAssistantIndex() {
            messages[idx].content += text
        }
    }

    private func appendToolToCurrentAssistant(_ content: String) {
        if let idx = currentOrRecoverAssistantIndex() {
            messages[idx].toolUse.append(ToolEvent(content: content))
        }
    }

    private func currentAssistantIndex() -> Int? {
        messages.indices.last(where: { messages[$0].role == .assistant && messages[$0].isStreaming })
    }

    /// Find streaming assistant message, or recover the last assistant message
    /// if it was marked non-streaming due to a WS disconnect (replay scenario).
    private func currentOrRecoverAssistantIndex() -> Int? {
        if let idx = currentAssistantIndex() {
            return idx
        }
        // Recovery: if we're generating but no streaming message exists,
        // the last assistant message was closed by a disconnect. Re-enable it.
        if isGenerating,
           let idx = messages.indices.last(where: { messages[$0].role == .assistant }) {
            messages[idx].isStreaming = true
            return idx
        }
        return nil
    }

    private func handleDisconnect() {
        connectionState = .disconnected
        pingTimer?.invalidate()
        // Keep isStreaming=true on the assistant message so that when the WS
        // reconnects and the server replays events, they can still append.
        // Only the "done" event should finalise the message.
        lastActivity = isGenerating ? "Reconnecting... Claude is still working" : "Reconnecting..."
        reconnect()
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        lastPongTime = Date()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // JSON-level ping (server responds with pong, resets lastPongTime).
                // Protocol-level pings are handled by the server's simple-websocket
                // ping_interval — URLSessionWebSocketTask responds automatically.
                self?.sendJSON(["type": "ping"])
                // Force reconnect if no pong/keepalive received for 60s
                if let self = self,
                   self.connectionState == .connected,
                   Date().timeIntervalSince(self.lastPongTime) > 60 {
                    self.handleDisconnect()
                }
            }
        }

        // Watchdog: auto-reset isGenerating if no events for a long time.
        // Uses two thresholds:
        //  - 90s while still connected → likely the turn genuinely stalled
        //  - 120s if disconnected → connection is truly gone, give up
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard self.isGenerating,
                      let lastEvent = self.lastEventTime else { return }

                let silentSeconds = Date().timeIntervalSince(lastEvent)
                let threshold: TimeInterval = self.connectionState == .connected ? 90 : 120

                if silentSeconds > threshold {
                    // Auto-reset stale generation state
                    if let idx = self.currentAssistantIndex() {
                        self.messages[idx].isStreaming = false
                    }
                    self.isGenerating = false
                    self.generationStartTime = nil
                    self.lastActivity = ""
                    self.messages.append(ChatMessage(
                        role: .system,
                        content: "Connection to Claude lost. Your message may need to be resent."
                    ))
                }
            }
        }
    }
}
