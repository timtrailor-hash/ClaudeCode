import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var ws: WebSocketService
    @StateObject private var notifPrefs = NotificationPreferences.shared
    @State private var hostInput = ""

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
                }

                Section("Chat Notifications") {
                    Toggle("Claude Finished (background)", isOn: $notifPrefs.claudeFinished)
                        .tint(accent)
                }

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
        }
    }

    private var statusColor: Color {
        switch ws.connectionState {
        case .connected: return .green
        case .disconnected: return .red
        case .reconnecting: return .yellow
        }
    }
}
