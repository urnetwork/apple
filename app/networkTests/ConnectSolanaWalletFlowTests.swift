//
//  ConnectSolanaWalletFlowTests.swift
//  networkTests
//
//  The Solana wallet connect flow: the hand-off to Phantom or Solflare and the
//  wallet's return, the manual address and its Solana check, linking (which
//  makes the wallet the payout wallet), the errors, retry and reset. The
//  encrypted connect envelope needs real wallet keys and is not covered here.
//

import Foundation
import Testing
@testable import URnetwork

/// Holds a scripted address check open until the test releases it.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// Records the address checks the SDK client asks the API service for.
private final class RecordingUrApiService: MockUrApiService {
    private(set) var validated: [(address: String, chain: String)] = []

    override func validateWalletAddress(address: String, chain: String) async throws -> Bool {
        validated.append((address, chain))
        return true
    }
}

@MainActor
struct ConnectSolanaWalletFlowTests {

    private static let address = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU"

    private static func flow(_ client: FakeUsdcWalletsClient) -> ConnectSolanaWalletFlow {
        ConnectSolanaWalletFlow(client: client, validationDebounce: .zero)
    }

    // MARK: wallet app

    @Test func startOpensTheWalletAndWaits() {
        let client = FakeUsdcWalletsClient()
        let flow = Self.flow(client)
        var opened: [ConnectSolanaWalletFlow.WalletApp] = []
        flow.openWallet = { app in
            opened.append(app)
            return true
        }

        #expect(flow.start(.phantom))
        #expect(opened == [.phantom])
        #expect(flow.stage == .awaitingWallet(.phantom))
        #expect(client.calls.isEmpty)
    }

    @Test func aWalletThatDoesNotOpenStaysOnTheChooser() {
        let flow = Self.flow(FakeUsdcWalletsClient())
        flow.openWallet = { _ in false }

        #expect(!flow.start(.solflare))
        #expect(flow.stage == .chooser)
    }

    @Test func theWalletReturnLinksASolanaWallet() async {
        let client = FakeUsdcWalletsClient()
        let flow = Self.flow(client)
        var connected: [String] = []
        flow.openWallet = { _ in true }
        flow.onConnected = { connected.append($0) }

        flow.start(.phantom)
        await flow.handleWalletReturn(publicKey: Self.address, provider: .phantom)

        // no payout wallet before: the server selected the new wallet itself,
        // and the wallet's key needs no separate address check
        #expect(client.calls == [.add(Self.address), .payoutWalletId])
        #expect(connected == ["wallet-new"])
    }

    @Test func linkingMakesTheWalletThePayoutWalletWhenAnotherIsSelected() async {
        let client = FakeUsdcWalletsClient()
        client.payoutId = "wallet-old"
        let flow = Self.flow(client)
        var callsWhenConnected: [FakeUsdcWalletsClient.Call] = []
        flow.openWallet = { _ in true }
        flow.onConnected = { _ in
            callsWhenConnected = client.calls
        }

        flow.start(.solflare)
        await flow.handleWalletReturn(publicKey: Self.address, provider: .solflare)

        #expect(callsWhenConnected == [.add(Self.address), .payoutWalletId, .setPayoutWallet("wallet-new")])
        #expect(client.payoutId == "wallet-new")
    }

    @Test func aReturnWhileNotWaitingIsIgnored() async {
        let client = FakeUsdcWalletsClient()
        let flow = Self.flow(client)

        await flow.handleWalletReturn(publicKey: Self.address, provider: .phantom)
        #expect(flow.stage == .chooser)

        flow.enterManually()
        await flow.handleWalletReturn(publicKey: Self.address, provider: .solflare)
        #expect(flow.stage == .manualEntry)

        #expect(client.calls.isEmpty)
    }

    @Test func aBittensorReturnIsIgnored() async {
        let client = FakeUsdcWalletsClient()
        let flow = Self.flow(client)
        flow.openWallet = { _ in true }

        flow.start(.phantom)
        await flow.handleWalletReturn(
            publicKey: "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY",
            provider: .bittensor
        )

        #expect(flow.stage == .awaitingWallet(.phantom))
        #expect(client.calls.isEmpty)
    }

