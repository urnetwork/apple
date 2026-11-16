//
//  StripeChallengeWindowTests.swift
//  networkTests
//
//  The checkout web view's windows and dialogs, in a real WKWebView (the
//  direct download's checkout, macOS). A 3D Secure challenge that opens a
//  window from Stripe's frames (by script, or by posting a form to it) gets a
//  window in the app, which answers the frame that opened it and closes when
//  it is closed; a window the checkout page itself opens still goes to the
//  browser; inside a challenge window only https loads; alert() and confirm()
//  show as sheets and answer the page.
//
//  The pages are local HTML on ur.io's address, with Stripe's frames played
//  by srcdoc frames, so nothing here reaches the network, except a posted
//  form's window, whose .invalid address fails to load after it opens.
//

#if os(macOS)

import AppKit
import Foundation
import Testing
import WebKit
@testable import URnetwork

@MainActor
@Suite(.serialized)
struct StripeChallengeWindowTests {

    /// What the checkout handed to the default browser, and back to the store.
    final class Recorder {
        var browser: [URL] = []
        var returns: [BillingDeepLink] = []
        var payMessages = 0
    }

    struct Harness {
        let coordinator: StripeCheckoutWebView.Coordinator
        let webView: WKWebView
        let recorder: Recorder

        var challenges: StripeChallengeWindows { coordinator.challengeWindows }
    }

    private static let base = URL(string: "https://ur.io/app/pay-sheet")!

    /// The checkout web view as makeNSView makes it, its browser recorded.
    private static func harness() -> Harness {
        let recorder = Recorder()
        let parent = StripeCheckoutWebView(
            request: StripeCheckoutRequest(id: 1, stage: .paySheet, url: base),
            onReturn: { recorder.returns.append($0) },
            onPayMessage: { _ in recorder.payMessages += 1 },
            onLoadFailed: {},
            onProcessTerminated: {},
            openInBrowser: { recorder.browser.append($0) }
        )
        let coordinator = StripeCheckoutWebView.Coordinator(parent)
        coordinator.challengeWindows.openInBrowser = { recorder.browser.append($0) }
        let webView = StripeCheckoutWebView.makeWebView(coordinator: coordinator)
        return Harness(coordinator: coordinator, webView: webView, recorder: recorder)
    }

    private struct TimedOut: Error {
        let what: String
    }

