//
//  BittensorWalletConnectorTests.swift
//  networkTests
//
//  The Bittensor wallet-connect adoption: wallet and transport selection per
//  platform, the refusal texts, the connector's manual and browser-bridge
//  paths against the real SDK session (fixed clock, scripted challenge, no
//  network), the Earnings flow on top of it, and the wallet provider no
//  longer claiming the bridge hand-back for itself.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

@MainActor
struct BittensorWalletConnectorTests {

    // well-known Substrate dev accounts (subkey //Alice, //Bob)
    static let alice = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"
    static let bob = "5FHneW46xGXgs5mUiveU4sbTyGBzmstUspZC92UhjJM694ty"
    static let message = "Sign in to URnetwork\nChallenge: q1w2e3r4t5y6u7i8o9p0\nTimestamp: 1757340000"
    static let signature = "0x" + String(repeating: "ab", count: 64)
    static let nowMillis: Int64 = 1_757_340_000_000
    static let walletConnectProjectId = "app-project"

    static func challengeResult(_ message: String = BittensorWalletConnectorTests.message) -> SdkAuthWalletChallengeResult {
        let result = SdkAuthWalletChallengeResult()
        result.messageTemplate = message
        result.expiresIn = 300
        return result
    }

    static func returnUrl(_ items: [String: String]) -> URL {
        var components = URLComponents(string: BittensorWallet.redirectLink)!
        components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    final class Recorder {
        var challengeArgs: [SdkAuthWalletChallengeArgs] = []
        var opened: [URL] = []
        var proofs: [BittensorWalletProofInfo] = []
        var nowMillis = BittensorWalletConnectorTests.nowMillis
    }

    static func connector(platform: String, recorder: Recorder) -> BittensorWalletConnector {
        let connector = BittensorWalletConnector(
            platform: platform,
            fetchChallenge: { args in
                recorder.challengeArgs.append(args)
                return challengeResult()
            },
            openUrl: { url in
                recorder.opened.append(url)
                return true
            },
            now: { recorder.nowMillis },
            walletConnectProjectId: Self.walletConnectProjectId
        )
        connector.onProof = { proof in
            recorder.proofs.append(proof)
        }
        return connector
    }

    // MARK: selection and texts

    @Test func talismanTaoComAndWalletConnectWithThePlatformTransport() {
        #expect(BittensorWallet.walletIds == ["talisman", "taocom", "walletconnect"])
        #expect(BittensorWallet.displayName("talisman") == "Talisman")
        #expect(BittensorWallet.displayName("taocom") == "TAO.com")
        #expect(BittensorWallet.displayName("walletconnect") == "WalletConnect")
        // WalletConnect pairs on the bridge page on both platforms
        #expect(BittensorWallet.transport("walletconnect", platform: SdkBittensorWalletPlatformIos) == SdkBittensorWalletTransportBrowserBridge)
        #expect(BittensorWallet.transport("walletconnect", platform: SdkBittensorWalletPlatformMacos) == SdkBittensorWalletTransportBrowserBridge)
        // no documented mobile deep link: Talisman and TAO.com are manual on iOS
        #expect(BittensorWallet.transport("talisman", platform: SdkBittensorWalletPlatformIos) == SdkBittensorWalletTransportManual)
        #expect(BittensorWallet.transport("taocom", platform: SdkBittensorWalletPlatformIos) == SdkBittensorWalletTransportManual)
        // macOS: the Talisman extension through the browser bridge
        #expect(BittensorWallet.transport("talisman", platform: SdkBittensorWalletPlatformMacos) == SdkBittensorWalletTransportBrowserBridge)
        #expect(BittensorWallet.transport("taocom", platform: SdkBittensorWalletPlatformMacos) == SdkBittensorWalletTransportManual)
        #if os(iOS)
        #expect(BittensorWallet.platform == SdkBittensorWalletPlatformIos)
        #else
        #expect(BittensorWallet.platform == SdkBittensorWalletPlatformMacos)
        #endif
    }

    @Test func outcomesSeparateRefusalsFromOtherFlowsAnswers() {
        let proof = BittensorWalletProofInfo(walletId: "talisman", purpose: "login", address: Self.alice, message: Self.message, signature: Self.signature)
        #expect(BittensorWallet.outcome(proof: proof, errorCode: "", errorMessage: "") == .proof(proof))
        for code in [SdkBittensorWalletErrorPurposeMismatch, SdkBittensorWalletErrorNotReturn, SdkBittensorWalletErrorNotAwaiting, SdkBittensorWalletErrorUnsupportedWallet] {
            #expect(BittensorWallet.outcome(proof: nil, errorCode: code, errorMessage: "") == .ignored)
        }
        #expect(BittensorWallet.outcome(proof: nil, errorCode: SdkBittensorWalletErrorExpired, errorMessage: "") == .failed(code: SdkBittensorWalletErrorExpired, walletMessage: ""))
    }

    @Test func refusalTexts() {
        #expect(BittensorWallet.errorText(code: SdkBittensorWalletErrorAddressMismatch, walletMessage: "") == String(localized: "The wallet that signed is not the address you entered."))
        #expect(BittensorWallet.errorText(code: SdkBittensorWalletErrorInvalidAddress, walletMessage: "") == String(localized: "That is not a valid Bittensor address."))
        #expect(BittensorWallet.errorText(code: SdkBittensorWalletErrorInvalidSignature, walletMessage: "") == String(localized: "That is not a valid signature. Paste the full 0x signature from your wallet."))
        #expect(BittensorWallet.errorText(code: SdkBittensorWalletErrorExpired, walletMessage: "") == String(localized: "This request expired. Start again to get a new message to sign."))
        #expect(BittensorWallet.errorText(code: SdkBittensorWalletErrorMessageMismatch, walletMessage: "") == String(localized: "The wallet signed a different request. Start again."))
        #expect(BittensorWallet.errorText(code: SdkBittensorWalletErrorWallet, walletMessage: "User rejected") == "User rejected")
        #expect(BittensorWallet.errorText(code: "something_new", walletMessage: "x") == String(localized: "There was an error connecting your wallet."))
    }

    // the bridge page hands a failure back with its code (sdk
    // BittensorWalletResult.BridgeErrorCode) and its English text: a code
    // this app knows reads in its own words, any other in the page's text
    @Test func refusalTextsForTheBridgePagesCodes() {
        let english = "The page's English text."
        let texts: [(String, String)] = [
            (SdkBittensorWalletBridgeErrorAddressNotInWallet, String(localized: "Your \("Talisman") wallet doesn't have the address you entered. Add or connect that account in the wallet, or enter an address it has.")),
            (SdkBittensorWalletBridgeErrorAddressMismatch, String(localized: "The wallet that signed is not the address you entered.")),
            (SdkBittensorWalletBridgeErrorExtensionNotFound, String(localized: "The \("Talisman") extension was not found in this browser. Install it, then try again.")),
            (SdkBittensorWalletBridgeErrorNoAccount, String(localized: "Your \("Talisman") wallet has no account to sign with. Add or connect an account in the wallet, then try again.")),
            (SdkBittensorWalletBridgeErrorUserRejected, String(localized: "The request was declined in your wallet. Start again and approve it to continue.")),
            (SdkBittensorWalletBridgeErrorWalletConnectExpired, String(localized: "The WalletConnect request expired before the wallet answered. Start again.")),
            (SdkBittensorWalletBridgeErrorWalletConnectUnavailable, String(localized: "WalletConnect is not available right now. Try again later, or enter your address manually.")),
        ]
        for (bridgeCode, text) in texts {
            #expect(BittensorWallet.errorText(code: SdkBittensorWalletErrorWallet, walletMessage: english, bridgeCode: bridgeCode, walletId: SdkBittensorWalletTalisman) == text, "\(bridgeCode)")
            #expect(!text.contains(english))
        }
        #expect(texts.first?.1.contains("Talisman") == true)
        // a code this app does not know, the page's other failures, and a page before the codes
        for bridgeCode in ["wallet_locked", SdkBittensorWalletBridgeErrorWallet, SdkBittensorWalletBridgeErrorInvalidRequest, ""] {
            #expect(BittensorWallet.errorText(code: SdkBittensorWalletErrorWallet, walletMessage: english, bridgeCode: bridgeCode, walletId: SdkBittensorWalletTalisman) == english, "\(bridgeCode)")
        }
        // the session's own refusals keep their own message
        #expect(BittensorWallet.errorText(code: SdkBittensorWalletErrorExpired, walletMessage: "", bridgeCode: SdkBittensorWalletBridgeErrorUserRejected) == String(localized: "This request expired. Start again to get a new message to sign."))
        #expect(BittensorWallet.outcome(proof: nil, errorCode: SdkBittensorWalletErrorWallet, errorMessage: english, bridgeErrorCode: SdkBittensorWalletBridgeErrorUserRejected) == .failed(code: SdkBittensorWalletErrorWallet, walletMessage: english, bridgeCode: SdkBittensorWalletBridgeErrorUserRejected))
    }

    // …/apple/app/networkTests/BittensorWalletConnectorTests.swift -> …/apple/app
    static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func theBridgeTextsAreTranslatedInEveryLocale() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        // every locale the catalog ships a translation for
        var locales = Set<String>()
        for case let entry as [String: Any] in strings.values {
            if let localizations = entry["localizations"] as? [String: Any] {
                locales.formUnion(localizations.keys)
            }
        }
        #expect(locales.contains("zh-Hans"))
        for key in [
            "Your %@ wallet doesn't have the address you entered. Add or connect that account in the wallet, or enter an address it has.",
            "The %@ extension was not found in this browser. Install it, then try again.",
            "Your %@ wallet has no account to sign with. Add or connect an account in the wallet, then try again.",
            "The request was declined in your wallet. Start again and approve it to continue.",
            "The WalletConnect request expired before the wallet answered. Start again.",
            "WalletConnect is not available right now. Try again later, or enter your address manually.",
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

    // MARK: connector, manual

    @Test func manualProofRefusesATypoThenAccepts() async {
        let recorder = Recorder()
        let connector = Self.connector(platform: SdkBittensorWalletPlatformIos, recorder: recorder)

        connector.presentChooser()
        #expect(connector.stage == .choosing)
        await connector.choose(walletId: "taocom", purpose: SdkBittensorWalletPurposeLogin)
        #expect(connector.stage == .manualSignature(walletId: "taocom", message: Self.message))
        #expect(recorder.challengeArgs.count == 1)
        #expect(recorder.challengeArgs.first?.blockchain == SdkTAO)
        #expect(recorder.challengeArgs.first?.purpose == SdkBittensorWalletPurposeLogin)
        #expect(recorder.opened.isEmpty)
        #expect(!connector.addressLocked)

        connector.manualAddress = Self.alice
        connector.manualSignature = "0x1234"
        await connector.submitManual()
        #expect(connector.manualError == String(localized: "That is not a valid signature. Paste the full 0x signature from your wallet."))
        #expect(connector.stage == .manualSignature(walletId: "taocom", message: Self.message))
        #expect(recorder.proofs.isEmpty)

        connector.manualSignature = "  " + String(repeating: "AB", count: 64) + "\n"
        await connector.submitManual()
        #expect(recorder.proofs == [BittensorWalletProofInfo(walletId: "taocom", purpose: "login", address: Self.alice, message: Self.message, signature: Self.signature)])
        #expect(connector.stage == .idle)
    }

    @Test func manualProofBoundToTheTypedAddress() async {
        let recorder = Recorder()
        let connector = Self.connector(platform: SdkBittensorWalletPlatformMacos, recorder: recorder)

        await connector.choose(walletId: "taocom", purpose: SdkBittensorWalletPurposeCreate, expectedAddress: Self.alice)
        #expect(recorder.challengeArgs.first?.walletAddress == Self.alice)
        #expect(connector.addressLocked)
        #expect(connector.manualAddress == Self.alice)

        connector.manualAddress = Self.bob
        connector.manualSignature = Self.signature
        await connector.submitManual()
        #expect(connector.manualError == String(localized: "The wallet that signed is not the address you entered."))
        #expect(recorder.proofs.isEmpty)
    }

    @Test func anExpiredManualChallengeNeedsANewOne() async {
        let recorder = Recorder()
        let connector = Self.connector(platform: SdkBittensorWalletPlatformIos, recorder: recorder)

        await connector.choose(walletId: "talisman", purpose: SdkBittensorWalletPurposeConnect)
        recorder.nowMillis += 300 * 1000
        connector.manualAddress = Self.alice
        connector.manualSignature = Self.signature
        await connector.submitManual()
        #expect(connector.stage == .failed(String(localized: "This request expired. Start again to get a new message to sign.")))
        #expect(recorder.proofs.isEmpty)
    }

    // MARK: connector, browser bridge (macOS Talisman)

    @Test func bridgeUrlNamesTheWalletAndPurposeWithoutWalletConnect() async throws {
        let recorder = Recorder()
        let connector = Self.connector(platform: SdkBittensorWalletPlatformMacos, recorder: recorder)

        await connector.choose(walletId: "talisman", purpose: SdkBittensorWalletPurposeConnect)
        #expect(connector.stage == .awaitingBrowser(walletId: "talisman"))
        let opened = try #require(recorder.opened.first)
        let components = try #require(URLComponents(url: opened, resolvingAgainstBaseURL: false))
        // the page reads the query with URLSearchParams: form encoding, "+" is a space
        let query = Dictionary(uniqueKeysWithValues: (components.percentEncodedQueryItems ?? []).map {
            ($0.name, ($0.value ?? "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "")
        })
        #expect(components.host == "ur.io")
        // the Bittensor-only bridge page (never the shared Solana /wallet-connect)
        #expect(components.path == "/bittensor-connect")
        #expect(query["provider"] == "bittensor")
        #expect(query["method"] == "signMessage")
        #expect(query["wallet"] == "talisman")
        #expect(query["purpose"] == "connect")
        #expect(query["message"] == Self.message)
        #expect(query["redirect_link"] == "urnetwork://bittensor-sign-message")
        #expect(query["wc_project_id"] == nil)
    }

    // MARK: WalletConnect

    @Test func theAppCarriesItsWalletConnectProjectId() {
        // Info.plist URWalletConnectProjectId (vault/main/walletconnect.yml)
        #expect(!BittensorWallet.walletConnectProjectId.isEmpty)
    }

    @Test(arguments: [SdkBittensorWalletPlatformIos, SdkBittensorWalletPlatformMacos])
    func walletConnectOpensTheBittensorPageWithTheProjectId(platform: String) async throws {
        let recorder = Recorder()
        let connector = Self.connector(platform: platform, recorder: recorder)
        await connector.choose(walletId: "walletconnect", purpose: SdkBittensorWalletPurposeLogin)
        #expect(connector.stage == .awaitingBrowser(walletId: "walletconnect"))
        let opened = try #require(recorder.opened.first)
        let components = try #require(URLComponents(url: opened, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.percentEncodedQueryItems ?? []).map {
            ($0.name, ($0.value ?? "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "")
        })
        #expect(components.host == "ur.io")
        #expect(components.path == "/bittensor-connect")
        #expect(query["wallet"] == "walletconnect")
        #expect(query["wc_project_id"] == Self.walletConnectProjectId)
        #expect(query["purpose"] == "login")
        #expect(query["message"] == Self.message)
        #expect(query["redirect_link"] == "urnetwork://bittensor-sign-message")
    }

    @Test(arguments: [SdkBittensorWalletPlatformIos, SdkBittensorWalletPlatformMacos])
    func walletConnectReturnIgnoresOtherWalletsAndFlows(platform: String) async {
        let recorder = Recorder()
        let connector = Self.connector(platform: platform, recorder: recorder)
        await connector.choose(walletId: "walletconnect", purpose: SdkBittensorWalletPurposeLogin)

        // another wallet's hand-back (a Talisman page left open) is not ours
        let talisman = Self.returnUrl(["address": Self.alice, "signature": Self.signature, "message": Self.message, "purpose": "login", "wallet": "talisman"])
        await connector.handleBridgeReturn(talisman)
        #expect(connector.stage == .awaitingBrowser(walletId: "walletconnect"))
        // another flow's hand-back is not ours either
        let connect = Self.returnUrl(["address": Self.alice, "signature": Self.signature, "message": Self.message, "purpose": "connect", "wallet": "walletconnect"])
        await connector.handleBridgeReturn(connect)
        #expect(connector.stage == .awaitingBrowser(walletId: "walletconnect"))
        #expect(recorder.proofs.isEmpty)

        let good = Self.returnUrl(["address": Self.alice, "signature": Self.signature, "message": Self.message, "purpose": "login", "wallet": "walletconnect"])
        await connector.handleBridgeReturn(good)
        #expect(recorder.proofs == [BittensorWalletProofInfo(walletId: "walletconnect", purpose: "login", address: Self.alice, message: Self.message, signature: Self.signature)])
        #expect(connector.stage == .idle)
    }

    @Test func earningsWalletConnectOnIosSignsFirstThenValidates() async {
        let recorder = Recorder()
        let client = FakeClient()
        let flow = Self.flow(platform: SdkBittensorWalletPlatformIos, client: client, recorder: recorder)

        await flow.chooseWallet("walletconnect")
        #expect(flow.stage == .signing)
        #expect(recorder.opened.count == 1)
        #expect(flow.connector.stage == .awaitingBrowser(walletId: "walletconnect"))

        await flow.connector.handleBridgeReturn(Self.returnUrl(["address": Self.bob, "signature": Self.signature, "message": Self.message, "purpose": "connect", "wallet": "walletconnect"]))
        #expect(client.validations == [Self.bob])
        #expect(client.connected.count == 1)
        #expect(client.connected.first?.0 == Self.bob)
    }

    @Test func bridgeReturnForAnotherFlowIsIgnoredAndTheRightOneSigns() async {
        let recorder = Recorder()
        let connector = Self.connector(platform: SdkBittensorWalletPlatformMacos, recorder: recorder)
        await connector.choose(walletId: "talisman", purpose: SdkBittensorWalletPurposeConnect)

        // the sign-in screen's return reaches every mounted handler
        let loginReturn = Self.returnUrl(["address": Self.alice, "signature": Self.signature, "message": Self.message, "purpose": "login", "wallet": "talisman"])
        #expect(connector.isBridgeReturn(loginReturn))
        await connector.handleBridgeReturn(loginReturn)
        #expect(connector.stage == .awaitingBrowser(walletId: "talisman"))
        #expect(recorder.proofs.isEmpty)

        // a solana return is not a bittensor hand-back
        #expect(!connector.isBridgeReturn(URL(string: "urnetwork://phantom-connect?nonce=a&data=b")!))

        let good = Self.returnUrl(["address": Self.bob, "signature": String(Self.signature.dropFirst(2)), "message": Self.message, "purpose": "connect", "wallet": "talisman"])
        await connector.handleBridgeReturn(good)
        #expect(recorder.proofs == [BittensorWalletProofInfo(walletId: "talisman", purpose: "connect", address: Self.bob, message: Self.message, signature: Self.signature)])
        #expect(connector.stage == .idle)
        // a replay after the proof is not a return for any open session
        #expect(!connector.isBridgeReturn(good))
    }

    @Test func bridgeReturnOverAnotherChallengeFails() async {
        let recorder = Recorder()
        let connector = Self.connector(platform: SdkBittensorWalletPlatformMacos, recorder: recorder)
        await connector.choose(walletId: "talisman", purpose: SdkBittensorWalletPurposeLogin)

        let other = Self.message.replacingOccurrences(of: "q1w2", with: "zzzz")
        await connector.handleBridgeReturn(Self.returnUrl(["address": Self.alice, "signature": Self.signature, "message": other, "purpose": "login"]))
        #expect(connector.stage == .failed(String(localized: "The wallet signed a different request. Start again.")))
        #expect(recorder.proofs.isEmpty)
    }

    @Test func bridgeWalletErrorShowsTheWalletsText() async {
        let recorder = Recorder()
        let connector = Self.connector(platform: SdkBittensorWalletPlatformMacos, recorder: recorder)
        await connector.choose(walletId: "talisman", purpose: SdkBittensorWalletPurposeLogin)

        await connector.handleBridgeReturn(Self.returnUrl(["errorCode": "-1", "errorMessage": "Cancelled", "purpose": "login"]))
        #expect(connector.stage == .failed("Cancelled"))
    }

    // the page's code goes through the real SDK session to the screen, in this
    // app's words with the chosen wallet's name; a code the app does not know
    // shows the page's text
    @Test func bridgeErrorCodeShowsTheAppsOwnWords() async {
        let english = "Your Talisman wallet doesn't have the address you entered. Add or connect that account in the wallet and try again, or enter your address manually."
        let recorder = Recorder()
        let talisman = Self.connector(platform: SdkBittensorWalletPlatformMacos, recorder: recorder)
        await talisman.choose(walletId: "talisman", purpose: SdkBittensorWalletPurposeConnect, expectedAddress: Self.bob)
        await talisman.handleBridgeReturn(Self.returnUrl(["errorCode": "address_not_in_wallet", "errorMessage": english, "purpose": "connect"]))
        #expect(talisman.stage == .failed(String(localized: "Your \("Talisman") wallet doesn't have the address you entered. Add or connect that account in the wallet, or enter an address it has.")))

        let walletConnect = Self.connector(platform: SdkBittensorWalletPlatformIos, recorder: recorder)
        await walletConnect.choose(walletId: "walletconnect", purpose: SdkBittensorWalletPurposeLogin)
        await walletConnect.handleBridgeReturn(Self.returnUrl(["errorCode": "user_rejected", "errorMessage": "User rejected.", "purpose": "login"]))
        #expect(walletConnect.stage == .failed(String(localized: "The request was declined in your wallet. Start again and approve it to continue.")))

        let unknown = Self.connector(platform: SdkBittensorWalletPlatformIos, recorder: recorder)
        await unknown.choose(walletId: "walletconnect", purpose: SdkBittensorWalletPurposeLogin)
        await unknown.handleBridgeReturn(Self.returnUrl(["errorCode": "wallet_locked", "errorMessage": "The wallet is locked.", "purpose": "login"]))
        #expect(unknown.stage == .failed("The wallet is locked."))
        #expect(recorder.proofs.isEmpty)
    }

    @Test func cancelDropsALateReturn() async {
        let recorder = Recorder()
        let connector = Self.connector(platform: SdkBittensorWalletPlatformMacos, recorder: recorder)
        await connector.choose(walletId: "talisman", purpose: SdkBittensorWalletPurposeLogin)
        connector.cancel()

        let late = Self.returnUrl(["address": Self.alice, "signature": Self.signature, "message": Self.message, "purpose": "login"])
        #expect(!connector.isBridgeReturn(late))
        await connector.handleBridgeReturn(late)
        #expect(recorder.proofs.isEmpty)
        #expect(connector.stage == .idle)
    }

    // MARK: Earnings flow

    final class FakeClient: EarningsClient {
        var validations: [String] = []
        var connected: [(String, String, String)] = []
        var existsOnChain = true
        private struct Unsupported: Error {}

        func validateSs58(_ address: String) -> Bool { SdkValidateSs58(address) }
        func shortSs58(_ address: String) -> String { address }
        func formatAlpha(rao: Int64) -> String { "\(rao)" }
        func formatShareBps(_ shareBps: Int64) -> String { "\(shareBps)" }
        func walletChallenge(_ args: SdkAuthWalletChallengeArgs) async throws -> SdkAuthWalletChallengeResult { throw Unsupported() }
        func validateWallet(_ address: String) async throws -> SnWalletValidation {
            validations.append(address)
            return SnWalletValidation(validSyntax: true, existsOnChain: existsOnChain, banned: false, message: "")
        }
        func cachedWallet() -> SnWalletInfo? { nil }
        func fetchWallet() async throws -> SnWalletInfo? { nil }
        func connectWallet(coldkeySs58: String, signature: String, message: String) async throws -> SnWalletInfo {
            connected.append((coldkeySs58, signature, message))
            return SnWalletInfo(coldkeySs58: coldkeySs58, clientId: "", setAtMillis: 0)
        }
        func observeWallet(_ onChange: @escaping (SnWalletInfo?) -> Void) -> EarningsSubscription { EarningsSubscription {} }
        func syncChainSettings() async throws {}
        func gasKey() -> SnGasKeyInfo? { nil }
        func gasBalanceTao() async throws -> Double { 0 }
        func claims() async throws -> (claims: [SnEpochClaimInfo], totalClaimableRao: Int64, schedule: SnEpochScheduleInfo?) { ([], 0, nil) }
        func claim(epochs: [Int64], onEvent: @escaping (SnClaimEvent) -> Void) {}
        func accountEpochs() async throws -> [AccountEpochInfo] { [] }
        func head() async throws -> SnHeadInfo? { nil }
    }

    static func flow(platform: String, client: FakeClient, recorder: Recorder) -> ConnectBittensorWalletFlow {
        ConnectBittensorWalletFlow(
            client: client,
            platform: platform,
            connector: connector(platform: platform, recorder: recorder),
            connect: { address, signature, message in
                try await client.connectWallet(coldkeySs58: address, signature: signature, message: message)
            }
        )
    }

    @Test func earningsTaoComTakesTheAddressThenTheSignature() async {
        let recorder = Recorder()
        let client = FakeClient()
        let flow = Self.flow(platform: SdkBittensorWalletPlatformMacos, client: client, recorder: recorder)
        var connectedWallet: SnWalletInfo?
        flow.onConnected = { connectedWallet = $0 }

        await flow.chooseWallet("taocom")
        #expect(flow.stage == .manualEntry)
        #expect(recorder.challengeArgs.isEmpty)

        flow.manualAddress = " \(Self.alice) "
        await flow.submitManualAddress()
        // validated before anything is signed, then a challenge bound to it
        #expect(client.validations == [Self.alice])
        #expect(flow.stage == .signing)
        #expect(recorder.challengeArgs.first?.walletAddress == Self.alice)
        #expect(recorder.challengeArgs.first?.purpose == SdkBittensorWalletPurposeConnect)
        #expect(flow.connector.addressLocked)
        #expect(flow.connector.manualAddress == Self.alice)

        flow.connector.manualSignature = Self.signature
        await flow.connector.submitManual()
        #expect(client.connected.count == 1)
        #expect(client.connected.first?.0 == Self.alice)
        #expect(client.connected.first?.1 == Self.signature)
        #expect(client.connected.first?.2 == Self.message)
        #expect(connectedWallet?.coldkeySs58 == Self.alice)
        // validated once, before signing
        #expect(client.validations == [Self.alice])
    }

    @Test func earningsTalismanOnMacosSignsFirstThenValidates() async {
        let recorder = Recorder()
        let client = FakeClient()
        client.existsOnChain = false
        let flow = Self.flow(platform: SdkBittensorWalletPlatformMacos, client: client, recorder: recorder)

        await flow.chooseWallet("talisman")
        #expect(flow.stage == .signing)
        #expect(recorder.opened.count == 1)
        #expect(flow.connector.stage == .awaitingBrowser(walletId: "talisman"))

        await flow.connector.handleBridgeReturn(Self.returnUrl(["address": Self.bob, "signature": Self.signature, "message": Self.message, "purpose": "connect", "wallet": "talisman"]))
        #expect(client.validations == [Self.bob])
        #expect(flow.stage == .newWalletWarning)
        #expect(client.connected.isEmpty)

        await flow.continueAnyway()
        #expect(client.connected.count == 1)
        #expect(client.connected.first?.0 == Self.bob)
    }

    @Test func earningsTalismanOnIosIsManual() async {
        let recorder = Recorder()
        let flow = Self.flow(platform: SdkBittensorWalletPlatformIos, client: FakeClient(), recorder: recorder)
        await flow.chooseWallet("talisman")
        #expect(flow.stage == .manualEntry)
        #expect(recorder.opened.isEmpty)
    }

    // MARK: the wallet provider

    /// The sign-in screen used to hand every urnetwork://bittensor-sign-message
    /// to the wallet provider, which took the address and signature without
    /// checking the challenge or the purpose, so a return meant for the
    /// Earnings coldkey (purpose connect) could be submitted as a sign-in.
    @Test func walletProviderLeavesTheBittensorReturnToTheSession() {
        let provider = ConnectWalletProviderViewModel()
        var signatures: [String] = []
        var errors: [Error] = []
        provider.handleDeepLink(
            Self.returnUrl(["address": Self.alice, "signature": Self.signature, "message": Self.message, "purpose": "connect"]),
            onSignature: { signatures.append($0) },
            onError: { errors.append($0) }
        )
        #expect(signatures.isEmpty)
        #expect(errors.isEmpty)
        #expect(provider.connectedPublicKey == nil)
    }
}
