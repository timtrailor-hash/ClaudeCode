import SwiftUI
import UserNotifications

/// A single health check item from the server
struct HealthItem: Identifiable, Decodable {
    var id: String { name }
    let name: String
    let timestamp: String?
    let detail: String?
    let uncommittedCount: Int?

    enum CodingKeys: String, CodingKey {
        case name, timestamp, detail
        case uncommittedCount = "uncommitted_count"
    }
}

struct HealthResponse: Decodable {
    let items: [HealthItem]
}

/// Color-coded system health dashboard shown in Settings
struct SystemHealthSection: View {
    let serverHost: String

    @State private var items: [HealthItem] = []
    @State private var lastFetched: Date?
    @State private var isLoading = false

    private let accent = Color(hex: "#C9A96E")
    private let dimText = Color(hex: "#888888")

    var body: some View {
        Section(header: HStack {
            Text("System Health")
            Spacer()
            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Button(action: fetchHealth) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(accent)
                }
                .buttonStyle(.plain)
            }
        }, footer: footerText) {
            if items.isEmpty && !isLoading {
                Text("Tap refresh to check system health")
                    .foregroundColor(dimText)
                    .font(.system(size: 13))
            }
            ForEach(items) { item in
                HStack(spacing: 10) {
                    Circle()
                        .fill(statusColor(for: item))
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 14, weight: .medium))
                        if let detail = item.detail {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundColor(dimText)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(relativeTime(for: item))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(statusColor(for: item))
                        if let ts = item.timestamp, let date = parseISO(ts) {
                            Text(shortDate(date))
                                .font(.system(size: 10))
                                .foregroundColor(dimText)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .onAppear { fetchHealth() }
    }

    private var footerText: some View {
        Group {
            if let fetched = lastFetched {
                Text("Last checked: \(shortTime(fetched))")
            } else {
                Text("Green < 24h · Amber 1-3 days · Red > 3 days")
            }
        }
    }

    // MARK: - Status color logic

    private func statusColor(for item: HealthItem) -> Color {
        // GitHub repos: color by uncommitted count (0=green, 1=amber, >1=red)
        if item.name.hasPrefix("GitHub:"), let count = item.uncommittedCount {
            if count == 0 { return .green }
            if count == 1 { return Color.orange }
            return .red
        }

        guard let ts = item.timestamp, let date = parseISO(ts) else {
            return .red
        }
        let hours = Date().timeIntervalSince(date) / 3600

        // Server uptime: green if running, uses different thresholds
        if item.name == "Conversation Server" {
            return .green  // If we got a response, it's running
        }
        // Printer daemon: should update every few minutes
        if item.name == "Printer Daemon" {
            if hours < 0.5 { return .green }
            if hours < 2 { return Color.orange }
            return .red
        }
        // Default thresholds: green <24h, amber 1-3 days, red >3 days
        if hours < 24 { return .green }
        if hours < 72 { return Color.orange }
        return .red
    }

    private func relativeTime(for item: HealthItem) -> String {
        // GitHub repos: show uncommitted count as the primary metric
        if item.name.hasPrefix("GitHub:"), let count = item.uncommittedCount {
            if count == 0 { return "clean" }
            return "\(count) dirty"
        }

        guard let ts = item.timestamp, let date = parseISO(ts) else {
            return "unknown"
        }

        // For server uptime, show uptime not age
        if item.name == "Conversation Server" {
            if let detail = item.detail {
                return detail
            }
        }

        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let days = Int(interval / 86400)
        return "\(days)d ago"
    }

    // MARK: - Date parsing

    private func parseISO(_ s: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: s) { return d }
        // Try without fractional seconds
        fmt.formatOptions = [.withInternetDateTime]
        if let d = fmt.date(from: s) { return d }
        // Try basic format (from datetime.isoformat())
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        if let d = df.date(from: s) { return d }
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return df.date(from: s)
    }

    private func shortDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "d MMM HH:mm"
        return df.string(from: date)
    }

    private func shortTime(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: date)
    }

    // MARK: - Fetch

    private func fetchHealth() {
        guard let url = URL(string: "http://\(serverHost)/system-health") else { return }
        isLoading = true

        var request = URLRequest(url: url)
        let token = UserDefaults.standard.string(forKey: "authToken") ?? ""
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                isLoading = false
                lastFetched = Date()

                guard let data = data, error == nil,
                      let response = try? JSONDecoder().decode(HealthResponse.self, from: data) else {
                    return
                }
                items = response.items

                // Check for stale backup and alert
                checkBackupStaleness(items: response.items)

                // Check for uncommitted code across repos
                checkUncommittedCode(items: response.items)
            }
        }.resume()
    }

    /// Post a local notification if backup is >48h old
    private func checkBackupStaleness(items: [HealthItem]) {
        guard UIApplication.shared.applicationState != .active else { return }
        for item in items where item.name == "Google Drive Backup" {
            guard let ts = item.timestamp, let date = parseISO(ts) else {
                // No backup at all — alert
                postBackupAlert(message: "No backup found! Check the backup daemon.")
                return
            }
            let hours = Date().timeIntervalSince(date) / 3600
            if hours > 48 {
                let days = Int(hours / 24)
                postBackupAlert(message: "Last backup was \(days) days ago. Check the backup daemon.")
            }
        }
    }

    /// Post a local notification if any repo has >1 uncommitted changes
    private func checkUncommittedCode(items: [HealthItem]) {
        guard UIApplication.shared.applicationState != .active else { return }
        let dirtyRepos = items.filter {
            $0.name.hasPrefix("GitHub:") && ($0.uncommittedCount ?? 0) > 1
        }
        guard !dirtyRepos.isEmpty else { return }

        let names = dirtyRepos.map {
            let count = $0.uncommittedCount ?? 0
            let short = $0.name.replacingOccurrences(of: "GitHub: ", with: "")
            return "\(short) (\(count))"
        }.joined(separator: ", ")

        let content = UNMutableNotificationContent()
        content.title = "Uncommitted Code"
        content.body = "Repos with uncommitted changes: \(names)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "uncommitted_code_warning",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func postBackupAlert(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Backup Warning"
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "backup_stale_warning",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
