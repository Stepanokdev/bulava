import SwiftUI
import WebKit

struct ReportWebView: NSViewRepresentable {
    let url: URL

    var onMake: ((WKWebView) -> Void)? = nil

    func makeCoordinator() -> Links { Links() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: config)
        web.underPageBackgroundColor = .clear
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        DispatchQueue.main.async { [onMake] in onMake?(web) }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        if web.url?.standardizedFileURL != url.standardizedFileURL {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    /// A link in a report opens in the browser. The view had no say over navigation, so a link — the
    /// bulava.app at the top of every report, one in the text — replaced the report in its own window,
    /// with no way back to it.
    final class Links: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url, Self.external(url) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// `target="_blank"` asks for a new view; the link goes to the browser instead.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, Self.external(url) { NSWorkspace.shared.open(url) }
            return nil
        }

        private static func external(_ url: URL) -> Bool {
            ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
        }
    }
}
