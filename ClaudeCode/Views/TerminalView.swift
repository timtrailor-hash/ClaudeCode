import SwiftUI
import WebKit

struct TerminalView: View {
    @EnvironmentObject var ws: WebSocketService
    @State private var isLoading = true
    @State private var webView: WKWebView?
    @State private var loadError: String?
    @State private var isResetting = false

    private let accent = Color(hex: "#C9A96E")

    private var terminalURL: URL? {
        let parts = ws.serverHost.split(separator: ":")
        let ip = parts.first ?? "100.126.253.40"
        // No auth — ttyd runs without --credential flag.
        // Protected by Tailscale private network (same as conversation_server).
        return URL(string: "http://\(ip):7681")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#1A1A2E").ignoresSafeArea()

                if let url = terminalURL {
                    TerminalWebViewWrapper(
                        url: url,
                        isLoading: $isLoading,
                        webView: $webView,
                        loadError: $loadError
                    )
                } else {
                    Text("Invalid server URL")
                        .foregroundColor(Color(hex: "#888888"))
                }

                if isLoading {
                    ProgressView("Loading Terminal...")
                        .foregroundColor(accent)
                }

                if let error = loadError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32))
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(hex: "#EE5555"))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                        Button("Retry") {
                            loadError = nil
                            isLoading = true
                            if let url = terminalURL {
                                webView?.load(URLRequest(url: url))
                            }
                        }
                        .foregroundColor(accent)
                        .padding(.top, 8)
                    }
                    .padding()
                    .background(Color(hex: "#1A1A2E").opacity(0.95))
                    .cornerRadius(12)
                }
            }
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: "#16213E"), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        newTmuxWindow()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.rectangle")
                            Text("New Session")
                                .font(.system(size: 13))
                        }
                        .foregroundColor(accent)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            resetTerminal()
                        } label: {
                            if isResetting {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(accent)
                            } else {
                                Image(systemName: "arrow.trianglehead.2.counterclockwise")
                                    .foregroundColor(accent)
                            }
                        }
                        .disabled(isResetting)

                        Button {
                            loadError = nil
                            if let url = terminalURL {
                                webView?.load(URLRequest(url: url))
                                isLoading = true
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(accent)
                        }
                    }
                }
            }
        }
    }

    private func resetTerminal() {
        let parts = ws.serverHost.split(separator: ":")
        let ip = parts.first ?? "100.126.253.40"
        guard let url = URL(string: "http://\(ip):8081/terminal-reset") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let token = UserDefaults.standard.string(forKey: "authToken") ?? ""
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        isResetting = true
        loadError = nil

        Task {
            do {
                let (_, _) = try await URLSession.shared.data(for: request)
                // Wait for ttyd to be ready
                try await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run {
                    isResetting = false
                    isLoading = true
                    if let termURL = terminalURL {
                        webView?.load(URLRequest(url: termURL))
                    }
                }
            } catch {
                await MainActor.run {
                    isResetting = false
                    loadError = "Reset failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func newTmuxWindow() {
        let parts = ws.serverHost.split(separator: ":")
        let ip = parts.first ?? "100.126.253.40"
        guard let url = URL(string: "http://\(ip):8081/terminal-new-window") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let token = UserDefaults.standard.string(forKey: "authToken") ?? ""
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        Task {
            _ = try? await URLSession.shared.data(for: request)
            // Reload the webview to show the new window
            if let termURL = terminalURL {
                await MainActor.run {
                    webView?.load(URLRequest(url: termURL))
                }
            }
        }
    }
}

/// WKWebView wrapper specialised for ttyd's xterm.js terminal.
/// Disables bounce scrolling so touch events pass through to xterm.js.
struct TerminalWebViewWrapper: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var webView: WKWebView?
    @Binding var loadError: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // Allow xterm.js to handle all keyboard input
        config.suppressesIncrementalRendering = false

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = UIColor.black
        wv.scrollView.backgroundColor = UIColor.black
        // Disable bounce but keep scroll enabled — xterm.js handles its own scrollback
        wv.scrollView.bounces = false
        wv.scrollView.isScrollEnabled = true
        wv.load(URLRequest(url: url))

        DispatchQueue.main.async {
            webView = wv
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: TerminalWebViewWrapper
        init(_ parent: TerminalWebViewWrapper) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in parent.isLoading = false }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                parent.isLoading = false
                parent.loadError = "Load failed: \(error.localizedDescription)"
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                parent.isLoading = false
                parent.loadError = "Connection failed: \(error.localizedDescription)"
            }
        }

        // No auth challenge handler needed — ttyd runs without credentials,
        // protected by Tailscale private network.
    }
}
