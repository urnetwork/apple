//
//  StorefrontLookupBoundTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * A balance read waits on the App Store storefront at most its bound
 * (SubscriptionBalanceViewModel's storefrontLookupTimeout). StoreKit's lookup
 * has no deadline and can't be cancelled, and while a read waited on it
 * isLoading held the welcome screen's Enter disabled (found with the App
 * Store review rejection of iOS 2026.11.19, guideline 2.1(a)).
 */
@MainActor
struct StorefrontLookupBoundTests {

    /// An answer the test gives when it chooses; one given before anyone
    /// waits is kept for the wait.
    private final class HeldAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var answered = false
        private var answer: String?
        private var waiter: CheckedContinuation<String?, Never>?

        func wait() async -> String? {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                lock.lock()
                if answered {
                    let answer = self.answer
                    lock.unlock()
                    continuation.resume(returning: answer)
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        }

        func give(_ value: String?) {
            lock.lock()
            answered = true
            answer = value
            let pending = waiter
            waiter = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    private struct BalanceUnavailable: Error {}

    /// Records each balance read's storefront and fails the read, so no read
    /// writes the dashboard snapshot.
    private final class StorefrontRecordingApi: MockUrApiService {
        var storefronts: [String?] = []

        override func fetchSubscriptionBalance(storefrontCountry: String?) async throws -> SdkSubscriptionBalanceResult {
            storefronts.append(storefrontCountry)
            throw BalanceUnavailable()
        }
    }

    @MainActor
    private final class IdleConfirmation: PurchaseConfirming {
        var onStateChanged: ((String) -> Void)?
        func start() {}
        func stop() {}
        func setForeground(_ foreground: Bool) {}
        func startPurchaseConfirmation() {}
    }

    private func viewModel(
        api: StorefrontRecordingApi,
        timeout: TimeInterval,
        lookup: @escaping () async -> String?
    ) -> SubscriptionBalanceViewModel {
        // isPro keeps the 30 s background poll (a real timer) out of the test
        SubscriptionBalanceViewModel(
            urApiService: api,
            isPro: true,
            refreshJwt: {},
            purchaseConfirmation: IdleConfirmation(),
            storefrontLookupTimeout: timeout,
            lookupStorefrontCountry: lookup
        )
    }

    @Test func aStorefrontThatNeverAnswersDoesNotHoldTheBalanceRead() async {
        let held = HeldAnswer()
        let api = StorefrontRecordingApi()
        let model = viewModel(api: api, timeout: 0, lookup: { await held.wait() })

        await model.fetchSubscriptionBalance()

        // the read went without the storefront, and ended: Enter is enabled
        #expect(api.storefronts == [nil])
        #expect(!model.isLoading)
        #expect(model.storefrontCountry == nil)
        held.give(nil)
    }

    @Test func aStorefrontThatAnswersWithinTheBoundGoesWithEveryRead() async {
        let api = StorefrontRecordingApi()
        var lookups = 0
        // far past any scheduling delay: only the answer ends this wait
        let model = viewModel(api: api, timeout: 3600, lookup: {
            lookups += 1
            return "DE"
        })

        await model.fetchSubscriptionBalance()
        await model.fetchSubscriptionBalance()

        #expect(api.storefronts == ["DE", "DE"])
        #expect(model.storefrontCountry == "DE")
        // read once from StoreKit
        #expect(lookups == 1)
    }

    @Test func anUnansweredWaitEndsAtItsBoundAndALaterWaitGetsTheAnswer() async {
        let held = HeldAnswer()
        let lookup = Task { await held.wait() }

        let early = await taskValue(lookup, within: 0)
        #expect(early == nil)

        held.give("DE")
        let late = await taskValue(lookup, within: 3600)
        #expect(late == "DE")
    }
}
