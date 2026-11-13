//
//  EarningsWalletLinkTests.swift
//  networkTests
//
//  Which Earnings connect flow a wallet deep link reaches: each flow takes
//  only its own callbacks, and only while its sheet is up. A Phantom or
//  Solflare return reaches none: Earnings has no Solana wallet since USDC
//  payouts ended (2026-11-12).
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
        #expect(EarningsWalletLink.route(Self.bittensor, bittensorSheetUp: true) == .bittensor)
        #expect(EarningsWalletLink.route(Self.bittensorError, bittensorSheetUp: true) == .bittensor)
        // the sheet was dismissed
        #expect(EarningsWalletLink.route(Self.bittensor, bittensorSheetUp: false) == nil)
        #expect(EarningsWalletLink.route(Self.bittensorError, bittensorSheetUp: false) == nil)
        // not a connect callback
        #expect(EarningsWalletLink.route(Self.signIn, bittensorSheetUp: true, consentSheetUp: true) == nil)
        #expect(EarningsWalletLink.route(Self.widget, bittensorSheetUp: true, consentSheetUp: true) == nil)
    }

    // USDC payouts ended, and with them the Solana payout wallet sheet: a
    // Phantom or Solflare connect return is no Earnings flow's, whichever
    // sheet is up
    @Test func aSolanaLinkReachesNoEarningsSheet() {
        for url in [Self.phantom, Self.solflare] {
            #expect(EarningsWalletLink.route(url, bittensorSheetUp: true) == nil, "\(url)")
            #expect(EarningsWalletLink.route(url, bittensorSheetUp: false, consentSheetUp: true) == nil, "\(url)")
            #expect(EarningsWalletLink.route(url, bittensorSheetUp: false) == nil, "\(url)")
        }
    }

    // CS-7: the payout consent signs through the same bridge link, so its
    // hand-back reaches the consent sheet while that is up, and only then
    @Test func aBittensorLinkReachesTheConsentSheetWhileItIsUp() {
        #expect(EarningsWalletLink.route(Self.bittensor, bittensorSheetUp: false, consentSheetUp: true) == .consent)
        #expect(EarningsWalletLink.route(Self.bittensorError, bittensorSheetUp: false, consentSheetUp: true) == .consent)
        #expect(EarningsWalletLink.route(Self.bittensor, bittensorSheetUp: true, consentSheetUp: false) == .bittensor)
        // the consent sheet was dismissed
        #expect(EarningsWalletLink.route(Self.bittensor, bittensorSheetUp: false, consentSheetUp: false) == nil)
    }
}
