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
//  A 3D Secure challenge runs in Stripe's frames on the page. One that opens
//  a window instead (by script, or by posting a form to it, from Stripe's
//  frames or the bank page inside them) gets a small window in the app
//  (StripeChallengeWindows), since in the browser it could not answer the
//  page that opened it. Nothing else opens a window in the app
//  (StripeCheckoutLinks.newWindow). The pages' alert() and confirm() show as
//  sheets (CheckoutJavaScriptPanels): without them alert() showed nothing and
//  confirm() read as Cancel.
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
    /// Hands a URL to the default browser (tests record it instead).
    var openInBrowser: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = Self.makeWebView(coordinator: context.coordinator)
        context.coordinator.load(request, in: webView)
        return webView
    }

    /// The checkout web view, its delegates the coordinator.
    static func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // the handler holds its target strongly and the web view holds the
        // handler: a weak proxy breaks the cycle
        configuration.userContentController.add(
            ScriptMessageProxy(coordinator),
            name: StripeCheckoutLinks.payMessageHandler
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.checkoutWebView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(request, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.challengeWindows.closeAll()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: StripeCheckoutLinks.payMessageHandler)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

        var parent: StripeCheckoutWebView
        /// The 3D Secure challenge windows the page opened.
        let challengeWindows = StripeChallengeWindows()
        /// The checkout page's own web view. A challenge window's web view
        /// shares its configuration, `urpay` handler and all, so a message
        /// counts only from this one.
        weak var checkoutWebView: WKWebView?
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
            // a challenge belongs to the page that opened it
            challengeWindows.closeAll()
            webView.load(URLRequest(url: request.url))
        }

        // MARK: the pay page's message

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == StripeCheckoutLinks.payMessageHandler else {
                return
            }
            // the pay page speaks; a challenge window does not
            guard let checkoutWebView, message.webView === checkoutWebView else {
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
            switch StripeCheckoutLinks.navigation(
                for: url,
                targetsNewWindow: navigationAction.targetFrame == nil,
                linkActivated: navigationAction.navigationType == .linkActivated,
                fromSubframe: !navigationAction.sourceFrame.isMainFrame
            ) {
            case .handBack(let link):
                decisionHandler(.cancel)
                parent.onReturn(link)
            case .openInBrowser:
                decisionHandler(.cancel)
                parent.openInBrowser(url)
            case .load:
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let url = navigationAction.request.url
            switch StripeCheckoutLinks.newWindow(
                for: url,
                linkActivated: navigationAction.navigationType == .linkActivated,
                fromSubframe: !navigationAction.sourceFrame.isMainFrame
            ) {
            case .challengeWindow:
                // a 3D Secure challenge's window: in the app, where it can
                // answer the frame that opened it
                return challengeWindows.open(configuration: configuration, windowFeatures: windowFeatures, over: webView)
            case .browser:
                // window.open / target=_blank: the default browser, never a new web view
                if let url {
                    parent.openInBrowser(url)
                }
            case .nothing:
                break
            }
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            CheckoutJavaScriptPanels.alert(message, from: frame, in: webView, done: completionHandler)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            CheckoutJavaScriptPanels.confirm(message, from: frame, in: webView, done: completionHandler)
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
            challengeWindows.closeAll()
            parent.onProcessTerminated()
        }
    }
}

/// The small windows a 3D Secure challenge opens over the checkout page
/// (StripeCheckoutNewWindow.challengeWindow). Each is a web view on the
/// configuration WebKit hands over, which ties it to the frame that opened
/// it, in a window of the size it asked for, kept above the checkout. Inside
/// it only https pages load, it opens no windows of its own (a link goes to
/// the browser), and it closes when its page closes it, when the user does,
/// or with the checkout page.
@MainActor
final class StripeChallengeWindows: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {

