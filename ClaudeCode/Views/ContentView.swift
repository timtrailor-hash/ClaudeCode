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

/// Wraps content with scaleEffect zoom. At 1.0x no change; above 1.0x content
/// is scaled up from the top-leading corner inside a scroll view.
struct ZoomedView<Content: View>: View {
    let zoom: Double
    @ViewBuilder let content: () -> Content

    var body: some View {
        if zoom > 1.01 {
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                content()
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(
                        width: UIScreen.main.bounds.width * zoom,
                        height: UIScreen.main.bounds.height * zoom
                    )
            }
        } else {
            content()
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var webSocket: WebSocketService
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @AppStorage("appZoomLevel") private var zoomLevel: Double = 1.0

    var body: some View {
        TabView(selection: $selectedTab) {
            // Chat is NOT zoomed — its own ScrollView + keyboard avoidance
            // breaks when wrapped in ZoomedView's outer ScrollView
            ChatView()
                .tabItem {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                    Text("Chat")
                }
                .tag(0)

            ZoomedView(zoom: zoomLevel) { PrinterView() }
                .tabItem {
                    Image(systemName: "printer.fill")
                    Text("Printers")
                }
                .tag(1)

            ZoomedView(zoom: zoomLevel) { GovernorsView() }
                .tabItem {
                    Image(systemName: "building.columns.fill")
                    Text("Governors")
                }
                .tag(2)

            ZoomedView(zoom: zoomLevel) { WorkView() }
                .tabItem {
                    Image(systemName: "briefcase.fill")
                    Text("Work")
                }
                .tag(3)

            // Settings is NOT zoomed (so the slider remains usable at all zoom levels)
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
