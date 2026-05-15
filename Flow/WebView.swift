import SwiftUI
import WebKit

// MARK: - WebView

struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading:     Bool
    @Binding var errorMessage:  String?
    @Binding var canGoBack:     Bool
    @Binding var canGoForward:  Bool
    @Binding var webViewRef:    WKWebView?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Inject no-zoom viewport at document end, before any page script runs
        let noZoomScript = WKUserScript(
            source: """
            (function() {
                var m = document.querySelector('meta[name="viewport"]');
                if (!m) {
                    m = document.createElement('meta');
                    m.name = 'viewport';
                    document.head.appendChild(m);
                }
                m.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(noZoomScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.067, green: 0.071, blue: 0.039, alpha: 1)
        webView.scrollView.backgroundColor = .clear

        // Disable pinch-to-zoom at the UIScrollView level
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false

        // Also disable double-tap zoom via a passthrough gesture recogniser
        let doubleTapBlocker = UITapGestureRecognizer()
        doubleTapBlocker.numberOfTapsRequired = 2
        doubleTapBlocker.delegate = context.coordinator
        webView.scrollView.addGestureRecognizer(doubleTapBlocker)

        // Pull-to-refresh
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

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
        var parent: WebView
        var refreshControl: UIRefreshControl?

        init(_ parent: WebView) { self.parent = parent }

        // Allow the double-tap blocker to coexist but absorb the event (prevents zoom)
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            parent.webViewRef?.reload()
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading    = true
                self.parent.errorMessage = nil
            }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading     = false
                self.parent.canGoBack     = webView.canGoBack
                self.parent.canGoForward  = webView.canGoForward
                self.refreshControl?.endRefreshing()
            }
            // Re-enforce no-zoom after every load (page may reset viewport)
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

        func webView(_ webView: WKWebView,
                     decidePolicyFor _: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
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
    if let nav = base as? UINavigationController  { return topViewController(base: nav.visibleViewController) }
    if let tab = base as? UITabBarController      { return topViewController(base: tab.selectedViewController) }
    if let pres = base?.presentedViewController  { return topViewController(base: pres) }
    return base
}
