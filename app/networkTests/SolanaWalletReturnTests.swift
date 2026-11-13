//
//  SolanaWalletReturnTests.swift
//  networkTests
//
//  A Solana wallet sign-in that fails (signing in, the second signature that
//  creates a network, adding a sign-in method) reads as the sdk reads it
//  (SdkSolanaWalletFailureFor), so the same failure shows the same message as
//  on every other app: the ur.io bridge page's codes on macOS, the wallet
//  apps' own codes on iOS, and the failures the app finds itself. The
//  wallet's or the page's English text is never the message. Before, the
//  app's own words for four codes were shown nowhere (only a payout sheet,
//  since removed, showed them), so signing in said "There was an error
//  logging in" and adding a sign-in method said nothing. The encrypted
//  envelope needs real wallet keys and is not covered here.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

@MainActor
struct SolanaWalletReturnTests {

    // the text a wallet or the bridge page sends beside its code
    private static let english = "The page's English text."

    private static func returnUrl(host: String, errorCode: String) -> URL {
        var components = URLComponents(string: "urnetwork://\(host)")!
        components.queryItems = [
            URLQueryItem(name: "errorCode", value: errorCode),
            URLQueryItem(name: "errorMessage", value: english),
        ]
        return components.url!
    }

    /// The one failure the wallet provider hands back for a return to `host`
    /// carrying `errorCode`, read in `source`'s scheme (the bridge page's on
    /// macOS, the wallet apps' on iOS) whatever platform runs the test.
    private static func returnFailure(source: String, host: String, errorCode: String) -> SolanaWalletFailure? {
        let provider = ConnectWalletProviderViewModel(walletReturnSource: source)
        var failures: [SolanaWalletFailure] = []
        provider.handleDeepLink(
            returnUrl(host: host, errorCode: errorCode),
            onPublicKeyRetrieved: { _, _ in
                Issue.record("a failed connect carries no key")
            },
            onSignature: { _ in
                Issue.record("a refused signature carries no signature")
            },
            onError: { failure in
                failures.append(failure)
            }
        )
        #expect(failures.count == 1, "\(source) \(host) \(errorCode)")
        return failures.first
    }

    // Phantom and Solflare decline with 4001 in their apps' hand-back (iOS),
    // at either step: the sdk's words, not the wallet's English
    @Test func aDeclineInTheWalletAppReadsAsDeclined() {
        for host in ["solflare-connect", "phantom-connect", "phantom-sign-message", "solflare-sign-message"] {
            let failure = Self.returnFailure(source: SdkSolanaWalletFailureSourceWalletApp, host: host, errorCode: "4001")
            #expect(failure?.failure == SdkSolanaWalletFailureUserRejected, "\(host)")
            #expect(failure?.messageKey == SdkSolanaWalletFailureMessageUserRejected, "\(host)")
            #expect(failure?.message == "The request was declined in your wallet. Start again and approve it to continue.", "\(host)")
        }
    }

    // the ur.io bridge page (macOS) hands a failure back with its code (sdk
    // SolanaWalletBridgeError*) and its English text: the sdk's failure for
    // the code, with the wallet's name where its message takes one
    @Test func theBridgePagesCodesReadAsTheSdkReadsThem() {
        let cases: [(host: String, code: String, failure: String, messageKey: String, walletName: String, text: String)] = [
            ("phantom-connect", SdkSolanaWalletBridgeErrorExtensionNotFound, SdkSolanaWalletFailureExtensionNotFound, SdkSolanaWalletFailureMessageExtensionNotFound, "Phantom",
             "The Phantom extension was not found in this browser. Install it, then try again."),
            ("solflare-connect", SdkSolanaWalletBridgeErrorExtensionNotFound, SdkSolanaWalletFailureExtensionNotFound, SdkSolanaWalletFailureMessageExtensionNotFound, "Solflare",
             "The Solflare extension was not found in this browser. Install it, then try again."),
            ("solflare-connect", SdkSolanaWalletBridgeErrorNoAccount, SdkSolanaWalletFailureNoAccount, SdkSolanaWalletFailureMessageNoAccount, "Solflare",
             "Your Solflare wallet has no account to sign with. Add or connect an account in the wallet, then try again."),
            ("phantom-connect", SdkSolanaWalletBridgeErrorUserRejected, SdkSolanaWalletFailureUserRejected, SdkSolanaWalletFailureMessageUserRejected, "",
             "The request was declined in your wallet. Start again and approve it to continue."),
            ("solflare-sign-message", SdkSolanaWalletBridgeErrorUserRejected, SdkSolanaWalletFailureUserRejected, SdkSolanaWalletFailureMessageUserRejected, "",
             "The request was declined in your wallet. Start again and approve it to continue."),
            ("phantom-sign-message", SdkSolanaWalletBridgeErrorSessionNotFound, SdkSolanaWalletFailureSessionNotFound, SdkSolanaWalletFailureMessageSessionNotFound, "",
             "The wallet connection wasn't found in this browser. Start again to reconnect your wallet."),
        ]
        for c in cases {
            let failure = Self.returnFailure(source: SdkSolanaWalletFailureSourceBridge, host: c.host, errorCode: c.code)
            #expect(failure?.failure == c.failure, "\(c.host) \(c.code)")
            #expect(failure?.messageKey == c.messageKey, "\(c.host) \(c.code)")
            #expect(failure?.walletName == c.walletName, "\(c.host) \(c.code)")
            #expect(failure?.message == c.text, "\(c.host) \(c.code)")
        }
    }

