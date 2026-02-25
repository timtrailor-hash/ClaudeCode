import SwiftUI
import WebKit

struct GovernorsView: View {
    @EnvironmentObject var ws: WebSocketService
    @State private var isLoading = true
    @State private var webView: WKWebView?
    @State private var showResetConfirm = false

    private let accent = Color(hex: "#C9A96E")

    private var governorsURL: URL? {
        let parts = ws.serverHost.split(separator: ":")
        let ip = parts.first ?? "localhost"
        return URL(string: "http://\(ip):8080/governors/")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#1A1A2E").ignoresSafeArea()

                if let url = governorsURL {
                    WebViewWrapper(url: url, isLoading: $isLoading, webView: $webView)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    Text("Invalid server URL")
                        .foregroundColor(Color(hex: "#888888"))
                }

                if isLoading {
                    ProgressView("Loading Governors Agent...")
                        .foregroundColor(accent)
                }
            }
            .navigationTitle("Governors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: "#16213E"), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showResetConfirm = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("New Chat")
                                .font(.system(size: 13))
                        }
                        .foregroundColor(accent)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let url = governorsURL {
                            webView?.load(URLRequest(url: url))
                            isLoading = true
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(accent)
                    }
                }
            }
            .alert("New Chat", isPresented: $showResetConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Clear Chat", role: .destructive) {
                    resetChat()
                }
            } message: {
                Text("This will clear the conversation for all users. Start fresh?")
            }
        }
    }

    private func resetChat() {
        let parts = ws.serverHost.split(separator: ":")
        let ip = parts.first ?? "localhost"
        guard let url = URL(string: "http://\(ip):8081/governors-reset") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        Task {
            _ = try? await URLSession.shared.data(for: request)
            // Reload the WebView after reset
            if let govURL = governorsURL {
                await MainActor.run {
                    webView?.load(URLRequest(url: govURL))
                    isLoading = true
                }
            }
        }
    }
}

struct WebViewWrapper: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var webView: WKWebView?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1)
        wv.scrollView.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1)
        wv.load(URLRequest(url: url))

        DispatchQueue.main.async {
            webView = wv
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebViewWrapper
        init(_ parent: WebViewWrapper) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in parent.isLoading = false }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in parent.isLoading = false }
        }
    }
}
