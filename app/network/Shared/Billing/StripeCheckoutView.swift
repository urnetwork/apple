//
//  StripeCheckoutView.swift
//  URnetwork
//
//  The checkout page inside the upgrade sheet (macOS, direct-download build):
//  a WKWebView on the ur.io pay page or the embedded checkout bridge, with
//  the `urpay` script message handler and the urnetwork:// return handled
//  through StripeCheckoutLinks. target=_blank links (Stripe's terms/privacy)
//  open in the default browser. The card form stays in Stripe's iframe; no
//  card data touches the app.
//

#if os(macOS)

import AppKit
import SwiftUI
import WebKit

struct StripeCheckoutView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let request: StripeCheckoutRequest
    @ObservedObject var store: StripeSubscriptionStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Get Pro")
                    .font(themeManager.currentTheme.titleFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                Spacer()
                Button(action: {
                    store.cancelCheckout()
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Close"))
            }
            .padding()

            StripeCheckoutWebView(
                request: request,
                onReturn: { link in store.handle(link) },
                onPayMessage: { body in store.handlePayMessage(body) },
                onLoadFailed: { store.handleLoadFailed() },
                onProcessTerminated: { store.handleProcessTerminated() }
            )
            .frame(minWidth: 480, minHeight: 560)
        }
        .background(themeManager.currentTheme.backgroundColor)
    }
}

struct StripeCheckoutWebView: NSViewRepresentable {

    let request: StripeCheckoutRequest
    let onReturn: (BillingDeepLink) -> Void
    let onPayMessage: (Any) -> Void
    let onLoadFailed: () -> Void
    let onProcessTerminated: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // the handler holds its target strongly and the web view holds the
        // handler: a weak proxy breaks the cycle
        configuration.userContentController.add(
            ScriptMessageProxy(context.coordinator),
            name: StripeCheckoutLinks.payMessageHandler
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.load(request, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(request, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: StripeCheckoutLinks.payMessageHandler)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

        var parent: StripeCheckoutWebView
        private var loadedRequestId: Int?
        private var pageLoaded = false

        init(_ parent: StripeCheckoutWebView) {
            self.parent = parent
        }

        func load(_ request: StripeCheckoutRequest, in webView: WKWebView) {
            guard loadedRequestId != request.id else {
                return
            }
            loadedRequestId = request.id
            pageLoaded = false
            webView.load(URLRequest(url: request.url))
        }

        // MARK: the pay page's message

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == StripeCheckoutLinks.payMessageHandler else {
                return
            }
            parent.onPayMessage(message.body)
        }

        // MARK: navigation

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            switch StripeCheckoutLinks.navigation(for: url, targetsNewWindow: navigationAction.targetFrame == nil) {
            case .handBack(let link):
                decisionHandler(.cancel)
                parent.onReturn(link)
            case .openInBrowser:
                decisionHandler(.cancel)
                NSWorkspace.shared.open(url)
            case .load:
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // window.open / target=_blank: the default browser, never a new web view
            if let url = navigationAction.request.url, !StripeCheckoutLinks.isReturnURL(url) {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loadFailed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loadFailed(error)
        }

        private func loadFailed(_ error: Error) {
            let nsError = error as NSError
            // our own policy cancels land here too; those are not failures
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
            // WKErrorFrameLoadInterruptedByPolicyChange (102): a navigation our
            // decidePolicyFor cancelled, not a page failure
            if nsError.domain == WKErrorDomain && nsError.code == 102 {
                return
            }
            // the page could not load at all: nothing rendered, nothing paid
            if !pageLoaded {
                parent.onLoadFailed()
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.onProcessTerminated()
        }
    }
}

/// Forwards script messages without retaining the coordinator.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

#endif