    @Test func aWalletErrorWhileWaitingFails() {
        let flow = Self.flow(FakeUsdcWalletsClient())
        flow.openWallet = { _ in true }
        // what the wallet provider reports for a callback carrying errorCode
        let rejected = NSError(
            domain: "ConnectWalletProviderViewModel",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Wallet connect error: User rejected the request."]
        )

        // not waiting for a wallet: ignored
        flow.handleWalletError(rejected)
        #expect(flow.stage == .chooser)

        flow.start(.phantom)
        flow.handleWalletError(rejected)
        #expect(flow.stage == .failed("There was an error connecting your wallet: User rejected the request."))

        // an error without a detail
        flow.start(.phantom)
        flow.handleWalletError(WalletDeepLinkError.missingParams)
        #expect(flow.stage == .failed("There was an error connecting your wallet."))
    }

    @Test func aFailedLinkReportsTheMessage() async {
        let client = FakeUsdcWalletsClient()
        client.addError = UsdcWalletsClientError.message("invalid wallet address")
        let flow = Self.flow(client)
        var connected: [String] = []
        flow.openWallet = { _ in true }
        flow.onConnected = { connected.append($0) }

        flow.start(.phantom)
        await flow.handleWalletReturn(publicKey: Self.address, provider: .phantom)
        #expect(flow.stage == .failed("There was an error connecting your wallet: invalid wallet address"))

        // selecting the payout wallet can fail too
        client.addError = nil
        client.payoutId = "wallet-old"
        client.setPayoutError = UsdcWalletsClientError.message("payout wallet not updated")
        flow.start(.phantom)
        await flow.handleWalletReturn(publicKey: Self.address, provider: .phantom)
        #expect(flow.stage == .failed("There was an error connecting your wallet: payout wallet not updated"))

        #expect(connected.isEmpty)
    }

    @Test func retryReopensTheSameWallet() async {
        let client = FakeUsdcWalletsClient()
        client.addError = UsdcWalletsClientError.message("invalid wallet address")
        let flow = Self.flow(client)
        var opened: [ConnectSolanaWalletFlow.WalletApp] = []
        flow.openWallet = { app in
            opened.append(app)
            return true
        }

        flow.start(.solflare)
        await flow.handleWalletReturn(publicKey: Self.address, provider: .solflare)
        #expect(flow.stage == .failed("There was an error connecting your wallet: invalid wallet address"))

        await flow.retry()
        #expect(opened == [.solflare, .solflare])
        #expect(flow.stage == .awaitingWallet(.solflare))
    }

    // MARK: manual entry

    @Test func manualEntryValidatesWithTheSolanaChain() async throws {
        let client = FakeUsdcWalletsClient()
        let flow = Self.flow(client)
        flow.enterManually()

        // a valid address, trimmed before the check
        flow.manualAddress = "  \(Self.address)\n"
        #expect(flow.manualValidation == .validating)
        #expect(flow.manualSupportingText == "Checking address…")
        await flow.validationTask?.value
        #expect(client.calls == [.validate(Self.address)])
        #expect(flow.manualValidation == .valid)
        #expect(flow.manualSupportingText == nil)

        // not a Solana address
        client.validate = { _ in false }
        flow.manualAddress = "0x52908400098527886E0F7030069857D2E4169EE7"
        await flow.validationTask?.value
        #expect(flow.manualValidation == .invalid)
        #expect(flow.manualSupportingText == "That is not a valid Solana address.")

        // the check itself fails
        client.validate = { _ in throw UsdcWalletsClientError.message("offline") }
        flow.manualAddress = "7xKX"
        await flow.validationTask?.value
        #expect(flow.manualValidation == .notChecked)
        #expect(flow.manualSupportingText == "There was an error connecting your wallet: offline")

        // empty: nothing to check
        flow.manualAddress = "   "
        #expect(flow.validationTask == nil)
        #expect(flow.manualValidation == .notChecked)
        #expect(flow.manualSupportingText == nil)
        #expect(client.calls.count == 3)

        // the SDK client checks on the Solana chain
        let api = RecordingUrApiService()
        let sdkClient = UsdcWalletsSdkClient(api: nil, urApiService: api)
        #expect(try await sdkClient.validateSolanaAddress(Self.address))
        #expect(api.validated.map { $0.address } == [Self.address])
        #expect(api.validated.map { $0.chain } == ["SOL"])
    }

