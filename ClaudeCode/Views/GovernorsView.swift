import SwiftUI
import WebKit

struct GovernorsView: View {
    @EnvironmentObject var ws: WebSocketService
    @State private var isLoading = true
    @State private var webView: WKWebView?
    @State private var showResetConfirm = false
    @State private var loadError: String?

    // Picker state — persisted in UserDefaults
    @AppStorage("govSelectedSchool") private var selectedSchool = "victoria"
    @AppStorage("govSelectedModel") private var selectedModel = "haiku"

    private let accent = Color(hex: "#C9A96E")

    private let schoolOptions: [(label: String, value: String)] = [
        ("Victoria", "victoria"),
        ("Thomas Coram", "thomas_coram"),
        ("Both", "both"),
    ]

    private let modelOptions: [(label: String, value: String)] = [
        ("Haiku", "haiku"),
        ("Sonnet", "sonnet"),
        ("Gemini Flash", "gemini_flash"),
    ]

    private var governorsURL: URL? {
        let parts = ws.serverHost.split(separator: ":")
        let ip = parts.first ?? "100.126.253.40"
        return URL(string: "https://\(ip):8502/?app_user=tim&school=\(selectedSchool)&model=\(selectedModel)")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Compact picker bar
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "building.2")
                            .font(.system(size: 11))
                            .foregroundColor(accent)
                        Picker("School", selection: $selectedSchool) {
                            ForEach(schoolOptions, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(accent)
                    }

                    Divider()
                        .frame(height: 20)

                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11))
                            .foregroundColor(accent)
                        Picker("Model", selection: $selectedModel) {
                            ForEach(modelOptions, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(accent)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(hex: "#16213E"))
                .onChange(of: selectedSchool) { _, _ in reloadWebView() }
                .onChange(of: selectedModel) { _, _ in reloadWebView() }

                // WebView content
                ZStack {
                    Color(hex: "#1A1A2E").ignoresSafeArea()

                    if let url = governorsURL {
                        WebViewWrapper(url: url, isLoading: $isLoading, webView: $webView, loadError: $loadError)
                    } else {
                        Text("Invalid server URL")
                            .foregroundColor(Color(hex: "#888888"))
                    }

                    if isLoading {
                        ProgressView("Loading Governors Agent...")
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
                                if let url = governorsURL {
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
                        reloadWebView()
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

    private func reloadWebView() {
        loadError = nil
        if let url = governorsURL {
            webView?.load(URLRequest(url: url))
            isLoading = true
        }
    }

    private func resetChat() {
        let parts = ws.serverHost.split(separator: ":")
        let ip = parts.first ?? "100.126.253.40"
        guard let url = URL(string: "http://\(ip):8081/governors-reset") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        Task {
            _ = try? await URLSession.shared.data(for: request)
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
    @Binding var loadError: String?

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

        // Accept self-signed cert from our HTTPS reverse proxy
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
}
