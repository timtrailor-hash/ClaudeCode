import Foundation
import Combine

@MainActor
class WebSocketService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var connectionState: ConnectionState = .disconnected
    @Published var isGenerating: Bool = false

    enum ConnectionState: String {
        case connected, disconnected, reconnecting
    }

    // Server config — stored in UserDefaults
    var serverHost: String {
        get { UserDefaults.standard.string(forKey: "serverHost") ?? "localhost:8081" }
        set {
            UserDefaults.standard.set(newValue, forKey: "serverHost")
            reconnect()
        }
    }

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    private var reconnectDelay: TimeInterval = 1.0
    private var autoContCount = 0
    private let maxAutoContinue = 3
    private var messageQueue: [String] = []

    init() {
        connect()
    }

    func connect() {
        disconnect()

        let urlString = "ws://\(serverHost)/ws"
        guard let url = URL(string: urlString) else {
            connectionState = .disconnected
            return
        }

        session = URLSession(configuration: .default)
        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()

        // Don't set .connected yet — wait for first successful message
        connectionState = .reconnecting
        reconnectDelay = 1.0

        startPingTimer()
        receiveMessage()
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func reconnect() {
        connectionState = .reconnecting
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
            connect()
        }
        reconnectDelay = min(reconnectDelay * 2, 30)
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
        autoContCount = 0

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

        switch event.type {
        case "text":
            appendToCurrentAssistant(event.content ?? "")

        case "tool":
            if let content = event.content {
                appendToolToCurrentAssistant(content)
            }

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
            let errorMsg = ChatMessage(role: .system, content: "Error: \(event.content ?? "Unknown")")
            messages.append(errorMsg)
            isGenerating = false

        case "cancelled":
            if let idx = currentAssistantIndex() {
                messages[idx].isStreaming = false
                messages[idx].content += "\n\n[Cancelled]"
            }
            isGenerating = false

        case "new_session_ok":
            break

        case "pong":
            break

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
        if let idx = currentAssistantIndex() {
            messages[idx].content += text
        }
    }

    private func appendToolToCurrentAssistant(_ content: String) {
        if let idx = currentAssistantIndex() {
            messages[idx].toolUse.append(ToolEvent(content: content))
        }
    }

    private func currentAssistantIndex() -> Int? {
        messages.indices.last(where: { messages[$0].role == .assistant && messages[$0].isStreaming })
    }

    private func handleDisconnect() {
        connectionState = .disconnected
        pingTimer?.invalidate()
        if let idx = currentAssistantIndex() {
            messages[idx].isStreaming = false
        }
        isGenerating = false
        reconnect()
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendJSON(["type": "ping"])
            }
        }
    }
}
