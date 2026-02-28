import SwiftUI
import WebKit
import os

private let termLog = Logger(subsystem: "com.timtrailor.claudecode", category: "terminal")

struct TerminalView: View {
    @EnvironmentObject var ws: WebSocketService
    @State private var isLoading = true
    @State private var webView: WKWebView?
    @State private var loadError: String?
    @State private var isResetting = false
    @State private var showCopied = false
    @State private var isExporting = false
    @State private var exportStatus: String?
    @State private var exportStatusIsError = false
    @State private var showGoogleAuth = false
    @State private var googleAuthURL: URL?

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
                        // Export to Google Docs — captures full scrollback
                        Button {
                            exportToGoogleDocs()
                        } label: {
                            if isExporting {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(accent)
                            } else {
                                Image(systemName: "doc.text")
                                    .foregroundColor(accent)
                                    .font(.system(size: 14))
                            }
                        }
                        .disabled(isExporting)

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
        .overlay(alignment: .bottom) {
            if let status = exportStatus {
                HStack {
                    Image(systemName: exportStatusIsError ? "xmark.circle" : "checkmark.circle")
                        .foregroundColor(exportStatusIsError ? .red : .green)
                    Text(status)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(hex: "#16213E").opacity(0.95))
                .cornerRadius(10)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        withAnimation { exportStatus = nil }
                    }
                }
            }
        }
        .sheet(isPresented: $showGoogleAuth) {
            if let authURL = googleAuthURL {
                GoogleAuthSheet(
                    url: authURL,
                    onCode: { code in
                        showGoogleAuth = false
                        completeGoogleAuth(code: code)
                    },
                    onCancel: {
                        showGoogleAuth = false
                        isExporting = false
                    }
                )
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
                _ = await MainActor.run {
                    webView?.load(URLRequest(url: termURL))
                }
            }
        }
    }

    // MARK: - Export to Google Docs

    private var serverBaseURL: String {
        let parts = ws.serverHost.split(separator: ":")
        let ip = parts.first ?? "100.126.253.40"
        return "http://\(ip):8081"
    }

    private func exportToGoogleDocs() {
        isExporting = true
        exportStatus = nil

        // Capture ALL terminal content (full scrollback buffer)
        let js = """
        (function() {
            var term = window.term;
            if (!term) return '';
            var buf = term.buffer.active;
            var lines = [];
            for (var i = 0; i < buf.length; i++) {
                var line = buf.getLine(i);
                if (line) lines.push(line.translateToString(true));
            }
            return lines.join('\\n');
        })()
        """

        webView?.evaluateJavaScript(js) { result, _ in
            let text = (result as? String) ?? ""
            if text.isEmpty {
                isExporting = false
                exportStatus = "No terminal content to export"
                exportStatusIsError = true
                return
            }
            sendToGoogleDocs(text: text)
        }
    }

    private func sendToGoogleDocs(text: String) {
        guard let url = URL(string: "\(serverBaseURL)/terminal-to-doc") else {
            isExporting = false
            exportStatus = "Invalid server URL"
            exportStatusIsError = true
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = UserDefaults.standard.string(forKey: "authToken") ?? ""
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let ok = json["ok"] as? Bool ?? false
                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

                await MainActor.run {
                    if ok, let docURL = json["doc_url"] as? String,
                       let url = URL(string: docURL) {
                        isExporting = false
                        exportStatus = "Google Doc created"
                        exportStatusIsError = false
                        UIApplication.shared.open(url)
                    } else if httpStatus == 503 {
                        // Google Docs auth not set up — start auth flow
                        startGoogleDocsAuth(pendingText: text)
                    } else {
                        isExporting = false
                        let error = json["error"] as? String ?? "Unknown error"
                        exportStatus = "Export failed: \(error)"
                        exportStatusIsError = true
                    }
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportStatus = "Export failed: \(error.localizedDescription)"
                    exportStatusIsError = true
                }
            }
        }
    }

    @State private var pendingExportText: String?

    private func startGoogleDocsAuth(pendingText: String) {
        pendingExportText = pendingText

        guard let url = URL(string: "\(serverBaseURL)/google-docs-auth-start") else {
            isExporting = false
            exportStatus = "Invalid server URL"
            exportStatusIsError = true
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

                if let authURLString = json["url"] as? String,
                   let authURL = URL(string: authURLString) {
                    await MainActor.run {
                        googleAuthURL = authURL
                        showGoogleAuth = true
                    }
                } else {
                    await MainActor.run {
                        isExporting = false
                        exportStatus = "Auth setup failed"
                        exportStatusIsError = true
                    }
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportStatus = "Auth failed: \(error.localizedDescription)"
                    exportStatusIsError = true
                }
            }
        }
    }

    private func completeGoogleAuth(code: String) {
        guard let url = URL(string: "\(serverBaseURL)/google-docs-auth-complete") else {
            isExporting = false
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

                if ok, let text = pendingExportText {
                    // Retry the doc creation now that auth is set up
                    await MainActor.run {
                        sendToGoogleDocs(text: text)
                    }
                } else {
                    await MainActor.run {
                        isExporting = false
                        exportStatus = "Google auth failed"
                        exportStatusIsError = true
                    }
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportStatus = "Auth failed: \(error.localizedDescription)"
                    exportStatusIsError = true
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
        config.suppressesIncrementalRendering = false

        // Message handler for JS → Swift logging
        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "termLog")

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

        termLog.info("WKWebView created — scrollEnabled=\(wv.scrollView.isScrollEnabled) panEnabled=\(wv.scrollView.panGestureRecognizer.isEnabled) bounces=\(wv.scrollView.bounces)")

        DispatchQueue.main.async {
            webView = wv
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: TerminalWebViewWrapper
        init(_ parent: TerminalWebViewWrapper) { self.parent = parent }

        // JS → Swift log bridge
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if let body = message.body as? String {
                termLog.info("JS: \(body)")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            termLog.info("didFinish navigation — injecting terminal setup + scroll diagnostics")

            // Re-enforce native scroll disable after navigation completes
            // (WKWebView can reset these on process swap / navigation)
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.panGestureRecognizer.isEnabled = false
            webView.scrollView.bounces = false
            termLog.info("Post-nav scrollView: scrollEnabled=\(webView.scrollView.isScrollEnabled) panEnabled=\(webView.scrollView.panGestureRecognizer.isEnabled)")

            let js = """
            (function() {
                var log = function(msg) {
                    window.webkit.messageHandlers.termLog.postMessage(msg);
                };

                function setup() {
                    if (!window.term) return false;

                    log('xterm.js found — setting up');
                    window.term.options.scrollback = 5000;

                    var viewport = document.querySelector('.xterm-viewport');
                    if (viewport) {
                        viewport.style.overflow = 'hidden';
                        viewport.style.touchAction = 'none';
                        log('viewport: overflow=' + viewport.style.overflow +
                            ' touchAction=' + viewport.style.touchAction);
                    } else {
                        log('WARNING: .xterm-viewport not found');
                    }

                    // Scroll diagnostics — track touch events and xterm scroll position
                    var touchCount = 0;
                    var lastScrollTop = 0;
                    var scrollIssueLogged = false;

                    var xtermEl = document.querySelector('.xterm');
                    if (xtermEl) {
                        xtermEl.addEventListener('touchstart', function(e) {
                            touchCount++;
                            var buf = window.term.buffer.active;
                            log('touchstart #' + touchCount +
                                ' touches=' + e.touches.length +
                                ' bufBaseY=' + buf.baseY +
                                ' cursorY=' + buf.cursorY +
                                ' viewportY=' + buf.viewportY);
                        }, {passive: true});

                        xtermEl.addEventListener('touchmove', function(e) {
                            // Only log every 10th to avoid spam
                            if (touchCount % 10 === 0) {
                                var buf = window.term.buffer.active;
                                log('touchmove viewportY=' + buf.viewportY +
                                    ' baseY=' + buf.baseY +
                                    ' cancelled=' + e.defaultPrevented);
                            }
                        }, {passive: true});

                        xtermEl.addEventListener('touchend', function(e) {
                            var buf = window.term.buffer.active;
                            log('touchend viewportY=' + buf.viewportY +
                                ' baseY=' + buf.baseY);
                        }, {passive: true});

                        log('Touch listeners attached to .xterm element');
                    } else {
                        log('WARNING: .xterm element not found for touch listeners');
                    }

                    // Monitor for scroll breakage — periodic check
                    setInterval(function() {
                        if (!window.term) return;
                        var buf = window.term.buffer.active;
                        var vp = document.querySelector('.xterm-viewport');
                        if (vp) {
                            var vpStyle = getComputedStyle(vp);
                            var ta = vpStyle.touchAction || 'unset';
                            var ov = vpStyle.overflow || 'unset';
                            // Detect if something reset our styles
                            if (ta !== 'none' || (ov !== 'hidden' && ov !== '')) {
                                if (!scrollIssueLogged) {
                                    log('SCROLL ISSUE: viewport styles changed — ' +
                                        'touchAction=' + ta + ' overflow=' + ov +
                                        ' — resetting');
                                    vp.style.overflow = 'hidden';
                                    vp.style.touchAction = 'none';
                                    scrollIssueLogged = true;
                                    // Reset flag after 5s so we catch it again
                                    setTimeout(function() { scrollIssueLogged = false; }, 5000);
                                }
                            }
                        }
                    }, 2000);

                    log('Setup complete — scrollback=' + window.term.options.scrollback);
                    return true;
                }

                if (!setup()) {
                    log('term not ready — retrying');
                    setTimeout(function() { if (!setup()) { setTimeout(setup, 1500); } }, 500);
                }
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
