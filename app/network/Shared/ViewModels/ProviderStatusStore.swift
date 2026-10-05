//
//  ProviderStatusStore.swift
//  URnetwork
//
//  This device's provider status from the server (P008): the sdk
//  ProviderStatusViewController polls GET /network/provider-status about once
//  a minute while started. The controller runs in the app process (it reads
//  the server through the app's api), so its getters are local reads.
//

import Foundation
import SwiftUI
import URnetworkSdk

/// One read of the controller, taken on the main queue after it reports a
/// change. Everything about this device comes from one status object, so a
/// poll that lands between two getters cannot mix two answers.
struct ProviderStatusSnapshot: Equatable {
    var isLoaded: Bool = false
    var lastFetchError: String = ""
    /// whether this device is one of the network's provider clients in the
    /// last poll
    var hasStatus: Bool = false
    /// the reason code (ProviderStatusReason*) and its English text, "" without
    /// a status
    var reason: String = ""
    var reasonText: String = ""
    /// the appearances per minute, oldest first; nil without a histogram
    var appearancesPerMinute: [Int64]? = nil
    var numbers: [ProviderStatusNumber] = []
    var country: ProviderStatusCountry? = nil

    var presentation: ProviderStatusPresentation {
        providerStatusPresentation(
            isLoaded: isLoaded,
            lastFetchError: lastFetchError,
            hasStatus: hasStatus,
            appearancesPerMinute: appearancesPerMinute
        )
    }
}

/// The sdk controller as the store drives it. A protocol so the owner test can
/// stand in for the sdk.
protocol ProviderStatusControlling: AnyObject {
    func start()
    func stop()
    func addStatusListener(_ changed: @escaping () -> Void) -> SdkSubProtocol?
    func readSnapshot() -> ProviderStatusSnapshot
}

/// What opens and closes the controller: the device in the app.
protocol ProviderStatusControllerOwner: AnyObject {
    func openProviderStatusController() -> ProviderStatusControlling?
    func closeProviderStatusController(_ controller: ProviderStatusControlling)
}

/**
 * Publishes this device's provider status for the provider statistics.
 *
 * The controller opens the first time the demand chart shows (never while
 * providing is disabled, when the chart does not show), polls only while it
 * shows (`setVisible`), and closes with the typed close when the device goes
 * or the presentation suspends (`reset`). A stopped controller keeps its last
 * snapshot, so a chart that shows again has it at once while the next poll
 * runs.
 */
@MainActor
class ProviderStatusStore: ObservableObject {

    @Published private(set) var snapshot = ProviderStatusSnapshot()

    private var owner: ProviderStatusControllerOwner?
    private var controller: ProviderStatusControlling?
    private var statusSub: SdkSubProtocol?

    // true while the provider statistics show the demand chart
    private var visible = false

    func setup(_ device: SdkDeviceRemote) {
        setup(owner: device)
    }

    func setup(owner: ProviderStatusControllerOwner) {
        reset()

        self.owner = owner
        if visible {
            startController()
        }
    }

    func reset() {
        closeController()
        owner = nil
        snapshot = ProviderStatusSnapshot()
    }

    /**
     * The provider statistics report whether the demand chart shows: on
     * screen with providing enabled. The controller polls only while it does.
     */
    func setVisible(_ nextVisible: Bool) {
        guard visible != nextVisible else {
            return
        }
        visible = nextVisible
        if visible {
            startController()
        } else {
            controller?.stop()
        }
    }

    private func startController() {
        if controller == nil, let owner, let controller = owner.openProviderStatusController() {
            self.controller = controller
            statusSub = controller.addStatusListener { [weak self] in
                DispatchQueue.main.async {
                    self?.update()
                }
            }
        }
        controller?.start()
        update()
    }

    private func closeController() {
        // the listener goes first, so nothing reads a closed controller
        statusSub?.close()
        statusSub = nil
        if let controller {
            controller.stop()
            owner?.closeProviderStatusController(controller)
        }
        controller = nil
    }

    private func update() {
        guard let controller else {
            return
        }
        let snapshot = controller.readSnapshot()
        // the listener fires after every poll; publish only real changes
        if snapshot != self.snapshot {
            self.snapshot = snapshot
        }
    }
}

private class ProviderStatusListener: NSObject, SdkProviderStatusListenerProtocol {
    private let callback: () -> Void

    init(_ callback: @escaping () -> Void) {
        self.callback = callback
    }

    func providerStatusChanged() {
        callback()
    }
}

extension SdkProviderStatusViewController: ProviderStatusControlling {

    func addStatusListener(_ changed: @escaping () -> Void) -> SdkSubProtocol? {
        add(ProviderStatusListener(changed))
    }

    func readSnapshot() -> ProviderStatusSnapshot {
        let status = getProviderStatus()
        var snapshot = ProviderStatusSnapshot(
            isLoaded: getIsLoaded(),
            lastFetchError: getLastFetchError(),
            hasStatus: status != nil,
            reason: status?.reason ?? "",
            reasonText: status?.reasonText ?? ""
        )
        if let appearances = status?.appearances {
            var counts: [Int64] = []
            if let list = appearances.appearancesPerMinute {
                counts.reserveCapacity(list.len())
                for i in 0..<list.len() {
                    counts.append(list.get(i))
                }
            }
            snapshot.appearancesPerMinute = counts
        }
        if let ranking = status?.ranking {
            for i in 0..<ranking.len() {
                if let number = ranking.get(i) {
                    snapshot.numbers.append(ProviderStatusNumber(number))
                }
            }
        }
        if let country = status?.country {
            snapshot.country = ProviderStatusCountry(
                country: country.country,
                countryCode: country.countryCode
            )
        }
        return snapshot
    }
}

extension SdkDeviceRemote: ProviderStatusControllerOwner {

    func openProviderStatusController() -> ProviderStatusControlling? {
        openProviderStatusViewController()
    }

    func closeProviderStatusController(_ controller: ProviderStatusControlling) {
        // the typed close (closeProviderStatusViewController), which also ends
        // the manager's ownership of the controller
        if let viewController = controller as? SdkProviderStatusViewController {
            close(viewController)
        }
    }
}

extension ProviderStatusNumber {

    init(_ number: SdkProviderRankingNumber) {
        self.init(
            name: number.name,
            hasValue: number.hasValue,
            value: number.value,
            hasMinimum: number.hasMinimum,
            minimum: number.minimum,
            hasMaximum: number.hasMaximum,
            maximum: number.maximum,
            passes: number.passes,
            count: number.count,
            total: number.total
        )
    }
}