    /// Hands a URL to the default browser (tests record it instead).
    var openInBrowser: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }

    private var windows: [(window: NSWindow, webView: WKWebView)] = []

    /// The open windows' web views, oldest first.
    var webViews: [WKWebView] {
        windows.map(\.webView)
    }

    /// The window a challenge's web view is in.
    func window(of webView: WKWebView) -> NSWindow? {
        windows.first { $0.webView === webView }?.window
    }

    /// The window's content size: what the page asked for, within reason.
    static func contentSize(width: Double?, height: Double?) -> NSSize {
        NSSize(
            width: min(max(width ?? 500, 320), 1000),
            height: min(max(height ?? 640, 400), 900)
        )
    }

    /// Opens a window for the web view WebKit asked for, and returns the web
    /// view, which WebKit then loads the window's page into.
    func open(configuration: WKWebViewConfiguration, windowFeatures: WKWindowFeatures, over opener: WKWebView) -> WKWebView {
        let size = Self.contentSize(width: windowFeatures.width?.doubleValue, height: windowFeatures.height?.doubleValue)
        let webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        if let openerWindow = opener.window {
            // centered over the checkout, and kept above it
            let frame = window.frame
            window.setFrameOrigin(NSPoint(
                x: openerWindow.frame.midX - frame.width / 2,
                y: openerWindow.frame.midY - frame.height / 2
            ))
            openerWindow.addChildWindow(window, ordered: .above)
        } else {
            window.center()
        }
        windows.append((window, webView))
        window.makeKeyAndOrderFront(nil)
        return webView
    }

    func closeAll() {
        let open = windows
        windows.removeAll()
        for (window, webView) in open {
            Self.tearDown(window, webView)
            window.close()
        }
    }

    private func close(_ webView: WKWebView) {
        window(of: webView)?.close()
    }

    private static func tearDown(_ window: NSWindow, _ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        window.delegate = nil
        window.parent?.removeChildWindow(window)
    }

    // MARK: WKUIDelegate

    func webViewDidClose(_ webView: WKWebView) {
        // window.close() from its page, or from the frame that opened it
        close(webView)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // no window from a challenge's window: a link goes to the browser
        if let url = navigationAction.request.url,
           StripeCheckoutLinks.newWindow(for: url, linkActivated: true, fromSubframe: false) == .browser {
            openInBrowser(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        CheckoutJavaScriptPanels.alert(message, from: frame, in: webView, done: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        CheckoutJavaScriptPanels.confirm(message, from: frame, in: webView, done: completionHandler)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(StripeCheckoutLinks.challengeWindowLoads(url) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // whose page it is, where a browser shows its address
        window(of: webView)?.title = webView.url?.host ?? ""
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        close(webView)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // closed by its page or by the user
        guard let window = notification.object as? NSWindow,
              let index = windows.firstIndex(where: { $0.window === window }) else {
            return
        }
        Self.tearDown(window, windows.remove(at: index).webView)
    }
}

/// The checkout pages' alert() and confirm() (a bank's check can ask either),
/// as sheets on the window the page is in, saying whose page asks. With no
/// window to show one on, the page gets what WebKit answers with none: alert()
/// returns, confirm() reads as Cancel.
@MainActor
enum CheckoutJavaScriptPanels {

    static func alert(_ message: String, from frame: WKFrameInfo, in webView: WKWebView, done: @escaping () -> Void) {
        // its one button is AppKit's own OK
        let alert = makeAlert(message, host: frame.securityOrigin.host)
        present(alert, in: webView) { _ in
            done()
        }
    }

    static func confirm(_ message: String, from frame: WKFrameInfo, in webView: WKWebView, done: @escaping (Bool) -> Void) {
        let alert = makeConfirm(message, host: frame.securityOrigin.host)
        present(alert, in: webView) { response in
            done(answer(response))
        }
    }

    static func makeAlert(_ message: String, host: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = host
        return alert
    }

    /// OK and Cancel. The OK is AppKit's own, in the user's language: the
    /// button an alert has before any is added.
    static func makeConfirm(_ message: String, host: String) -> NSAlert {
        let alert = makeAlert(message, host: host)
        let ok = alert.buttons.first?.title ?? String(localized: "Continue")
        alert.addButton(withTitle: ok)
        // AppKit gives Escape to a button titled Cancel only in English
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        return alert
    }

    /// confirm()'s answer for the button that ended the panel.
    static func answer(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertFirstButtonReturn
    }

    private static func present(_ alert: NSAlert, in webView: WKWebView, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window = webView.window else {
            completion(.cancel)
            return
        }
        alert.beginSheetModal(for: window, completionHandler: completion)
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
