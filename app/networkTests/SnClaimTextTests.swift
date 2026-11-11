//
//  SnClaimTextTests.swift
//  networkTests
//
//  The words a v1 SN25α claim reads as on Earnings (support inbox 8126): an
//  epoch's status in the history rows and the claim sheet, and the count
//  under the unclaimed total. The SDK reports an epoch the vault finalized
//  without a payout root as "not-finalized", which read "Pending" here; it
//  reads "No payout published" now. The count counts the claimable epochs,
//  so it says so instead of "finalized epochs".
//
//  Capture the flag (sn/CAPTURETHEFLAG.md §10): each settlement v2 pool's
//  name, "Pool 1" as before, "Provider pool" and "Capture the flag", and the
//  line naming the slot this device won, with its country in the strings'
//  language.
//
//  Reads the app's English and German strings, as the catalog builds them,
//  and drives the view model with canned claims; no device or chain.
//  SnClaimCatalogTests checks the catalog itself.
//

import Foundation
import Testing
@testable import URnetwork

@MainActor
struct SnClaimTextTests {

    /// The app's strings in one language, as the catalog builds them.
    private static func strings(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private static func claim(_ epoch: Int64, _ status: SnClaimStatus, _ amountRao: Int64) -> SnEpochClaimInfo {
        SnEpochClaimInfo(epoch: epoch, shareBps: 71, amountRao: amountRao, status: status, claimOpenBlock: 0, expiryBlock: 0, txHash: "")
    }

    @Test func aClaimableEpochReadsUnclaimed() throws {
        #expect(SnClaimText.status(.claimable, bundle: try Self.strings("en")) == "Unclaimed")
    }

    @Test func aClaimedEpochReadsClaimed() throws {
        #expect(SnClaimText.status(.claimed, bundle: try Self.strings("en")) == "Claimed")
    }

    @Test func anExpiredEpochReadsExpired() throws {
        #expect(SnClaimText.status(.expired, bundle: try Self.strings("en")) == "Expired")
    }

    @Test func anEpochTheVaultHasNotFinalizedReadsPending() throws {
        #expect(SnClaimText.status(.open, bundle: try Self.strings("en")) == "Pending")
    }

    @Test func anEpochFinalizedWithoutAPayoutReadsNoPayoutPublished() throws {
        #expect(SnClaimStatus(sdkStatus: "not-finalized") == .notFinalized)
        #expect(SnClaimText.status(.notFinalized, bundle: try Self.strings("en")) == "No payout published")
        #expect(SnClaimText.status(.notFinalized, bundle: try Self.strings("de")) == "Keine Auszahlung veröffentlicht")
    }

    @Test func aStatusThisBuildDoesNotKnowIsNotReadAsFinalizedWithoutAPayout() {
        #expect(SnClaimStatus(sdkStatus: "pending-review") == .open)
        #expect(SnClaimStatus(sdkStatus: "") == .open)
    }

    @Test func theCountUnderTheUnclaimedTotalSaysClaimableEpochs() throws {
        #expect(SnClaimText.claimableEpochs(2, bundle: try Self.strings("en")) == "Claimable epochs: 2")
        #expect(SnClaimText.claimableEpochs(2, bundle: try Self.strings("de")) == "Einlösbare Epochen: 2")
    }

    @Test func eachPoolIsNamedInTheAppsLanguage() throws {
        let en = try Self.strings("en")
        let de = try Self.strings("de")
        // before capture the flag, as it has read
        #expect(SnLedgerPoolName.pool(noId: 1).text(bundle: en) == "Pool 1")
        #expect(SnLedgerPoolName.providerPool.text(bundle: en) == "Provider pool")
        #expect(SnLedgerPoolName.captureTheFlag.text(bundle: en) == "Capture the flag")
        #expect(SnLedgerPoolName.providerPool.text(bundle: de) == "Anbieter-Pool")
        #expect(SnLedgerPoolName.captureTheFlag.text(bundle: de) == "Capture the Flag")
    }

    @Test func theWonLineNamesASlotOfTheCountryInTheStringsLanguage() throws {
        let provider = try #require(SnCtfWinInfo(role: "provider", country: "is"))
        let extender = try #require(SnCtfWinInfo(role: "extender", country: "la"))
        #expect(provider.text(locale: Locale(identifier: "en"), bundle: try Self.strings("en")) == "You won one of the Iceland provider slots")
        #expect(extender.text(locale: Locale(identifier: "en"), bundle: try Self.strings("en")) == "You won one of the Laos extender slots")
        #expect(provider.text(locale: Locale(identifier: "de"), bundle: try Self.strings("de")) == "Island: Du hast einen der Anbieter-Plätze gewonnen")
    }

    @Test func theCountIsTheClaimableEpochs() async throws {
        let client = EarningsPreviewClient(
            wallet: SnWalletInfo(coldkeySs58: "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY", clientId: "", setAtMillis: 0),
            claims: [
                Self.claim(6, .open, 0),
                Self.claim(5, .claimable, 3_241_000_000),
                Self.claim(4, .claimable, 2_905_500_000),
                Self.claim(3, .claimed, 2_640_000_000),
                Self.claim(2, .expired, 1_812_250_000),
                Self.claim(1, .notFinalized, 0),
            ]
        )
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refreshSubnet()
        // six epochs reported, two of them claimable
        #expect(viewModel.claims.count == 6)
        #expect(viewModel.claimableClaims.map(\.epoch) == [5, 4])
        #expect(SnClaimText.claimableEpochs(viewModel.claimableClaims.count, bundle: try Self.strings("en")) == "Claimable epochs: 2")
    }
}