    // the page's other failures, a code this build does not know, the -1 of
    // pages before the codes, and a code of the other platform's scheme: the
    // wallet's generic failure with its name, never the page's or the
    // wallet's own text
    @Test func anyOtherCodeIsTheWalletsGenericFailure() {
        let cases: [(source: String, host: String, code: String, text: String)] = [
            (SdkSolanaWalletFailureSourceBridge, "phantom-connect", SdkSolanaWalletBridgeErrorInvalidRequest,
             "Your Phantom wallet couldn't finish the request. Check the wallet, then try again."),
            (SdkSolanaWalletFailureSourceBridge, "solflare-connect", SdkSolanaWalletBridgeErrorWallet,
             "Your Solflare wallet couldn't finish the request. Check the wallet, then try again."),
            (SdkSolanaWalletFailureSourceBridge, "phantom-sign-message", "wallet_locked",
             "Your Phantom wallet couldn't finish the request. Check the wallet, then try again."),
            (SdkSolanaWalletFailureSourceBridge, "phantom-connect", "-1",
             "Your Phantom wallet couldn't finish the request. Check the wallet, then try again."),
            // the wallet apps' decline is not a bridge page code
            (SdkSolanaWalletFailureSourceBridge, "phantom-connect", "4001",
             "Your Phantom wallet couldn't finish the request. Check the wallet, then try again."),
            (SdkSolanaWalletFailureSourceWalletApp, "solflare-sign-message", "-32603",
             "Your Solflare wallet couldn't finish the request. Check the wallet, then try again."),
            // nor are the bridge page's codes a wallet app's
            (SdkSolanaWalletFailureSourceWalletApp, "phantom-connect", SdkSolanaWalletBridgeErrorUserRejected,
             "Your Phantom wallet couldn't finish the request. Check the wallet, then try again."),
            (SdkSolanaWalletFailureSourceWalletApp, "solflare-connect", SdkSolanaWalletBridgeErrorExtensionNotFound,
             "Your Solflare wallet couldn't finish the request. Check the wallet, then try again."),
        ]
        for c in cases {
            let failure = Self.returnFailure(source: c.source, host: c.host, errorCode: c.code)
            #expect(failure?.failure == SdkSolanaWalletFailureWallet, "\(c.source) \(c.code)")
            #expect(failure?.messageKey == SdkSolanaWalletFailureMessageWallet, "\(c.source) \(c.code)")
            #expect(failure?.message == c.text, "\(c.source) \(c.code)")
            #expect(failure?.message.contains(Self.english) == false, "\(c.source) \(c.code)")
        }
    }

    // a hand-back with neither its answer nor a failure (no key, nonce or
    // data): the wallet's generic failure, not the app's English
    @Test func anUnreadableHandBackIsTheWalletsGenericFailure() {
        for (host, walletName) in [("phantom-connect", "Phantom"), ("solflare-sign-message", "Solflare")] {
            let provider = ConnectWalletProviderViewModel(walletReturnSource: SdkSolanaWalletFailureSourceWalletApp)
            var failures: [SolanaWalletFailure] = []
            provider.handleDeepLink(URL(string: "urnetwork://\(host)?nonce=synthetic")!, onError: { failures.append($0) })
            #expect(failures.map(\.failure) == [SdkSolanaWalletFailureWallet], "\(host)")
            #expect(failures.first?.walletName == walletName, "\(host)")
        }
    }

