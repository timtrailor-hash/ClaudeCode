import SwiftUI
import WebKit

/// Modal sheet that opens the Claude OAuth URL in a WKWebView.
/// Intercepts the redirect to `platform.claude.com/oauth/code/callback`
/// and extracts the `code` query parameter.
struct TerminalAuthSheet: View {
    let url: URL
    let onCode: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            OAuthWebView(url: url, onCode: onCode)
                .navigationTitle("Authenticate")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color(hex: "#16213E"), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onCancel() }
                            .foregroundColor(Color(hex: "#C9A96E"))
                    }
                }
        }
    }
}

struct OAuthWebView: UIViewRepresentable {
    let url: URL
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Allow inline media and JavaScript for Google SSO
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator  // Handle popups (Google SSO)
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
               let host = url.host,
               host.contains("platform.claude.com"),
               url.path.contains("/oauth/code/callback"),
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
                decisionHandler(.cancel)
                Task { @MainActor in onCode(code) }
                return
            }
            decisionHandler(.allow)
        }

        // MARK: - WKUIDelegate (handle popups for Google SSO)

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Google SSO tries to open a popup — load it in the same webview instead
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}
