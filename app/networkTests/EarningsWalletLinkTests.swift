//
//  EarningsWalletLinkTests.swift
//  networkTests
//
//  Which Earnings connect flow a wallet deep link reaches: each flow takes
//  only its own callbacks, and only while its sheet is up.
//

import Foundation
import Testing
@testable import URnetwork

struct EarningsWalletLinkTests {

    private static let phantom = URL(string: "urnetwork://phantom-connect?errorCode=-1&errorMessage=Rejected")!
    private static let solflare = URL(string: "urnetwork://solflare-connect?nonce=n&data=d&solflare_encryption_public_key=k")!
    private static let bittensor = URL(string: "urnetwork://bittensor-sign-message?address=5F&signature=00")!
    private static let bittensorError = URL(string: "urnetwork://bittensor-sign-message?errorCode=-1&errorMessage=No%20wallet&purpose=connect")!
    private static let signIn = URL(string: "urnetwork://phantom-sign-message?nonce=n&data=d")!
    private static let widget = URL(string: "urnetwork://widgets/connect")!

    @Test func aWalletLinkReachesOnlyTheSheetItBelongsTo() {
        #expect(EarningsWalletLink.route(Self.phantom, solanaSheetUp: true, bittensorSheetUp: false) == .solana)
        #expect(EarningsWalletLink.route(Self.solflare, solanaSheetUp: true, bittensorSheetUp: false) == .solana)
        #expect(EarningsWalletLink.route(Self.bittensor, solanaSheetUp: false, bittensorSheetUp: true) == .bittensor)
        // the other flow's late callback
        #expect(EarningsWalletLink.route(Self.bittensorError, solanaSheetUp: true, bittensorSheetUp: false) == nil)
        #expect(EarningsWalletLink.route(Self.phantom, solanaSheetUp: false, bittensorSheetUp: true) == nil)
        // the sheet was dismissed
        #expect(EarningsWalletLink.route(Self.solflare, solanaSheetUp: false, bittensorSheetUp: false) == nil)
        // not a connect callback
        #expect(EarningsWalletLink.route(Self.signIn, solanaSheetUp: true, bittensorSheetUp: true) == nil)
        #expect(EarningsWalletLink.route(Self.widget, solanaSheetUp: true, bittensorSheetUp: true) == nil)
    }
}
