import SwiftUI

@main
struct ClaudeCodeApp: App {
    @StateObject private var webSocket = WebSocketService()
    @StateObject private var notifications = NotificationService()

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
    }
}
