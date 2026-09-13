//
//  ExtenderStatusStore.swift
//  URnetwork
//

import Foundation
import SwiftUI
import URnetworkSdk

/**
 * The extender network status the drawer panel draws (EXTENDER.md K4, K5).
 *
 * The sdk publishes one coalesced `ExtenderStatus` per second through the
 * device, which on iOS reads through the rpc to the tunnel extension's space.
 * This store maps it onto a plain value so the panel re-renders only when
 * something it draws actually changed, and so the mapping is exercised by the
 * unit tests without a device.
 */

/// The gossip network's state as the panel draws it: the status dot's color
/// and the word beside it (K4).
enum ExtenderGossipDisplayState: String, CaseIterable {
    /// a member with at least one mesh peer, or a feed app with its stream up
    case connected
    /// a dial or a reconnect in progress
    case connecting
    /// nothing in progress: backoff, no candidates, or disabled
    case disconnected

    /// The sdk's `ExtenderStatus.gossipState`. An unknown or empty value reads
    /// as disconnected: a status that names no state is not a working one.
    static func of(gossipState: String) -> ExtenderGossipDisplayState {
        switch gossipState {
        case SdkExtenderGossipStateConnected:
            return .connected
        case SdkExtenderGossipStateConnecting:
            return .connecting
        default:
            return .disconnected
        }
    }

    var color: Color {
        switch self {
        case .connected:
            return .urGreen
        case .connecting:
            return .urLightYellow
        case .disconnected:
            return .urCoral
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .disconnected:
            return "Disconnected"
        }
    }
}

/// One frame of the extender panel: what it draws, and nothing else.
struct ExtenderStatusModel: Equatable {

    /// the colors of the extenders carrying at least one live connection right
    /// now, in the sdk's order — one hollow ring each (K4)
    let activeColorHexes: [String]
    /// the "N" of "N of M": addresses carrying a live connection
    let activeCount: Int
    /// the "M" of "N of M": every usable directory entry
    let reserveCount: Int
    let eventCountLastMinute: Int
    let gossipState: ExtenderGossipDisplayState

    static let empty = ExtenderStatusModel(
        activeColorHexes: [],
        activeCount: 0,
        reserveCount: 0,
        eventCountLastMinute: 0,
        gossipState: .disconnected
    )

    init(
        activeColorHexes: [String],
        activeCount: Int,
        reserveCount: Int,
        eventCountLastMinute: Int,
        gossipState: ExtenderGossipDisplayState
    ) {
        self.activeColorHexes = activeColorHexes
        self.activeCount = activeCount
        self.reserveCount = reserveCount
        self.eventCountLastMinute = eventCountLastMinute
        self.gossipState = gossipState
    }

    init(_ status: SdkExtenderStatus) {
        // the rings are the addresses actually carrying traffic, which is what
        // `InUse` counts; `ActiveCount` is the same set's size, but the colors
        // have to come from the rows
        var colorHexes: [String] = []
        if let extenders = status.extenders {
            for i in 0..<extenders.len() {
                guard let extender = extenders.get(i), 0 < extender.inUse else {
                    continue
                }
                colorHexes.append(extender.colorHex)
            }
        }
        self.init(
            activeColorHexes: colorHexes,
            activeCount: status.activeCount,
            reserveCount: status.reserveCount,
            eventCountLastMinute: status.eventCountLastMinute,
            gossipState: ExtenderGossipDisplayState.of(gossipState: status.gossipState)
        )
    }
}

private class ExtenderStatusChangeListener: NSObject, SdkExtenderStatusChangeListenerProtocol {
    private let callback: (SdkExtenderStatus?) -> Void
    init(callback: @escaping (SdkExtenderStatus?) -> Void) {
        self.callback = callback
    }
    func extenderStatusChanged(_ status: SdkExtenderStatus?) {
        callback(status)
    }
}

/**
 * Publishes the device's extender status. The subscription is the panel's own,
 * held here rather than on the connect view model so the once-a-second status
 * publish invalidates the panel alone and not the drawer's charts.
 */
@MainActor
class ExtenderStatusStore: ObservableObject {

    @Published private(set) var status: ExtenderStatusModel = .empty

    private var device: SdkDeviceRemote?
    private var statusSub: SdkSubProtocol?

    func setup(_ device: SdkDeviceRemote) {
        reset()

        self.device = device
        // `AddExtenderStatusChangeListener` binds as `add(_:)`: the selector
        // names the listener type, which swift strips
        self.statusSub = device.add(
            ExtenderStatusChangeListener { [weak self] status in
                guard let status else {
                    return
                }
                let model = ExtenderStatusModel(status)
                DispatchQueue.main.async {
                    self?.apply(model)
                }
            }
        )
        // the listener only reports changes; seed with what is already known
        if let status = device.getExtenderStatus() {
            apply(ExtenderStatusModel(status))
        }
    }

    func reset() {
        statusSub?.close()
        statusSub = nil
        device = nil
        status = .empty
    }

    private func apply(_ model: ExtenderStatusModel) {
        guard model != status else {
            return
        }
        status = model
    }
}
