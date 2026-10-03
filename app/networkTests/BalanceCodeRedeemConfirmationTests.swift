//
//  BalanceCodeRedeemConfirmationTests.swift
//  networkTests
//
//  A balance code is data only: the server grants its transfer balance with
//  pro = false and the redeem answer has no Pro field. A credited redeem must
//  reach the UI as the data the code added (BalanceCodeRedeemedView), not as a
//  bare success the flows confirmed with "You're premium." and the Pro poll.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/// Answers every redeem with a credited transfer balance of `byteCount`.
private final class CreditingUrApiService: MockUrApiService {
    let byteCount: Int64

    init(byteCount: Int64) {
        self.byteCount = byteCount
    }

    override func redeemBalanceCode(_ code: String) async throws -> SdkRedeemBalanceCodeResult {
        let transferBalance = SdkRedeemBalanceCodeTransferBalance()
        transferBalance.balanceByteCount = byteCount
        let result = SdkRedeemBalanceCodeResult()
        result.transferBalance = transferBalance
        return result
    }
}

@MainActor
struct BalanceCodeRedeemConfirmationTests {

    private static let fiveGib: Int64 = 5 * 1024 * 1024 * 1024

    @Test func creditedRedeemReportsTheDataTheCodeAdded() async throws {
        let viewModel = RedeemBalanceCodeSheet.ViewModel(
            api: CreditingUrApiService(byteCount: Self.fiveGib)
        )
        viewModel.code = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

        let redeemed = try await viewModel.redeem().get()

        #expect(redeemed == RedeemedBalanceCode(addedByteCount: Self.fiveGib))
    }

    @Test func confirmationStatesTheDataAdded() {
        let message = BalanceCodeRedeemedView.dataAddedMessage(
            RedeemedBalanceCode(addedByteCount: Self.fiveGib)
        )

        #expect(message == String(localized: "\(formatBalanceBytes(Int(Self.fiveGib))) of data added to your balance."))
        #expect(message?.contains("5") == true)
    }

    @Test func confirmationWithoutAByteCountIsTheTitleAlone() {
        #expect(BalanceCodeRedeemedView.dataAddedMessage(RedeemedBalanceCode(addedByteCount: 0)) == nil)
    }
}
