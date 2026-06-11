import SwiftUI
import WebKit

// MARK: - WebView

struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading:    Bool
    @Binding var errorMessage: String?
    @Binding var canGoBack:    Bool
    @Binding var canGoForward: Bool
    @Binding var webViewRef:   WKWebView?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Persistent storage — localStorage survives app restarts
        config.websiteDataStore = .default()

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Register message handlers
        config.userContentController.add(context.coordinator, name: "cognitoTokenExchange")
        config.userContentController.add(context.coordinator, name: "setUserId")

        // Patch handleOAuthCallback to do the token exchange natively (no CORS)
        let tokenPatch = WKUserScript(source: """
        (function() {
            function patch() {
                if (!window.tokenRefresh) { setTimeout(patch, 50); return; }
                window.tokenRefresh.handleOAuthCallback = async function() {
                    var code = new URLSearchParams(window.location.search).get('code');
                    if (!code) return false;
                    window.history.replaceState({}, document.title, window.location.pathname);
                    return new Promise(function(resolve) {
                        window.__cognitoTokenResult = function(tokens) {
                            if (!tokens) { resolve(false); return; }
                            localStorage.setItem('id_token',     tokens.id_token);
                            localStorage.setItem('access_token', tokens.access_token);
                            if (tokens.refresh_token) localStorage.setItem('refresh_token', tokens.refresh_token);
                            resolve(true);
                        };
                        window.webkit.messageHandlers.cognitoTokenExchange.postMessage({
                            code: code,
                            redirectUri: window.location.origin + window.location.pathname
                        });
                    });
                };
            }
            patch();
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(tokenPatch)

        // No-zoom
        let noZoom = WKUserScript(source: """
        (function() {
            var m = document.querySelector('meta[name="viewport"]');
            if (!m) { m = document.createElement('meta'); m.name='viewport'; document.head.appendChild(m); }
            m.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(noZoom)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // Allow back-swipe — needed so user can return from Cognito login page
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.067, green: 0.071, blue: 0.039, alpha: 1)
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false

        let refresh = UIRefreshControl()
        refresh.tintColor = UIColor(red: 0.788, green: 0.490, blue: 0.047, alpha: 1)
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.addSubview(refresh)
        context.coordinator.refreshControl = refresh

        DispatchQueue.main.async { webViewRef = webView }
        webView.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: WebView
        var refreshControl: UIRefreshControl?

        private let cognitoDomain = "https://us-west-1EcPW1b7GZ.auth.us-west-1.amazoncognito.com"
        private let clientId      = "2edr9uguhogu2sp507ck4ddbh4"
        // The dashboard URL — Cognito redirects back here after login
        private let dashboardURL  = "https://www.sensaro.net/Mobile/Business_Management/admin_dashboard.html"

        init(_ parent: WebView) { self.parent = parent }

        // MARK: WKScriptMessageHandler

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {

            case "cognitoTokenExchange":
                guard let body        = message.body as? [String: String],
                      let code        = body["code"],
                      let redirectUri = body["redirectUri"]
                else { return }
                Task { await exchangeCodeForTokens(code: code,
                                                   redirectUri: redirectUri,
                                                   webView: message.webView) }

            case "setUserId":
                if let email = message.body as? String {
                    print("[Satyr] user: \(email)")
                }

            default: break
            }
        }

        // Native token exchange — bypasses CORS
        private func exchangeCodeForTokens(code: String, redirectUri: String, webView: WKWebView?) async {
            guard let tokenURL = URL(string: "\(cognitoDomain)/oauth2/token") else { return }

            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "grant_type",   value: "authorization_code"),
                URLQueryItem(name: "client_id",    value: clientId),
                URLQueryItem(name: "code",         value: code),
                URLQueryItem(name: "redirect_uri", value: redirectUri),
            ]

            var request = URLRequest(url: tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = components.query?.data(using: .utf8)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    webView?.evaluateJavaScript(
                        "window.__cognitoTokenResult && window.__cognitoTokenResult(null);",
                        completionHandler: nil)
                    return
                }

                let idToken      = json["id_token"]      as? String ?? ""
                let accessToken  = json["access_token"]  as? String ?? ""
                let refreshToken = json["refresh_token"] as? String ?? ""

                let js = """
                window.__cognitoTokenResult && window.__cognitoTokenResult({
                    id_token:      \(escaped(idToken)),
                    access_token:  \(escaped(accessToken)),
                    refresh_token: \(escaped(refreshToken))
                });
                """
                webView?.evaluateJavaScript(js, completionHandler: nil)

            } catch {
                webView?.evaluateJavaScript(
                    "window.__cognitoTokenResult && window.__cognitoTokenResult(null);",
                    completionHandler: nil)
            }
        }

        private func escaped(_ s: String) -> String {
            let e = s.replacingOccurrences(of: "\\", with: "\\\\")
                     .replacingOccurrences(of: "\"", with: "\\\"")
                     .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(e)\""
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading    = true
                self.parent.errorMessage = nil
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading     = false
                self.parent.canGoBack     = webView.canGoBack
                self.parent.canGoForward  = webView.canGoForward
                self.refreshControl?.endRefreshing()
            }
            // Re-enforce no-zoom after every navigation
            webView.evaluateJavaScript("""
                var m = document.querySelector('meta[name="viewport"]');
                if (m) m.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
            """, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            handleError(error)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
            handleError(error)
        }
        private func handleError(_ error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.refreshControl?.endRefreshing()
                if (error as NSError).code != NSURLErrorCancelled {
                    self.parent.errorMessage = error.localizedDescription
                }
            }
        }

        // Allow all navigation — Cognito login happens in-WebView, redirect back is allowed
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            parent.webViewRef?.reload()
        }

        // MARK: WKUIDelegate

        func webView(_ webView: WKWebView,
                     createWebViewWith _: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures _: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
            return nil
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame _: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            topViewController()?.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame _: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "OK",     style: .default) { _ in completionHandler(true) })
            topViewController()?.present(alert, animated: true)
        }
    }
}

// MARK: - Helpers

private func topViewController(
    base: UIViewController? = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).first?.windows.first?.rootViewController
) -> UIViewController? {
    if let nav  = base as? UINavigationController  { return topViewController(base: nav.visibleViewController) }
    if let tab  = base as? UITabBarController      { return topViewController(base: tab.selectedViewController) }
    if let pres = base?.presentedViewController    { return topViewController(base: pres) }
    return base
}
