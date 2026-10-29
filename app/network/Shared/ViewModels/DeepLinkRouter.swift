//
//  DeepLinkRouter.swift
//  URnetwork
//
//  Holds a widget tap's destination until the view that can show it is on
//  screen: the tab view switches to the connect tab as soon as one is
//  pending, and the connect view presents the sheet (provider details or
//  client contracts) and consumes it. Pending survives the welcome animation
//  and a tab that is not yet mounted, so a cold launch from a widget lands on
//  the right screen too.
//

import Combine
import Foundation

@MainActor
final class DeepLinkRouter: ObservableObject {

    @Published private(set) var pending: WidgetDestination? = nil

    /// An onboarding email link's destination, until the tab view routes it.
    @Published private(set) var pendingOnboarding: OnboardingDestination? = nil
    /// A page the account tab should push once it is on screen.
    @Published private(set) var pendingAccountPath: AccountNavigationPath? = nil
    /// What the feedback screen should start with once it is on screen.
    @Published private(set) var pendingFeedback: FeedbackPrefill? = nil
    /// A Stripe checkout return (urnetwork://pay/done, urnetwork://checkout?...)
    /// from the browser, until the direct-download build's store takes it.
    @Published private(set) var pendingBilling: BillingDeepLink? = nil
    /// A Google or Apple browser sign-in return (urnetwork://oauth/<provider>)
    /// from the api's callback, until the login screen or the add sign-in
    /// method sheet checks it against the attempt it started.
    @Published private(set) var pendingBrowserSso: BrowserSso.Return? = nil
    /// A Top 200 sign link (urnetwork://top200/sign?binding=...) from the
    /// ur.io page, until the tab view opens Account > Sign fleet binding.
    @Published private(set) var pendingTop200Sign: Top200SignDestination? = nil
    /// The Protocol leaderboard's Claim on Earnings, until the tab view
    /// switches to the account tab (apple/LEADERTOP.md §5).
    @Published private(set) var pendingEarningsTop200 = false
    /// The Earnings screen scrolls to its Top 200 tile once the tile shows.
    @Published private(set) var pendingEarningsTop200Scroll = false
    /// The Earnings Top 200 tile's "See the Protocol leaderboard", until the
    /// tab view switches to the leaderboard.
    @Published private(set) var pendingProtocolLeaderboard = false
    /// The leaderboard selects its Protocol tab once it is on screen.
    @Published private(set) var pendingLeaderboardProtocol = false

    func open(_ destination: WidgetDestination) {
        pending = destination
    }

    func open(_ destination: OnboardingDestination) {
        pendingOnboarding = destination
    }

    func open(_ link: BillingDeepLink) {
        pendingBilling = link
    }

    func open(_ ssoReturn: BrowserSso.Return) {
        pendingBrowserSso = ssoReturn
    }

    func open(_ link: Top200SignDestination) {
        pendingTop200Sign = link
    }

    func pushAccount(_ path: AccountNavigationPath) {
        pendingAccountPath = path
    }

    /// Account › Earnings, scrolled to its Top 200 tile.
    func openEarningsTop200() {
        pendingEarningsTop200 = true
    }

    /// The leaderboard on its Protocol tab.
    func openProtocolLeaderboard() {
        pendingProtocolLeaderboard = true
    }

    func prefillFeedback(_ prefill: FeedbackPrefill) {
        pendingFeedback = prefill
    }

    // Every consume below writes only when there is something to take: see consume().

    func consumeOnboarding() -> OnboardingDestination? {
        guard let destination = pendingOnboarding else { return nil }
        pendingOnboarding = nil
        return destination
    }

    func consumeBilling() -> BillingDeepLink? {
        guard let link = pendingBilling else { return nil }
        pendingBilling = nil
        return link
    }

    func consumeBrowserSso() -> BrowserSso.Return? {
        guard let ssoReturn = pendingBrowserSso else { return nil }
        pendingBrowserSso = nil
        return ssoReturn
    }

    func consumeTop200Sign() -> Top200SignDestination? {
        guard let link = pendingTop200Sign else { return nil }
        pendingTop200Sign = nil
        return link
    }

    /**
     * The tab view takes Claim on Earnings: true when there was one, and
     * the tab view then shows the account tab. The account tab is handed
     * Earnings to open, and Earnings the scroll to its Top 200 tile.
     */
    func consumeEarningsTop200() -> Bool {
        guard pendingEarningsTop200 else { return false }
        pendingEarningsTop200 = false
        pendingAccountPath = .earnings
        pendingEarningsTop200Scroll = true
        return true
    }

    /// The Earnings screen takes the scroll to its Top 200 tile.
    func consumeEarningsTop200Scroll() -> Bool {
        guard pendingEarningsTop200Scroll else { return false }
        pendingEarningsTop200Scroll = false
        return true
    }

    /// The Earnings screen left before its Top 200 tile showed: the scroll
    /// is dropped, so a later visit does not jump.
    func cancelEarningsTop200Scroll() {
        if pendingEarningsTop200Scroll {
            pendingEarningsTop200Scroll = false
        }
    }

    /// The tab view takes "See the Protocol leaderboard": true when there
    /// was one, and the tab view then shows the leaderboard, which is handed
    /// its Protocol tab to select.
    func consumeProtocolLeaderboard() -> Bool {
        guard pendingProtocolLeaderboard else { return false }
        pendingProtocolLeaderboard = false
        pendingLeaderboardProtocol = true
        return true
    }

    /// The leaderboard takes its Protocol tab.
    func consumeLeaderboardProtocol() -> Bool {
        guard pendingLeaderboardProtocol else { return false }
        pendingLeaderboardProtocol = false
        return true
    }

    func consumeAccountPath() -> AccountNavigationPath? {
        guard let path = pendingAccountPath else { return nil }
        pendingAccountPath = nil
        return path
    }

    func consumeFeedback() -> FeedbackPrefill? {
        guard let prefill = pendingFeedback else { return nil }
        pendingFeedback = nil
        return prefill
    }

    /// Takes the pending destination, if any.
    ///
    /// Writes `pending` only when there is something to take. The connect
    /// view calls this from `.onReceive(deepLinkRouter.$pending)`, and a
    /// `@Published` property publishes on every assignment, nil to nil
    /// included: an unconditional `pending = nil` here re-published, which
    /// re-ran that closure, which consumed again, forever. That livelock
    /// pinned the main thread (blank screens after sign-in) until the
    /// watchdog killed the app (0x8BADF00D, "failed to terminate gracefully").
    func consume() -> WidgetDestination? {
        guard let destination = pending else { return nil }
        pending = nil
        return destination
    }
}
