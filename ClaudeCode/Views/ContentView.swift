import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

struct ContentView: View {
    @EnvironmentObject var webSocket: WebSocketService
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatView()
                .tabItem {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                    Text("Chat")
                }
                .tag(0)

            PrinterView()
                .tabItem {
                    Image(systemName: "printer.fill")
                    Text("Printers")
                }
                .tag(1)

            GovernorsView()
                .tabItem {
                    Image(systemName: "building.columns.fill")
                    Text("Governors")
                }
                .tag(2)

            WorkView()
                .tabItem {
                    Image(systemName: "briefcase.fill")
                    Text("Work")
                }
                .tag(3)

            SettingsView()
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
                .tag(4)
        }
        .tint(Color(hex: "#C9A96E"))
        .onAppear {
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(red: 0.086, green: 0.129, blue: 0.243, alpha: 1) // #16213E
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active && webSocket.connectionState != .connected {
                webSocket.forceReconnect()
            }
        }
    }
}