    /// Lets WebKit's work on the main run loop happen until `condition`.
    private static func waitUntil(_ what: String, timeout: Duration = .seconds(15), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else {
                throw TimedOut(what: what)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Runs a script without waiting for its answer (a dialog holds it).
    private static func run(_ script: String, in webView: WKWebView) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// A Stripe frame (a srcdoc frame on the page) running `script` in its body.
    private static func page(frameScript script: String) -> String {
        "<!doctype html><html><head><title>loading</title></head><body><iframe srcdoc=\"<body><script>\(script)</script></body>\"></iframe></body></html>"
    }

    // MARK: windows

    /// The frame gets its window, in the app and of the size it asked for,
    /// and closing it from the frame closes the window.
    @Test func aWindowStripesFrameOpensOpensInTheAppAndClosesWithIt() async throws {
        let harness = Self.harness()
        defer { harness.challenges.closeAll() }
        harness.webView.loadHTMLString(Self.page(frameScript: """
            var w = window.open('', 'challenge', 'width=420,height=560'); \
            parent.challenge = w; \
            parent.document.title = w ? 'opened' : 'blocked';
            """), baseURL: Self.base)
        try await Self.waitUntil("the frame's window") { harness.webView.title == "opened" || harness.webView.title == "blocked" }

        #expect(harness.webView.title == "opened")
        #expect(harness.challenges.webViews.count == 1)
        #expect(harness.recorder.browser.isEmpty)
        let challenge = try #require(harness.challenges.webViews.first)
        let window = try #require(harness.challenges.window(of: challenge))
        #expect(window.contentView === challenge)
        #expect(window.contentRect(forFrameRect: window.frame).size == NSSize(width: 420, height: 560))
        #expect(window.isVisible)

        // the frame that opened it closes it
        Self.run("challenge.close()", in: harness.webView)
        try await Self.waitUntil("the window to close") { harness.challenges.webViews.isEmpty }
        #expect(!window.isVisible)
    }

    /// The challenge's own page closing itself (window.close()) closes the window.
    @Test func aChallengeClosingItselfClosesTheWindow() async throws {
        let harness = Self.harness()
        defer { harness.challenges.closeAll() }
        harness.webView.loadHTMLString(Self.page(frameScript: """
            var w = window.open('about:blank', 'challenge'); \
            parent.document.title = w ? 'opened' : 'blocked';
            """), baseURL: Self.base)
        try await Self.waitUntil("the frame's window") { harness.challenges.webViews.count == 1 }

        let challenge = try #require(harness.challenges.webViews.first)
        Self.run("window.close()", in: challenge)
        try await Self.waitUntil("the window to close") { harness.challenges.webViews.isEmpty }
    }

    /// A form posted to a new window (a 3D Secure 1 style challenge) asks the
    /// navigation policy first, then gets its window in the app, where the
    /// posted form can arrive whole; the browser would have dropped it.
    @Test func aFormPostedToANewWindowGetsAWindowInTheApp() async throws {
        let harness = Self.harness()
        defer { harness.challenges.closeAll() }
        harness.webView.loadHTMLString(Self.page(frameScript: """
            var f = document.createElement('form'); f.method = 'post'; \
            f.action = 'https://acs.bank.invalid/challenge'; f.target = 'acs'; \
            var i = document.createElement('input'); i.name = 'PaReq'; i.value = 'x'; f.appendChild(i); \
            document.body.appendChild(f); f.submit(); \
            parent.document.title = 'posted';
            """), baseURL: Self.base)
        try await Self.waitUntil("the posted form's window") { harness.challenges.webViews.count == 1 }
        #expect(harness.recorder.browser.isEmpty)
    }

    /// A window the checkout page itself opens is not a challenge's: the
    /// browser, as before, and the page gets no window.
    @Test func aWindowThePageOpensGoesToTheBrowser() async throws {
        let harness = Self.harness()
        harness.webView.loadHTMLString("""
            <!doctype html><html><head><title>loading</title></head><body><script>
            var w = window.open('https://ur.io/terms', '_blank');
            document.title = w ? 'opened' : 'blocked';
            </script></body></html>
            """, baseURL: Self.base)
        try await Self.waitUntil("the page's window") { harness.webView.title == "opened" || harness.webView.title == "blocked" }

        #expect(harness.webView.title == "blocked")
        #expect(harness.recorder.browser == [URL(string: "https://ur.io/terms")!])
        #expect(harness.challenges.webViews.isEmpty)
    }

    /// Inside a challenge window a urnetwork:// return does not load and
    /// hands nothing back: only the checkout page hands back.
    @Test func aChallengeWindowLoadsNoReturn() async throws {
        let harness = Self.harness()
        defer { harness.challenges.closeAll() }
        harness.webView.loadHTMLString(Self.page(frameScript: """
            var w = window.open('about:blank', 'challenge'); \
            parent.document.title = w ? 'opened' : 'blocked';
            """), baseURL: Self.base)
        try await Self.waitUntil("the frame's window") { harness.challenges.webViews.count == 1 }
        let challenge = try #require(harness.challenges.webViews.first)

        Self.run("location.href = 'urnetwork://pay/done'", in: challenge)
        // the policy answers before the page could go anywhere
        try await Task.sleep(for: .milliseconds(500))
        #expect(harness.recorder.returns.isEmpty)
        #expect(challenge.url?.scheme != "urnetwork")
        #expect(harness.challenges.webViews.count == 1)
    }

    /// A challenge window's web view shares the checkout's configuration, its
    /// `urpay` handler included: only the pay page's own messages reach the
    /// store, so a challenge page cannot say the payment went through.
    @Test func onlyThePayPageSpeaksToTheStore() async throws {
        let harness = Self.harness()
        defer { harness.challenges.closeAll() }
        harness.webView.loadHTMLString(Self.page(frameScript: """
            var w = window.open('about:blank', 'challenge'); \
            parent.document.title = w ? 'opened' : 'blocked';
            """), baseURL: Self.base)
        try await Self.waitUntil("the frame's window") { harness.challenges.webViews.count == 1 }
        let challenge = try #require(harness.challenges.webViews.first)

        let succeeded = "window.webkit.messageHandlers.urpay.postMessage({type: 'ur-pay', status: 'succeeded'}); document.title = 'posted'"
        Self.run(succeeded, in: challenge)
        try await Self.waitUntil("the challenge's message") { challenge.title == "posted" }
        Self.run(succeeded, in: harness.webView)
        try await Self.waitUntil("the pay page's message") { harness.recorder.payMessages > 0 }
        // nothing else arrives behind it
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.recorder.payMessages == 1)
    }

    @Test func theWindowIsTheSizeAskedForWithinReason() {
        #expect(StripeChallengeWindows.contentSize(width: nil, height: nil) == NSSize(width: 500, height: 640))
        #expect(StripeChallengeWindows.contentSize(width: 390, height: 400) == NSSize(width: 390, height: 400))
        #expect(StripeChallengeWindows.contentSize(width: 10, height: 10) == NSSize(width: 320, height: 400))
        #expect(StripeChallengeWindows.contentSize(width: 5000, height: 5000) == NSSize(width: 1000, height: 900))
    }

    // MARK: dialogs

    @Test func confirmHasOKAndCancel() {
        let confirm = CheckoutJavaScriptPanels.makeConfirm("Leave the check?", host: "acs.bank.example")
        #expect(confirm.messageText == "Leave the check?")
        #expect(confirm.informativeText == "acs.bank.example")
        #expect(confirm.buttons.count == 2)
        #expect(confirm.buttons.map(\.keyEquivalent) == ["\r", "\u{1b}"])
        #expect(confirm.buttons.last?.title == String(localized: "Cancel"))
        #expect(CheckoutJavaScriptPanels.answer(.alertFirstButtonReturn))
        #expect(!CheckoutJavaScriptPanels.answer(.alertSecondButtonReturn))
        #expect(!CheckoutJavaScriptPanels.answer(.cancel))
    }

    /// alert() and confirm() show as sheets on the checkout's window and
    /// answer the page with the button that ended them.
    @Test func alertAndConfirmShowAsSheetsAndAnswerThePage() async throws {
        let harness = Self.harness()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = harness.webView
        window.orderFront(nil)
        defer { window.close() }
        harness.webView.loadHTMLString("<!doctype html><html><head><title>ready</title></head><body></body></html>", baseURL: Self.base)
        try await Self.waitUntil("the page") { harness.webView.title == "ready" && !harness.webView.isLoading }

        for (button, answer) in [(NSApplication.ModalResponse.alertFirstButtonReturn, "yes"), (.alertSecondButtonReturn, "no")] {
            Self.run("document.title = confirm('Leave the check?') ? 'yes' : 'no'", in: harness.webView)
            try await Self.waitUntil("the confirm sheet") { window.attachedSheet != nil }
            let sheet = try #require(window.attachedSheet)
            window.endSheet(sheet, returnCode: button)
            try await Self.waitUntil("confirm's answer") { harness.webView.title == answer }
        }

        Self.run("alert('Enter the code we sent.'); document.title = 'alerted'", in: harness.webView)
        try await Self.waitUntil("the alert sheet") { window.attachedSheet != nil }
        // the page waits on the alert
        #expect(harness.webView.title == "no")
        let sheet = try #require(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await Self.waitUntil("the page after the alert") { harness.webView.title == "alerted" }
    }

    /// With no window to show a sheet on, the page gets what WebKit answers
    /// with no dialog: confirm() is Cancel, and nothing hangs.
    @Test func withNoWindowConfirmIsCancel() async throws {
        let harness = Self.harness()
        harness.webView.loadHTMLString("""
            <!doctype html><html><head><title>loading</title></head><body><script>
            alert('x');
            document.title = confirm('Leave the check?') ? 'yes' : 'no';
            </script></body></html>
            """, baseURL: Self.base)
        try await Self.waitUntil("confirm's answer") { harness.webView.title == "yes" || harness.webView.title == "no" }
        #expect(harness.webView.title == "no")
    }
}

#endif
