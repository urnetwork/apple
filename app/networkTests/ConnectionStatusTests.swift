//
//  ConnectionStatusTests.swift
//  networkTests
//
//  The connect view controller's status strings, as ConnectViewModel reads
//  them (ConnectionStatus(rawValue:)). CONNECT_FAILED (the connect window
//  passed both of its outcome deadlines with no provider added) had no
//  ConnectionStatus, so updateConnectionStatus dropped it: the connect view
//  kept its last status and said "Connecting to providers" while nothing
//  could be reached.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

struct ConnectionStatusTests {

    // every status the sdk's ConnectViewController reports (sdk
    // connect_view_controller.go ConnectionStatus)
    private static let sdkStatuses = [
        SdkDisconnected,
        SdkConnecting,
        SdkDestinationSet,
        SdkConnected,
        SdkConnectFailed,
    ]

    @Test func everySdkStatusIsMapped() {
        for value in Self.sdkStatuses {
            #expect(ConnectionStatus(rawValue: value)?.rawValue == value, "\(value) is dropped")
        }
    }

    @Test func connectFailedIsNotReadAsAnotherStatus() {
        let status = ConnectionStatus(rawValue: SdkConnectFailed)
        #expect(status != nil, "CONNECT_FAILED is dropped")
        for value in Self.sdkStatuses where value != SdkConnectFailed {
            #expect(status != ConnectionStatus(rawValue: value), "CONNECT_FAILED reads as \(value)")
        }
    }

    @Test func anUnknownStatusIsNotMapped() {
        #expect(ConnectionStatus(rawValue: "") == nil)
        #expect(ConnectionStatus(rawValue: "FAILED") == nil)
        #expect(ConnectionStatus(rawValue: "CONNECT FAILED") == nil)
    }
}