    // a sign step that found no wallet connection in the browser (macOS)
    // drops the app's too, so starting again connects the wallet again
    // instead of asking the same browser to sign; a decline keeps it
    @Test func aLostBrowserConnectionIsDroppedSoStartingAgainReconnects() {
        let provider = ConnectWalletProviderViewModel(walletReturnSource: SdkSolanaWalletFailureSourceBridge)
        provider.handleDeepLink(Self.returnUrl(host: "phantom-sign-message", errorCode: SdkSolanaWalletBridgeErrorUserRejected))
        #expect(provider.connectedWalletProvider == .phantom)
        provider.handleDeepLink(Self.returnUrl(host: "phantom-sign-message", errorCode: SdkSolanaWalletBridgeErrorSessionNotFound))
        #expect(provider.connectedWalletProvider == nil)
        #expect(provider.connectedPublicKey == nil)
    }

    // the failures the app finds itself: a wallet app that would not open,
    // no wallet app at all (the iOS sign-in tile), and one it cannot name
    @Test func theAppsOwnFailuresReadAsTheSdkReadsThem() {
        let notOpened = SolanaWalletFailure.app(SdkSolanaWalletFailureWalletAppNotFound, provider: .solflare)
        #expect(notOpened.messageKey == SdkSolanaWalletFailureMessageWalletAppNotFound)
        #expect(notOpened.message == "Couldn't open wallet. Please install it and try again.")
        let noWallet = SolanaWalletFailure.app(SdkSolanaWalletFailureNoWallet, provider: nil)
        #expect(noWallet.messageKey == SdkSolanaWalletFailureMessageNoWallet)
        #expect(noWallet.message == "No Solana wallets were found installed on this device. Please install a wallet and try again.")
        let unnamed = SolanaWalletFailure.app(SdkSolanaWalletFailureWallet, provider: nil)
        #expect(unnamed.walletName == "Solana")
        #expect(unnamed.message == "Your Solana wallet couldn't finish the request. Check the wallet, then try again.")
    }

    // every store key the sdk answers has its text, and a key this build
    // does not know reads as the wallet's generic failure
    @Test func eachMessageKeyHasItsText() {
        let cases: [(messageKey: String, walletName: String, text: String)] = [
            (SdkSolanaWalletFailureMessageUserRejected, "",
             String(localized: "The request was declined in your wallet. Start again and approve it to continue.")),
            (SdkSolanaWalletFailureMessageNoWallet, "",
             String(localized: "No Solana wallets were found installed on this device. Please install a wallet and try again.")),
            (SdkSolanaWalletFailureMessageWalletAppNotFound, "",
             String(localized: "Couldn't open wallet. Please install it and try again.")),
            (SdkSolanaWalletFailureMessageExtensionNotFound, "Phantom",
             String(localized: "The \("Phantom") extension was not found in this browser. Install it, then try again.")),
            (SdkSolanaWalletFailureMessageNoAccount, "Solflare",
             String(localized: "Your \("Solflare") wallet has no account to sign with. Add or connect an account in the wallet, then try again.")),
            (SdkSolanaWalletFailureMessageSessionNotFound, "",
             String(localized: "The wallet connection wasn't found in this browser. Start again to reconnect your wallet.")),
            (SdkSolanaWalletFailureMessageWallet, "Phantom",
             String(localized: "Your \("Phantom") wallet couldn't finish the request. Check the wallet, then try again.")),
            (SdkSolanaWalletFailureMessageWallet, "",
             String(localized: "Your \("Solana") wallet couldn't finish the request. Check the wallet, then try again.")),
            ("a_key_from_a_later_sdk", "Solflare",
             String(localized: "Your \("Solflare") wallet couldn't finish the request. Check the wallet, then try again.")),
            ("a_key_from_a_later_sdk", "",
             String(localized: "Your \("Solana") wallet couldn't finish the request. Check the wallet, then try again.")),
        ]
        for c in cases {
            #expect(SolanaWalletFailure.message(messageKey: c.messageKey, walletName: c.walletName) == c.text, "\(c.messageKey) \(c.walletName)")
        }
    }

    // …/apple/app/networkTests/SolanaWalletReturnTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func theFailureMessagesAreTranslatedInEveryLocale() throws {
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
            "The request was declined in your wallet. Start again and approve it to continue.",
            "No Solana wallets were found installed on this device. Please install a wallet and try again.",
            "Couldn't open wallet. Please install it and try again.",
            "The %@ extension was not found in this browser. Install it, then try again.",
            "Your %@ wallet has no account to sign with. Add or connect an account in the wallet, then try again.",
            "The wallet connection wasn't found in this browser. Start again to reconnect your wallet.",
            "Your %@ wallet couldn't finish the request. Check the wallet, then try again.",
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
}
