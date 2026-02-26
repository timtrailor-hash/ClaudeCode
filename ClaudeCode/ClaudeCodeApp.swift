import SwiftUI

@main
struct ClaudeCodeApp: App {
    @StateObject private var webSocket = WebSocketService()
    @StateObject private var notifications = NotificationService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(webSocket)
                .environmentObject(notifications)
                .preferredColorScheme(.dark)
                .onAppear {
                    notifications.requestPermission()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active && webSocket.connectionState != .connected {
                webSocket.forceReconnect()
            }
        }
    }
}
