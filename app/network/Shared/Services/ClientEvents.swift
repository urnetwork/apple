//
//  ClientEvents.swift
//  URnetwork
//
//  The app-wide product-event sender. One SDK ClientEventQueue lives for the
//  length of a session (created when the device session comes up, flushed
//  and closed at sign-out); every event goes through the SDK's typed
//  constructors, so the app can only send names and props the server's
//  closed schema accepts. Batching, persistence and retries are the queue's.
//

import Foundation
import URnetworkSdk

/// The onboarding pages in order, as the events name them.
enum IntroStep: Int, CaseIterable {
    case welcome = 0
    case usage
    case participate
    case refer
    case quickConnect
    case offer

    var name: String {
        switch self {
        case .welcome: return "welcome"
        case .usage: return "usage"
        case .participate: return "participate"
        case .refer: return "refer"
        case .quickConnect: return "quickConnect"
        case .offer: return "offer"
        }
    }

    /// The route that presents the step, nil for the first page.
    init?(route: IntroductionRoute) {
        switch route {
        case .usage: self = .usage
        case .participate: self = .participate
        case .refer: self = .refer
        case .quickConnect: self = .quickConnect
        case .offer: self = .offer
        }
    }
}

/// Where a step's elapsed time comes from: the moment it was shown.
struct IntroStepTiming {
    private var starts: [IntroStep: Date] = [:]

    mutating func shown(_ step: IntroStep, at date: Date = Date()) {
        starts[step] = date
    }

    /// Milliseconds since the step was shown; zero when it never was.
    mutating func elapsedMillis(_ step: IntroStep, at date: Date = Date()) -> Int64 {
        guard let start = starts.removeValue(forKey: step) else { return 0 }
        return max(0, Int64(date.timeIntervalSince(start) * 1000))
    }
}

@MainActor
final class ClientEvents: ObservableObject {

    static let shared = ClientEvents()

    private var queue: SdkClientEventQueue?
    private weak var boundNetworkSpace: SdkNetworkSpace?
    private var timing = IntroStepTiming()

    static var platform: String {
        #if os(macOS)
        return SdkEventPlatformMacos
        #else
        return SdkEventPlatformIos
        #endif
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    static var locale: String {
        Locale.current.identifier
    }

    /// Binds the sender to the session's network space; a new cold start is
    /// a new session. Re-binding to the same space is a no-op.
    func start(networkSpace: SdkNetworkSpace) {
        if queue != nil, boundNetworkSpace === networkSpace {
            return
        }
        stop(timeoutMillis: 500)
        guard let queue = SdkNewClientEventQueue(networkSpace, Self.platform, Self.appVersion, Self.locale) else {
            return
        }
        queue.newSession()
        self.queue = queue
        boundNetworkSpace = networkSpace
    }

    /// Flushes what is pending (bounded by the timeout) and drops the queue;
    /// sign-out and a session change go through here.
    func stop(timeoutMillis: Int64 = 2000) {
        guard let queue else { return }
        queue.flushAndWait(timeoutMillis)
        queue.close()
        self.queue = nil
        boundNetworkSpace = nil
    }

    /// Sends what is pending without waiting; the background transition calls this.
    func flush() {
        queue?.flush()
    }

    func add(_ event: SdkClientEvent?) {
        guard let event else { return }
        queue?.add(event)
    }

    // MARK: onboarding steps

    func stepShown(_ step: IntroStep) {
        timing.shown(step)
        add(SdkNewOnboardingStepShownEvent(step.name, step.rawValue, 0))
    }

    func stepCompleted(_ step: IntroStep) {
        add(SdkNewOnboardingStepCompletedEvent(step.name, step.rawValue, timing.elapsedMillis(step)))
    }

    func stepSkipped(_ step: IntroStep) {
        add(SdkNewOnboardingStepSkippedEvent(step.name, step.rawValue, timing.elapsedMillis(step)))
    }

    // MARK: the welcome offer

    func offerScreenShown(
        surface: String,
        experiment: String,
        variant: String,
        tier: String,
        priceShown: Double,
        currency: String,
        expiresInSeconds: Int64
    ) {
        add(SdkNewOfferScreenShownEvent(surface, experiment, variant, tier, priceShown, currency, expiresInSeconds))
    }

    func offerCardTapped(plan: String) {
        add(SdkNewOfferCardTappedEvent(plan))
    }

    func offerCtaTapped(plan: String, store: String = SdkEventStoreApple) {
        add(SdkNewOfferCtaTappedEvent(plan, store))
    }

    func offerDeclined(control: String, elapsedMillis: Int64) {
        add(SdkNewOfferDeclinedEvent(control, elapsedMillis))
    }

    // MARK: purchases

    func purchaseStarted(product: String, plan: String, trial: Bool, price: Double, currency: String) {
        add(SdkNewPurchaseStartedEvent(SdkEventStoreApple, product, plan, trial, price, currency))
    }

    func purchaseCompleted(product: String, plan: String, trial: Bool, price: Double, currency: String) {
        add(SdkNewPurchaseCompletedEvent(SdkEventStoreApple, product, plan, trial, price, currency))
    }

    func purchaseCancelled(product: String, plan: String, trial: Bool, price: Double, currency: String) {
        add(SdkNewPurchaseCancelledEvent(SdkEventStoreApple, product, plan, trial, price, currency))
    }

    func purchaseFailed(product: String, plan: String, trial: Bool, price: Double, currency: String, errorClass: String) {
        add(SdkNewPurchaseFailedEvent(SdkEventStoreApple, product, plan, trial, price, currency, errorClass))
    }

    // MARK: activation

    private static let connectFirstKey = "clientEvents.connectFirst"

    /// Once per network: the first successful connection.
    func connectFirst(networkId: String) {
        let key = Self.connectFirstKey + "." + networkId
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        add(SdkNewConnectFirstEvent())
    }

    private static let widgetKindsKey = "clientEvents.widgetKinds"

    /// The widget kinds the app has seen placed; new ones are reported once.
    func widgetsPlaced(kinds: [String]) {
        let seen = Set(UserDefaults.standard.stringArray(forKey: Self.widgetKindsKey) ?? [])
        let fresh = Set(kinds).subtracting(seen)
        guard !fresh.isEmpty else { return }
        for kind in fresh.sorted() {
            add(SdkNewWidgetAddedEvent(kind))
        }
        UserDefaults.standard.set(Array(seen.union(fresh)).sorted(), forKey: Self.widgetKindsKey)
    }

    func feedbackSubmitted(rating: Int, reason: String, text: String) {
        add(SdkNewFeedbackSubmittedEvent(rating, reason, text))
    }

    func signupOptoutChanged(productUpdates: Bool) {
        add(SdkNewSignupOptoutChangedEvent(productUpdates))
    }
}

/// The widget kinds as the events name them.
enum WidgetEventKind {
    static func name(forWidgetKind kind: String) -> String? {
        switch kind {
        case WidgetKinds.dashboard: return "dashboard"
        case WidgetKinds.providerGlobe: return "globe"
        case WidgetKinds.contracts: return "contracts"
        default: return nil
        }
    }
}
