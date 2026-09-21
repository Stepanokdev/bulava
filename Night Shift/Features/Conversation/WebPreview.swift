import SwiftUI
import WebKit

enum WebPreviewPhase: Equatable {
    case loading
    case shown
    case failed(String)
}

struct WebPreview: View {
    let url: URL
    var onClose: () -> Void

    @State private var title = ""

    @State private var currentURL: URL
    @State private var phase: WebPreviewPhase = .loading

    @State private var reloadToken = 0

    init(url: URL, onClose: @escaping () -> Void) {
        self.url = url
        self.onClose = onClose
        _currentURL = State(initialValue: url)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.line)
            content
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Palette.content)
    }

    @ViewBuilder private var content: some View {
        ZStack {
            EphemeralWebView(url: url, reloadToken: reloadToken,
                             title: $title, currentURL: $currentURL, phase: $phase)
            if case .failed(let reason) = phase { failure(reason) }
        }
    }

    private func failure(_ reason: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Palette.textFaint)
            Text("This page did not load")
                .font(Typo.cardTitle)
                .foregroundStyle(Palette.text)
            Text(reason)
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 8) {
                Button { phase = .loading; reloadToken += 1 } label: { Text("Try again") }
                Button { NSWorkspace.shared.open(currentURL) } label: { Text("Open in your browser") }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.content)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.icon(size: 26, glyph: 12))
                .help(Text("Close"))

            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? currentURL.host ?? currentURL.absoluteString : title)
                    .font(Typo.cardTitle)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)

                Text(currentURL.absoluteString)
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if phase == .loading { ProgressView().controlSize(.small) }

            Button { NSWorkspace.shared.open(currentURL) } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.icon(size: 26, glyph: 12))
            .help(Text("Open in your browser"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct EphemeralWebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int
    @Binding var title: String
    @Binding var currentURL: URL
    @Binding var phase: WebPreviewPhase

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        context.coordinator.lastToken = reloadToken
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastToken != reloadToken else { return }
        context.coordinator.lastToken = reloadToken
        view.load(URLRequest(url: currentURL))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: EphemeralWebView
        var lastToken = -1
        init(_ parent: EphemeralWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = action.request.url?.scheme?.lowercased()
            decisionHandler(scheme == "http" || scheme == "https" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.phase = .loading
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let url = webView.url { parent.currentURL = url }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url { parent.currentURL = url }
            parent.title = webView.title ?? ""
            parent.phase = .shown
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            fail(error)
        }

        private func fail(_ error: Error) {
            let ns = error as NSError
            guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) else { return }
            parent.phase = .failed(ns.localizedDescription)
        }
    }
}
