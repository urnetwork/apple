//
//  FakeUsdcWalletsClient.swift
//  networkTests
//
//  A scripted UsdcWalletsClient shared by the Solana wallet suites. It records
//  every call and behaves like the server where that matters: linking a
//  wallet makes it the payout wallet when the network has none, and removing
//  the payout wallet drops the payout association.
//

import Foundation
@testable import URnetwork

@MainActor
final class FakeUsdcWalletsClient: UsdcWalletsClient {

    enum Call: Equatable {
        case validate(String)
        case add(String)
        case wallets
        case payoutWalletId
        case setPayoutWallet(String)
        case remove(String)
        case payments
    }

    private(set) var calls: [Call] = []

    var validate: (String) async throws -> Bool = { _ in true }
    var addedWalletId = "wallet-new"
    var addError: Error?
    var walletRows: [UsdcWalletInfo] = []
    var walletsError: Error?
    var payoutId: String?
    var payoutIdError: Error?
    var setPayoutError: Error?
    var removeError: Error?
    var paymentRows: [UsdcPaymentInfo] = []
    var paymentsError: Error?
    /// runs in payments() after the call is recorded, before it returns
    var beforePaymentsReturn: () async -> Void = {}

    func validateSolanaAddress(_ address: String) async throws -> Bool {
        calls.append(.validate(address))
        return try await validate(address)
    }

    func addSolanaWallet(address: String) async throws -> String {
        calls.append(.add(address))
        if let addError {
            throw addError
        }
        if payoutId == nil {
            payoutId = addedWalletId
        }
        return addedWalletId
    }

    func wallets() async throws -> [UsdcWalletInfo] {
        calls.append(.wallets)
        if let walletsError {
            throw walletsError
        }
        return walletRows
    }

    func payoutWalletId() async throws -> String? {
        calls.append(.payoutWalletId)
        if let payoutIdError {
            throw payoutIdError
        }
        return payoutId
    }

    func setPayoutWallet(id: String) async throws {
        calls.append(.setPayoutWallet(id))
        if let setPayoutError {
            throw setPayoutError
        }
        payoutId = id
    }

    func removeWallet(id: String) async throws {
        calls.append(.remove(id))
        if let removeError {
            throw removeError
        }
        walletRows.removeAll { $0.id == id }
        if payoutId == id {
            payoutId = nil
        }
    }

    func payments() async throws -> [UsdcPaymentInfo] {
        calls.append(.payments)
        await beforePaymentsReturn()
        if let paymentsError {
            throw paymentsError
        }
        return paymentRows
    }
}
