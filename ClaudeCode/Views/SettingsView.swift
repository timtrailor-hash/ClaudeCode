import SwiftUI

/// Wrapper to make URL identifiable for .sheet(item:)
struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct SettingsView: View {
    @EnvironmentObject var ws: WebSocketService
    @StateObject private var notifPrefs = NotificationPreferences.shared
    @State private var hostInput = ""
    @State private var tokenInput = ""
    @AppStorage("appZoomLevel") private var zoomLevel: Double = 1.0

    // Terminal auth state
    @State private var authSheetItem: IdentifiableURL?
    @State private var authInProgress = false
    @State private var authStatusMessage: String?
    @State private var authStatusIsError = false

    private let accent = Color(hex: "#C9A96E")
    private let dimText = Color(hex: "#888888")
    private let cardBg = Color(hex: "#16213E")
    private let bg = Color(hex: "#1A1A2E")

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    HStack {
                        Text("Host")
                        Spacer()
                        TextField("host:port", text: $hostInput)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(accent)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit {
                                ws.serverHost = hostInput
                            }
                    }

                    HStack {
                        Text("Token")
                        Spacer()
                        SecureField("Auth Token", text: $tokenInput)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(accent)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit {
                                ws.authToken = tokenInput
                            }
                    }

                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 8, height: 8)
                            Text(ws.connectionState.rawValue.capitalized)
                                .foregroundColor(dimText)
                        }
                    }

                    Button("Reconnect") {
                        ws.serverHost = hostInput
                    }
                    .foregroundColor(accent)
                }

                Section(header: Text("Ask Permission Before"),
                        footer: Text(ws.permissionLevel.description)) {
                    Picker("Prompt For", selection: Binding(
                        get: { ws.permissionLevel },
                        set: { ws.setPermissionLevel($0) }
                    )) {
                        ForEach(PermissionLevel.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .tint(accent)
                }

                Section("Printer Notifications") {
                    Toggle("Print Complete", isOn: $notifPrefs.printComplete)
                        .tint(accent)
                    Toggle("Print Paused / Resumed", isOn: $notifPrefs.printPaused)
                        .tint(accent)
                    Toggle("Print Error", isOn: $notifPrefs.printError)
                        .tint(accent)
                    Toggle("Print Cancelled", isOn: $notifPrefs.printCancelled)
                        .tint(accent)
                    Toggle("Print Started", isOn: $notifPrefs.printStarted)
                        .tint(accent)
                    Toggle("Custom Watches", isOn: $notifPrefs.customWatches)
                        .tint(accent)
                    Toggle("AI Failure Detection", isOn: $notifPrefs.aiFailureDetection)
                        .tint(accent)
                    Toggle("ETA Method Changes", isOn: $notifPrefs.etaMethodChange)
                        .tint(accent)
                    Toggle("Connection Lost / Restored", isOn: $notifPrefs.connectionAlerts)
                        .tint(accent)
                }

                Section(header: Text("AI Failure Checks"), footer: Text("Bambu uses Claude Haiku (API credits). SV08 uses Obico (free).")) {
                    Picker("Bambu A1 (Haiku)", selection: $notifPrefs.bambuAIFrequency) {
                        ForEach(NotificationPreferences.frequencyOptions, id: \.seconds) { opt in
                            Text(opt.label).tag(opt.seconds)
                        }
                    }
                    .tint(accent)

                    Picker("SV08 Max (Obico)", selection: $notifPrefs.sv08AIFrequency) {
                        ForEach(NotificationPreferences.frequencyOptions, id: \.seconds) { opt in
                            Text(opt.label).tag(opt.seconds)
                        }
                    }
                    .tint(accent)
                }

                Section("Chat Notifications") {
                    Toggle("Claude Finished (background)", isOn: $notifPrefs.claudeFinished)
                        .tint(accent)
                }

                Section(header: Text("Display"),
                        footer: Text("Scales the entire app UI. Double-tap slider to reset.")) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Zoom")
                            Spacer()
                            Text("\(Int(zoomLevel * 100))%")
                                .foregroundColor(accent)
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                        }
                        Slider(value: $zoomLevel, in: 0.85...1.4, step: 0.05)
                            .tint(accent)
                            .onTapGesture(count: 2) {
                                withAnimation { zoomLevel = 1.0 }
                            }
                    }
                }

                Section(header: Text("Terminal Authentication"),
                        footer: Text("Authenticate the Terminal tab with your Claude account via OAuth.")) {
                    if let msg = authStatusMessage {
                        HStack {
                            Image(systemName: authStatusIsError ? "xmark.circle" : "checkmark.circle")
                                .foregroundColor(authStatusIsError ? .red : .green)
                            Text(msg)
                                .font(.system(size: 13))
                                .foregroundColor(authStatusIsError ? .red : .green)
                        }
                    }

                    Button {
                        startAuth()
                    } label: {
                        HStack {
                            if authInProgress {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .padding(.trailing, 4)
                                Text("Authenticating...")
                            } else {
                                Image(systemName: "person.badge.key")
                                Text("Authenticate Terminal")
                            }
                        }
                    }
                    .foregroundColor(accent)
                    .disabled(authInProgress)
                }

                SystemHealthSection(serverHost: ws.serverHost)

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.1")
                            .foregroundColor(dimText)
                    }
                    HStack {
                        Text("Messages")
                        Spacer()
                        Text("\(ws.messages.count)")
                            .foregroundColor(dimText)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(bg)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(cardBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .onAppear {
            hostInput = ws.serverHost
            tokenInput = ws.authToken
        }
        .sheet(item: $authSheetItem) { item in
            TerminalAuthSheet(
                url: item.url,
                onCode: { code in
                    authSheetItem = nil
                    completeAuth(code: code)
                },
                onCancel: {
                    authSheetItem = nil
                    authInProgress = false
                }
            )
        }
    }

    private var statusColor: Color {
        switch ws.connectionState {
        case .connected: return .green
        case .disconnected: return .red
        case .reconnecting: return .yellow
        }
    }

    // MARK: - Terminal Auth

    private var serverBaseURL: String {
        let parts = ws.serverHost.split(separator: ":")
        let ip = parts.first ?? "100.126.253.40"
        return "http://\(ip):8081"
    }

    private func startAuth() {
        authInProgress = true
        authStatusMessage = nil

        guard let url = URL(string: "\(serverBaseURL)/terminal-auth-start") else {
            authStatusMessage = "Invalid server URL"
            authStatusIsError = true
            authInProgress = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let token = UserDefaults.standard.string(forKey: "authToken") ?? ""
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

                if let oauthURLString = json["url"] as? String,
                   let oauthURL = URL(string: oauthURLString) {
                    await MainActor.run {
                        authSheetItem = IdentifiableURL(url: oauthURL)
                    }
                } else {
                    let error = json["error"] as? String ?? "Unknown error"
                    await MainActor.run {
                        authStatusMessage = error
                        authStatusIsError = true
                        authInProgress = false
                    }
                }
            } catch {
                await MainActor.run {
                    authStatusMessage = "Request failed: \(error.localizedDescription)"
                    authStatusIsError = true
                    authInProgress = false
                }
            }
        }
    }

    private func completeAuth(code: String) {
        guard let url = URL(string: "\(serverBaseURL)/terminal-auth-complete") else {
            authStatusMessage = "Invalid server URL"
            authStatusIsError = true
            authInProgress = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = UserDefaults.standard.string(forKey: "authToken") ?? ""
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code])

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let ok = json["ok"] as? Bool ?? false
                let status = json["status"] as? String ?? ""

                await MainActor.run {
                    authInProgress = false
                    if ok {
                        authStatusMessage = "Logged in: \(status)"
                        authStatusIsError = false
                    } else {
                        authStatusMessage = "Auth failed: \(json["error"] as? String ?? status)"
                        authStatusIsError = true
                    }
                }
            } catch {
                await MainActor.run {
                    authStatusMessage = "Request failed: \(error.localizedDescription)"
                    authStatusIsError = true
                    authInProgress = false
                }
            }
        }
    }
}
