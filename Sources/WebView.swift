import SwiftUI
import WebKit

/// The Status sheet: Jax's own dashboard page, shown inside the app.
/// This is the only web page left. The talk screen is fully native.
struct StatusPage: View {
    let url: URL
    @State private var state: LoadState = .loading
    @State private var attempt = 0

    enum LoadState: Equatable {
        case loading, loaded
        case failed(String)
    }

    var body: some View {
        ZStack {
            Look.background.ignoresSafeArea()
            DashboardWeb(url: url, state: $state)
                .id(attempt)
                .opacity(state == .loaded ? 1 : 0)
                .ignoresSafeArea(edges: .bottom)
            switch state {
            case .loading:
                ProgressView().tint(Look.sky)
            case .failed(let why):
                VStack(spacing: 16) {
                    Text("Can't load status").font(.system(size: 20, weight: .semibold))
                    Text(why).font(.system(size: 16)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try again") { state = .loading; attempt += 1 }
                        .font(.system(size: 16, weight: .semibold))
                        .frame(minWidth: 160, minHeight: 48)
                        .background(Look.sky, in: Capsule())
                        .foregroundStyle(.black)
                }
                .padding(24)
            case .loaded:
                EmptyView()
            }
        }
    }
}

private struct DashboardWeb: UIViewRepresentable {
    let url: URL
    @Binding var state: StatusPage.LoadState

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Lock the page to the phone's width. No pinch zoom, no double-tap zoom.
        let lock = """
        var m = document.querySelector('meta[name=viewport]') || document.head.appendChild(document.createElement('meta'));
        m.name = 'viewport';
        m.content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no';
        """
        config.userContentController.addUserScript(
            WKUserScript(source: lock, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = UIColor(Look.background)
        web.scrollView.backgroundColor = UIColor(Look.background)
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.scrollView.bouncesZoom = false
        web.scrollView.minimumZoomScale = 1
        web.scrollView.maximumZoomScale = 1
        web.scrollView.alwaysBounceHorizontal = false
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: DashboardWeb
        init(_ parent: DashboardWeb) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.state = .loaded }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.state = .failed(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.state = .failed(error.localizedDescription) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // This sheet is for Jax only. Any other site opens in Safari.
            if action.targetFrame?.isMainFrame != false, let dest = action.request.url,
               let host = dest.host, host != parent.url.host {
                UIApplication.shared.open(dest)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
