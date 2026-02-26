import Foundation
import UserNotifications
import UIKit

// MARK: - Notification Preferences

class NotificationPreferences: ObservableObject {
    static let shared = NotificationPreferences()

    @Published var printStarted: Bool {
        didSet { UserDefaults.standard.set(printStarted, forKey: "notify_printStarted") }
    }
    @Published var printComplete: Bool {
        didSet { UserDefaults.standard.set(printComplete, forKey: "notify_printComplete") }
    }
    @Published var printPaused: Bool {
        didSet { UserDefaults.standard.set(printPaused, forKey: "notify_printPaused") }
    }
    @Published var printError: Bool {
        didSet { UserDefaults.standard.set(printError, forKey: "notify_printError") }
    }
    @Published var printCancelled: Bool {
        didSet { UserDefaults.standard.set(printCancelled, forKey: "notify_printCancelled") }
    }
    @Published var customWatches: Bool {
        didSet { UserDefaults.standard.set(customWatches, forKey: "notify_customWatches") }
    }
    @Published var claudeFinished: Bool {
        didSet { UserDefaults.standard.set(claudeFinished, forKey: "notify_claudeFinished") }
    }
    @Published var aiFailureDetection: Bool {
        didSet { UserDefaults.standard.set(aiFailureDetection, forKey: "notify_aiFailure") }
    }
    @Published var etaMethodChange: Bool {
        didSet { UserDefaults.standard.set(etaMethodChange, forKey: "notify_etaMethod") }
    }
    @Published var connectionAlerts: Bool {
        didSet { UserDefaults.standard.set(connectionAlerts, forKey: "notify_connection") }
    }

    // AI check frequencies (seconds, 0 = off)
    @Published var bambuAIFrequency: Int {
        didSet {
            UserDefaults.standard.set(bambuAIFrequency, forKey: "ai_freq_bambu")
            sendAIConfigToServer()
        }
    }
    @Published var sv08AIFrequency: Int {
        didSet {
            UserDefaults.standard.set(sv08AIFrequency, forKey: "ai_freq_sv08")
            sendAIConfigToServer()
        }
    }

    static let frequencyOptions: [(label: String, seconds: Int)] = [
        ("Off", 0),
        ("1 min", 60),
        ("5 min", 300),
        ("15 min", 900),
        ("1 hour", 3600)
    ]

    init() {
        let d = UserDefaults.standard
        // Default everything ON except print started
        printStarted = d.object(forKey: "notify_printStarted") as? Bool ?? false
        printComplete = d.object(forKey: "notify_printComplete") as? Bool ?? true
        printPaused = d.object(forKey: "notify_printPaused") as? Bool ?? true
        printError = d.object(forKey: "notify_printError") as? Bool ?? true
        printCancelled = d.object(forKey: "notify_printCancelled") as? Bool ?? true
        customWatches = d.object(forKey: "notify_customWatches") as? Bool ?? true
        claudeFinished = d.object(forKey: "notify_claudeFinished") as? Bool ?? true
        aiFailureDetection = d.object(forKey: "notify_aiFailure") as? Bool ?? true
        etaMethodChange = d.object(forKey: "notify_etaMethod") as? Bool ?? true
        connectionAlerts = d.object(forKey: "notify_connection") as? Bool ?? true
        bambuAIFrequency = d.object(forKey: "ai_freq_bambu") as? Int ?? 300  // Default 5 min
        sv08AIFrequency = d.object(forKey: "ai_freq_sv08") as? Int ?? 300    // Default 5 min
    }

    func sendAIConfigToServer() {
        // Send config to conversation server
        guard let hostStr = UserDefaults.standard.string(forKey: "serverHost"),
              let url = URL(string: "http://\(hostStr)/ai-check-config") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "bambu_interval": bambuAIFrequency,
            "sv08_interval": sv08AIFrequency
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    func shouldNotify(event: String, printer: String) -> Bool {
        switch event {
        case "state_change":
            return true  // Checked at finer level in shouldNotifyStateChange
        case "watch_triggered":
            return customWatches
        case "failure_detected", "ai_failure_detected":
            return aiFailureDetection
        case "eta_method_degraded", "eta_method_recovered":
            return etaMethodChange
        case "connection_lost", "connection_restored":
            return connectionAlerts
        default:
            return true
        }
    }

    func shouldNotifyStateChange(message: String) -> Bool {
        let msg = message.lowercased()
        if msg.contains("started") { return printStarted }
        if msg.contains("complete") { return printComplete }
        if msg.contains("paused") { return printPaused }
        if msg.contains("error") { return printError }
        if msg.contains("cancelled") || msg.contains("canceled") { return printCancelled }
        if msg.contains("resumed") { return printPaused }  // Resume uses same toggle as pause
        return true
    }
}

// MARK: - Notification Service

@MainActor
class NotificationService: ObservableObject {
    static weak var shared: NotificationService?

    init() {
        Self.shared = self
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            print("Notifications \(granted ? "granted" : "denied")")
        }
    }

    func postIfBackgrounded(title: String, body: String) {
        let prefs = NotificationPreferences.shared
        guard prefs.claudeFinished else { return }
        guard UIApplication.shared.applicationState != .active else { return }
        postNotification(title: title, body: body, sound: .default)
    }

    func postPrinterAlert(title: String, body: String) {
        let prefs = NotificationPreferences.shared
        // Check fine-grained preference for state changes
        if !prefs.shouldNotifyStateChange(message: body) { return }

        // Always post printer alerts (even when app is active, show as banner)
        postNotification(title: title, body: body, sound: UNNotificationSound.default)
    }

    private func postNotification(title: String, body: String, sound: UNNotificationSound?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let sound = sound {
            content.sound = sound
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