    @Test func aChangeDuringTheCheckDiscardsTheStaleResult() async {
        let client = FakeUsdcWalletsClient()
        let gate = Gate()
        client.validate = { address in
            if address == "first" {
                await gate.wait()
                return true
            }
            return false
        }
        let flow = Self.flow(client)
        flow.enterManually()

        flow.manualAddress = "first"
        let firstCheck = flow.validationTask
        // let the first check reach the server
        for _ in 0..<100 where !client.calls.contains(.validate("first")) {
            await Task.yield()
        }
        #expect(client.calls == [.validate("first")])

        flow.manualAddress = "second"
        await flow.validationTask?.value
        gate.open()
        await firstCheck?.value

        #expect(client.calls == [.validate("first"), .validate("second")])
        #expect(flow.manualValidation == .invalid)
        #expect(flow.manualSupportingText == "That is not a valid Solana address.")
    }

    @Test func submitRequiresAValidAddress() async {
        let client = FakeUsdcWalletsClient()
        client.validate = { _ in false }
        let flow = Self.flow(client)
        flow.enterManually()
        flow.manualAddress = "not-an-address"

        // still being checked
        await flow.submitManualAddress()
        await flow.validationTask?.value
        // checked, and not a Solana address
        await flow.submitManualAddress()

        #expect(client.calls == [.validate("not-an-address")])
        #expect(flow.stage == .manualEntry)
    }

    @Test func submitLinksTheWallet() async {
        let client = FakeUsdcWalletsClient()
        let flow = Self.flow(client)
        var connected: [String] = []
        flow.onConnected = { connected.append($0) }
        flow.enterManually()
        flow.manualAddress = " \(Self.address) "
        await flow.validationTask?.value

        await flow.submitManualAddress()

        #expect(client.calls == [.validate(Self.address), .add(Self.address), .payoutWalletId])
        #expect(connected == ["wallet-new"])
    }

    @Test func retryAfterAManualFailureKeepsTheAddress() async {
        let client = FakeUsdcWalletsClient()
        client.addError = UsdcWalletsClientError.message("wallet already linked")
        let flow = Self.flow(client)
        var connected: [String] = []
        flow.onConnected = { connected.append($0) }
        flow.enterManually()
        flow.manualAddress = Self.address
        await flow.validationTask?.value

        await flow.submitManualAddress()
        #expect(flow.stage == .failed("There was an error connecting your wallet: wallet already linked"))

        await flow.retry()
        #expect(flow.stage == .manualEntry)
        #expect(flow.manualAddress == Self.address)
        #expect(flow.manualValidation == .valid)

        client.addError = nil
        await flow.submitManualAddress()
        #expect(connected == ["wallet-new"])
        // the kept address is not checked again
        #expect(client.calls.filter { $0 == .validate(Self.address) }.count == 1)
    }

    @Test func resetClearsEverything() async {
        let client = FakeUsdcWalletsClient()
        let flow = Self.flow(client)
        flow.openWallet = { _ in true }
        flow.enterManually()
        flow.manualAddress = Self.address
        let pendingCheck = flow.validationTask

        flow.reset()
        await pendingCheck?.value

        #expect(flow.stage == .chooser)
        #expect(flow.manualAddress == "")
        #expect(flow.manualValidation == .notChecked)
        #expect(flow.manualSupportingText == nil)
        #expect(flow.validationTask == nil)

        // nothing left to retry
        await flow.retry()
        #expect(flow.stage == .chooser)

        // a wallet that comes back after the reset is ignored
        await flow.handleWalletReturn(publicKey: Self.address, provider: .phantom)
        #expect(!client.calls.contains(.add(Self.address)))
    }
}
