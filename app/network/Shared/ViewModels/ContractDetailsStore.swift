//
//  ContractDetailsStore.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/8/26.
//

import Foundation
import SwiftUI
import URnetworkSdk

/**
 * One contract, un-aggregated: its own used/total byte counts and bit rate.
 * Contracts are never paired -- the send and receive contracts of a peer are
 * fundamentally many-to-many, so each is presented on its own.
 */
struct ContractEntry: Identifiable, Equatable {
    /**
     * the contract id: the stable identity a circle keeps for its whole
     * insert/slide-off lifecycle
     */
    let id: String
    var usedByteCount: Int64 = 0
    var totalByteCount: Int64 = 0
    var bitRate: Int = 0
    // a stream contract (its transfer path carries a stream id) — drawn as a
    // double concentric outer ring so streams are visually distinct
    var hasStream: Bool = false

    var isActive: Bool {
        0 < bitRate
    }
}

/**
 * One peer client's open contracts, as two independent stacks: contracts
 * sending to the peer and contracts receiving from it, each newest first.
 */
struct ContractPeerRow: Identifiable, Equatable {
    let clientId: String

    // newest first
    var send: [ContractEntry] = []
    var receive: [ContractEntry] = []

    // cumulative bytes moved to / from this peer in the current run (accumulated
    // across the peer's contracts, reset when it goes idle), for the stack headers
    var sendByteCount: Int64 = 0
    var receiveByteCount: Int64 = 0

    // unix-millis of this peer's last byte movement (any contract with a
    // positive bit rate), or 0 if it has not moved bytes since appearing. The
    // list floats rows with recent activity above idle ones; freshness is judged
    // against the device clock (the SDK view controller runs in-app).
    var lastActivityMillis: Int64 = 0

    // the peer's last contract closed and the row is being ejected: it is kept
    // briefly (by the SDK view controller, with empty stacks) so the circles
    // can slide off, then removed
    var closing: Bool = false

    var id: String { clientId }
}

enum ContractDetailsMode {
    /**
     * contracts for this device's own traffic
     */
    case client
    /**
     * contracts for traffic relayed for remote clients
     */
    case provider
}

private class ContractRowsListener: NSObject, SdkContractRowsListenerProtocol {
    private let callback: () -> Void
    init(callback: @escaping () -> Void) {
        self.callback = callback
    }
    func contractRowsChanged() {
        callback()
    }
}

/**
 * Publishes the live, per-contract rows for the mode's traffic. The grouping
 * (per-peer send/receive stacks, newest first, stable order) and the closing
 * lifecycle are done by the SDK ContractDetailsViewController, shared by every
 * platform; this store just maps its rows onto the UI types.
 */
@MainActor
class ContractDetailsStore: ObservableObject {

    let mode: ContractDetailsMode

    @Published private(set) var rows: [ContractPeerRow] = []

    // the shared view controller's "N new" pending count for this feed: rows that
    // arrived while scrolled away from the top and are not yet merged
    @Published private(set) var pendingCount: Int = 0

    private var device: SdkDeviceRemote?
    private var viewController: SdkContractDetailsViewController?
    private var rowsSub: SdkSubProtocol?

    init(mode: ContractDetailsMode) {
        self.mode = mode
    }

    func setup(_ device: SdkDeviceRemote) {
        reset()

        self.device = device
        // client and provider lists are two instances of the same single-feed
        // controller; open the one for this store's feed
        let vc = mode == .client
            ? device.openClientContractDetailsViewController()
            : device.openProviderContractDetailsViewController()
        self.viewController = vc
        self.rowsSub = vc?.add(ContractRowsListener { [weak self] in
            DispatchQueue.main.async {
                self?.update()
            }
        })
        vc?.start()
        update()
    }

    func reset() {
        rowsSub?.close()
        rowsSub = nil
        if let viewController {
            if let device {
                device.close(viewController)
            } else {
                viewController.close()
            }
        }
        viewController = nil
        device = nil
        rows = []
        pendingCount = 0
    }

    /// Report whether this feed's list is scrolled to the very top. The shared
    /// view controller owns the ordering: at the top it re-sorts active rows
    /// above idle ones; scrolled away it freezes membership+order and collects
    /// new rows into `pendingCount`.
    func setAtTop(_ atTop: Bool) {
        viewController?.setAtTop(atTop)
    }

    private static func entries(_ list: SdkContractEntryList?) -> [ContractEntry] {
        guard let list = list else {
            return []
        }
        var entries: [ContractEntry] = []
        for i in 0..<list.len() {
            guard let e = list.get(i) else {
                continue
            }
            entries.append(
                ContractEntry(
                    id: e.contractId,
                    usedByteCount: e.usedByteCount,
                    totalByteCount: e.totalByteCount,
                    bitRate: Int(e.bitRate),
                    hasStream: e.hasStream
                )
            )
        }
        return entries
    }

    private func update() {
        guard let vc = self.viewController else {
            return
        }
        let list: SdkContractPeerRowList? = vc.getContractRows()
        let pending = vc.pendingCount()

        var newRows: [ContractPeerRow] = []
        if let list = list {
            for i in 0..<list.len() {
                guard let r = list.get(i) else {
                    continue
                }
                newRows.append(
                    ContractPeerRow(
                        clientId: r.clientId,
                        send: Self.entries(r.sendContracts),
                        receive: Self.entries(r.receiveContracts),
                        sendByteCount: r.sendByteCount,
                        receiveByteCount: r.receiveByteCount,
                        lastActivityMillis: r.lastActivityMillis,
                        closing: r.closing
                    )
                )
            }
        }

        // the view controller owns the ordering; animate the reorder/merge it
        // hands us (each contract circle's own animation stays internal to the row)
        if newRows != rows {
            withAnimation(.easeInOut(duration: 0.35)) {
                rows = newRows
            }
        }
        if Int(pending) != pendingCount {
            pendingCount = Int(pending)
        }
    }
}
