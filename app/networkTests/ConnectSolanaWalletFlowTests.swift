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
import URnetworkSdk
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
        #expect(flow.manualSupportingText == "There was an error connecting your wallet.")

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

    // MARK: returns after an error, payout reads that fail

    @Test func aWalletReturnAfterItsErrorStillLinks() async {
        let client = FakeUsdcWalletsClient()
        let flow = Self.flow(client)
        var connected: [String] = []
        flow.openWallet = { _ in true }
        flow.onConnected = { connected.append($0) }

        // the ur.io bridge reports the rejected first approval, then its
        // Try again returns the key for the same hand-off
        flow.start(.phantom)
        flow.handleWalletError(WalletDeepLinkError.walletError("User rejected the request."))
        #expect(flow.stage == .failed("There was an error connecting your wallet: User rejected the request."))
        await flow.handleWalletReturn(publicKey: Self.address, provider: .phantom)

        #expect(client.calls == [.add(Self.address), .payoutWalletId])
        #expect(connected == ["wallet-new"])

        // a failed manual link is not a wallet hand-off: a wallet return is ignored
        let manualClient = FakeUsdcWalletsClient()
        manualClient.addError = UsdcWalletsClientError.message("invalid wallet address")
        let manual = Self.flow(manualClient)
        manual.enterManually()
        manual.manualAddress = Self.address
        await manual.validationTask?.value
        await manual.submitManualAddress()
        manualClient.addError = nil
        await manual.handleWalletReturn(publicKey: Self.address, provider: .phantom)
        #expect(manualClient.calls == [.validate(Self.address), .add(Self.address)])
        #expect(manual.stage == .failed("There was an error connecting your wallet: invalid wallet address"))
    }

    @Test func aPayoutReadThatFailsStillSelectsTheWallet() async {
        let client = FakeUsdcWalletsClient()
        client.payoutId = "wallet-old"
        client.payoutIdError = UsdcWalletsClientError.message("offline")
        let flow = Self.flow(client)
        var connected: [String] = []
        flow.openWallet = { _ in true }
        flow.onConnected = { connected.append($0) }

        flow.start(.phantom)
        await flow.handleWalletReturn(publicKey: Self.address, provider: .phantom)

        #expect(client.calls == [.add(Self.address), .payoutWalletId, .setPayoutWallet("wallet-new")])
        #expect(client.payoutId == "wallet-new")
        #expect(connected == ["wallet-new"])
    }

    // MARK: failure wording

    /// The stage a wallet hand-back carrying `errorCode` and `errorMessage`
    /// leaves the flow in, through the wallet provider's deep link handling.
    private static func failedStage(host: String, errorCode: String, errorMessage: String) -> ConnectSolanaWalletFlow.Stage {
        let provider = ConnectWalletProviderViewModel()
        let flow = Self.flow(FakeUsdcWalletsClient())
        flow.openWallet = { _ in true }
        flow.start(host.hasPrefix("solflare") ? .solflare : .phantom)
        var components = URLComponents(string: "urnetwork://\(host)")!
        components.queryItems = [
            URLQueryItem(name: "errorCode", value: errorCode),
            URLQueryItem(name: "errorMessage", value: errorMessage),
        ]
        provider.handleDeepLink(
            components.url!,
            onPublicKeyRetrieved: { _, _ in
                Issue.record("a failed connect carries no key")
            },
            onError: { error in
                flow.handleWalletError(error)
            }
        )
        return flow.stage
    }

    // Phantom and Solflare decline with 4001 (their apps on iOS): the app's
    // own words, not the wallet's English
    @Test func aDeclinedConnectReadsInTheAppsWords() {
        #expect(Self.failedStage(host: "solflare-connect", errorCode: "4001", errorMessage: "User rejected the request.")
            == .failed("There was an error connecting your wallet: The request was declined in your wallet. Start again and approve it to continue."))
    }

    // the ur.io bridge (macOS) hands a failure back with its code (sdk
    // SolanaWalletBridgeError*) and its English text: a code this app knows
    // reads in its own words, with the wallet's name where the text has one
    @Test func theBridgePagesCodesReadInTheAppsWords() {
        let english = "The page's English text."
        // (a missing extension has a stage of its own: aMissingExtensionOffersManualEntry)
        let cases: [(host: String, code: String, detail: String)] = [
            ("solflare-connect", SdkSolanaWalletBridgeErrorNoAccount, "Your Solflare wallet has no account to sign with. Add or connect an account in the wallet, then try again."),
            ("phantom-connect", SdkSolanaWalletBridgeErrorUserRejected, "The request was declined in your wallet. Start again and approve it to continue."),
            ("phantom-connect", SdkSolanaWalletBridgeErrorSessionNotFound, "The wallet connection wasn't found in this browser. Start again to reconnect your wallet."),
        ]
        for c in cases {
            #expect(Self.failedStage(host: c.host, errorCode: c.code, errorMessage: english)
                == .failed("There was an error connecting your wallet: \(c.detail)"), "\(c.host) \(c.code)")
        }
        // the page's other failures, a code this app does not know, and a page
        // before the codes: the page's text
        for code in [SdkSolanaWalletBridgeErrorInvalidRequest, SdkSolanaWalletBridgeErrorWallet, "wallet_locked", "-1"] {
            #expect(Self.failedStage(host: "phantom-connect", errorCode: code, errorMessage: english)
                == .failed("There was an error connecting your wallet: \(english)"), "\(code)")
        }
    }

    // MARK: no extension of the wallet (macOS)

    // Reported defect (android, the same flow): a wallet the app cannot hand
    // off to was answered only with "install a wallet", although the sheet's
    // manual entry takes any wallet's address. The bridge's missing extension
    // is a stage of its own that offers it.
    @Test func aMissingExtensionOffersManualEntry() {
        let english = "Phantom wasn't detected in this browser. Install the Phantom extension, then try again."
        #expect(Self.failedStage(host: "phantom-connect", errorCode: SdkSolanaWalletBridgeErrorExtensionNotFound, errorMessage: english)
            == .extensionNotFound(.phantom))
        #expect(Self.failedStage(host: "solflare-connect", errorCode: SdkSolanaWalletBridgeErrorExtensionNotFound, errorMessage: english)
            == .extensionNotFound(.solflare))
    }

    @Test func theMissingExtensionLineNamesTheWalletAndManualEntry() {
        #expect(ConnectSolanaWalletFlow.extensionNotFoundMessage(for: .phantom)
            == String(localized: "The \("Phantom") extension was not found in this browser. Install it and try again, or choose “Enter address manually” to paste your wallet address."))
        #expect(ConnectSolanaWalletFlow.extensionNotFoundMessage(for: .solflare)
            == String(localized: "The \("Solflare") extension was not found in this browser. Install it and try again, or choose “Enter address manually” to paste your wallet address."))
        // the shared words, which signing in keeps, do not change
        #expect(SolanaWalletReturnError.text(code: SdkSolanaWalletBridgeErrorExtensionNotFound, provider: .phantom)
            == String(localized: "The \("Phantom") extension was not found in this browser. Install it, then try again."))
    }

    @Test func enterManuallyAfterAMissingExtensionOpensTheAddressField() async {
        let client = FakeUsdcWalletsClient()
        let flow = Self.flow(client)
        var connected: [String] = []
        flow.openWallet = { _ in true }
        flow.onConnected = { connected.append($0) }

        flow.start(.phantom)
        flow.handleWalletError(WalletDeepLinkError.extensionNotFound("no extension"))
        #expect(flow.stage == .extensionNotFound(.phantom))

        flow.enterManually()
        #expect(flow.stage == .manualEntry)
        flow.manualAddress = Self.address
        await flow.validationTask?.value
        await flow.submitManualAddress()

        #expect(client.calls == [.validate(Self.address), .add(Self.address), .payoutWalletId])
        #expect(connected == ["wallet-new"])
    }

    @Test func retryAfterAMissingExtensionReopensTheSameWallet() async {
        let flow = Self.flow(FakeUsdcWalletsClient())
        var opened: [ConnectSolanaWalletFlow.WalletApp] = []
        flow.openWallet = { app in
            opened.append(app)
            return true
        }

        flow.start(.solflare)
        flow.handleWalletError(WalletDeepLinkError.extensionNotFound("no extension"))
        await flow.retry()

        #expect(opened == [.solflare, .solflare])
        #expect(flow.stage == .awaitingWallet(.solflare))
    }

    // the bridge page's Try again, once the extension is installed, returns a
    // key for the same hand-off
    @Test func aKeyAfterAMissingExtensionStillLinks() async {
        let client = FakeUsdcWalletsClient()
        let flow = Self.flow(client)
        var connected: [String] = []
        flow.openWallet = { _ in true }
        flow.onConnected = { connected.append($0) }

        flow.start(.phantom)
        flow.handleWalletError(WalletDeepLinkError.extensionNotFound("no extension"))
        await flow.handleWalletReturn(publicKey: Self.address, provider: .phantom)

        #expect(client.calls == [.add(Self.address), .payoutWalletId])
        #expect(connected == ["wallet-new"])
    }

    @Test func otherWalletErrorsStillFail() {
        let flow = Self.flow(FakeUsdcWalletsClient())
        flow.openWallet = { _ in true }

        flow.start(.phantom)
        flow.handleWalletError(WalletDeepLinkError.walletError("The request was declined in your wallet. Start again and approve it to continue."))

        #expect(flow.stage == .failed("There was an error connecting your wallet: The request was declined in your wallet. Start again and approve it to continue."))
    }

    // the sign step's refusal comes back the same way (the bridge on macOS)
    @Test func aSignatureRefusalCarriesTheAppsWordsToo() {
        let provider = ConnectWalletProviderViewModel()
        var errors: [Error] = []
        for (code, message) in [(SdkSolanaWalletBridgeErrorSessionNotFound, "No wallet session found. Please connect first."), ("wallet_locked", "The wallet is locked.")] {
            var components = URLComponents(string: "urnetwork://phantom-sign-message")!
            components.queryItems = [URLQueryItem(name: "errorCode", value: code), URLQueryItem(name: "errorMessage", value: message)]
            provider.handleDeepLink(
                components.url!,
                onSignature: { _ in
                    Issue.record("a refused signature carries no signature")
                },
                onError: { error in
                    errors.append(error)
                }
            )
        }
        #expect(errors.count == 2)
        if case WalletDeepLinkError.walletError(let text)? = errors.first {
            #expect(text == "The wallet connection wasn't found in this browser. Start again to reconnect your wallet.")
        } else {
            Issue.record("session_not_found: \(String(describing: errors.first))")
        }
        // a code this app does not know keeps the wallet's own text
        #expect(errors.last?.localizedDescription == "Wallet signing error: The wallet is locked.")
    }

    @Test func eachCodeHasItsText() {
        #expect(SolanaWalletReturnError.text(code: SdkSolanaWalletBridgeErrorExtensionNotFound, provider: .phantom)
            == String(localized: "The \("Phantom") extension was not found in this browser. Install it, then try again."))
        #expect(SolanaWalletReturnError.text(code: SdkSolanaWalletBridgeErrorNoAccount, provider: .phantom)
            == String(localized: "Your \("Phantom") wallet has no account to sign with. Add or connect an account in the wallet, then try again."))
        #expect(SolanaWalletReturnError.text(code: SdkSolanaWalletBridgeErrorSessionNotFound, provider: .solflare)
            == String(localized: "The wallet connection wasn't found in this browser. Start again to reconnect your wallet."))
        for code in [SdkSolanaWalletBridgeErrorUserRejected, SolanaWalletReturnError.walletUserRejectedCode] {
            #expect(SolanaWalletReturnError.text(code: code, provider: .solflare)
                == String(localized: "The request was declined in your wallet. Start again and approve it to continue."))
        }
        for code in [SdkSolanaWalletBridgeErrorInvalidRequest, SdkSolanaWalletBridgeErrorWallet, "-1", "-32603", ""] {
            #expect(SolanaWalletReturnError.text(code: code, provider: .phantom) == nil, "\(code)")
        }
    }

    // …/apple/app/networkTests/ConnectSolanaWalletFlowTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func theWalletReturnTextsAreTranslatedInEveryLocale() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        var locales = Set<String>()
        for case let entry as [String: Any] in strings.values {
            if let localizations = entry["localizations"] as? [String: Any] {
                locales.formUnion(localizations.keys)
            }
        }
        #expect(locales.contains("zh-Hans"))
        for key in [
            "The %@ extension was not found in this browser. Install it, then try again.",
            "Your %@ wallet has no account to sign with. Add or connect an account in the wallet, then try again.",
            "The request was declined in your wallet. Start again and approve it to continue.",
            "The wallet connection wasn't found in this browser. Start again to reconnect your wallet.",
        ] {
            let entry = try #require(strings[key] as? [String: Any], "the catalog has no \(key)")
            #expect(entry["extractionState"] as? String != "stale")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            var missing: [String] = []
            for locale in locales.sorted() {
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                guard let value = unit?["value"] as? String, !value.isEmpty else {
                    missing.append(locale)
                    continue
                }
                if locale != "en" {
                    #expect(value != key, "\(locale) is English: \(key)")
                }
                #expect(value.contains("%@") == key.contains("%@"), "\(locale): \(value)")
            }
            #expect(missing.isEmpty, "not translated: \(missing) in \(key)")
        }
    }

    @Test func failuresWithoutAServerMessageReadAsTheSentenceAlone() {
        let noDetail = "There was an error connecting your wallet."
        // the client's own stand-ins, and the SDK's request timeout
        #expect(ConnectSolanaWalletFlow.errorMessage(for: UsdcWalletsClientError.emptyResult) == noDetail)
        #expect(ConnectSolanaWalletFlow.errorMessage(for: UsdcWalletsClientError.sdkUnavailable) == noDetail)
        let timeout = NSError(domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timeout."])
        #expect(ConnectSolanaWalletFlow.errorMessage(for: timeout) == noDetail)
        // a server or library message is the detail
        let refused = NSError(domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: "500 Internal Server Error: invalid wallet address"])
        #expect(ConnectSolanaWalletFlow.errorMessage(for: refused) == "There was an error connecting your wallet: 500 Internal Server Error: invalid wallet address")
        #expect(ConnectSolanaWalletFlow.errorMessage(for: UsdcWalletsClientError.message("wallet not found")) == "There was an error connecting your wallet: wallet not found")
    }

    @Test func aPayoutSwitchThatTimesOutReadsAsTheSentenceAlone() async {
        let client = FakeUsdcWalletsClient()
        client.payoutId = "wallet-old"
        client.setPayoutError = NSError(domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timeout."])
        let flow = Self.flow(client)
        flow.openWallet = { _ in true }

        flow.start(.phantom)
        await flow.handleWalletReturn(publicKey: Self.address, provider: .phantom)

        #expect(client.calls == [.add(Self.address), .payoutWalletId, .setPayoutWallet("wallet-new")])
        #expect(flow.stage == .failed("There was an error connecting your wallet."))
    }
}
