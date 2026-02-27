import SwiftUI
import WebKit

struct TerminalView: View {
    @EnvironmentObject var ws: WebSocketService
    @State private var isLoading = true
    @State private var webView: WKWebView?
    @State private var loadError: String?
    @State private var isResetting = false
    @State private var showCopied = false

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
                    HStack(spacing: 14) {
                        // Copy — grabs xterm.js selection, falls back to last 100 lines
                        Button {
                            copyFromTerminal()
                        } label: {
                            ZStack {
                                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                    .foregroundColor(showCopied ? .green : accent)
                                    .font(.system(size: 14))
                            }
                        }

                        // Paste — sends clipboard text to terminal
                        Button {
                            pasteToTerminal()
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .foregroundColor(accent)
                                .font(.system(size: 14))
                        }

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

    private func copyFromTerminal() {
        // Try xterm.js selection first, fall back to visible screen content
        let js = """
        (function() {
            var term = window.term;
            if (term) {
                var sel = term.getSelection();
                if (sel && sel.length > 0) return sel;
                // No selection — grab last 100 visible lines
                var buf = term.buffer.active;
                var lines = [];
                var start = Math.max(0, buf.baseY + buf.cursorY - 100);
                var end = buf.baseY + buf.cursorY;
                for (var i = start; i <= end; i++) {
                    var line = buf.getLine(i);
                    if (line) lines.push(line.translateToString(true));
                }
                return lines.join('\\n');
            }
            return '';
        })()
        """
        webView?.evaluateJavaScript(js) { result, _ in
            if let text = result as? String, !text.isEmpty {
                UIPasteboard.general.string = text
                showCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showCopied = false
                }
            }
        }
    }

    private func pasteToTerminal() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        // Escape for JS string and send to xterm.js via ttyd's websocket
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        let js = """
        (function() {
            var term = window.term;
            if (term) {
                term.paste('\(escaped)');
                return true;
            }
            return false;
        })()
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
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
        // Disable WKWebView's native scrollView entirely so all touch/swipe
        // events pass through to xterm.js, which handles its own scrollback buffer.
        wv.scrollView.bounces = false
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.panGestureRecognizer.isEnabled = false
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
            // After ttyd/xterm.js loads, ensure touch scrolling works and
            // store a reference to the terminal for copy/paste operations.
            let js = """
            (function() {
                function setup() {
                    if (window.term) {
                        // Store ref for copy/paste buttons
                        window.term.options.scrollback = 5000;
                        // Enable xterm.js touch handling for mobile scroll
                        var viewport = document.querySelector('.xterm-viewport');
                        if (viewport) {
                            viewport.style.overflow = 'hidden';
                            viewport.style.touchAction = 'none';
                        }
                        return true;
                    }
                    return false;
                }
                if (!setup()) { setTimeout(setup, 500); setTimeout(setup, 1500); }
            })()
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
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
