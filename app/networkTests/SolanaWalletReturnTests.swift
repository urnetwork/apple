//
//  SolanaWalletReturnTests.swift
//  networkTests
//
//  A Phantom or Solflare hand-back that carries a failure, as the wallet
//  provider reads it for signing in and adding a sign-in method: the ur.io
//  bridge's codes on macOS and the wallet apps' 4001 on iOS read in this
//  app's words, with the wallet's name where the text takes one; any other
//  code keeps the wallet's or the page's own text. The encrypted envelope
//  needs real wallet keys and is not covered here.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

@MainActor
struct SolanaWalletReturnTests {

    /// The text of the one error the wallet provider hands back for a return
    /// to `host` carrying `errorCode` and `errorMessage`: this app's words for
    /// a code it knows, else the wallet's or the page's own text.
    private static func returnText(host: String, errorCode: String, errorMessage: String) -> String? {
        let provider = ConnectWalletProviderViewModel()
        var components = URLComponents(string: "urnetwork://\(host)")!
        components.queryItems = [
            URLQueryItem(name: "errorCode", value: errorCode),
            URLQueryItem(name: "errorMessage", value: errorMessage),
        ]
        var errors: [Error] = []
        provider.handleDeepLink(
            components.url!,
            onPublicKeyRetrieved: { _, _ in
                Issue.record("a failed connect carries no key")
            },
            onSignature: { _ in
                Issue.record("a refused signature carries no signature")
            },
            onError: { error in
                errors.append(error)
            }
        )
        #expect(errors.count == 1, "\(host) \(errorCode)")
        guard let error = errors.first else {
            return nil
        }
        if case WalletDeepLinkError.walletError(let text) = error {
            return text
        }
        return error.localizedDescription
    }

    // Phantom and Solflare decline with 4001 (their apps on iOS): the app's
    // own words, not the wallet's English
    @Test func aDeclinedConnectReadsInTheAppsWords() {
        #expect(Self.returnText(host: "solflare-connect", errorCode: "4001", errorMessage: "User rejected the request.")
            == "The request was declined in your wallet. Start again and approve it to continue.")
    }

    // the ur.io bridge (macOS) hands a failure back with its code (sdk
    // SolanaWalletBridgeError*) and its English text: a code this app knows
    // reads in its own words, with the wallet's name where the text has one.
    // A missing extension reads as the others do: it had a case of its own
    // only for the USDC payout sheet's manual entry, gone with USDC payouts
    @Test func theBridgePagesCodesReadInTheAppsWords() {
        let english = "The page's English text."
        let cases: [(host: String, code: String, text: String)] = [
            ("phantom-connect", SdkSolanaWalletBridgeErrorExtensionNotFound, "The Phantom extension was not found in this browser. Install it, then try again."),
            ("solflare-connect", SdkSolanaWalletBridgeErrorExtensionNotFound, "The Solflare extension was not found in this browser. Install it, then try again."),
            ("solflare-connect", SdkSolanaWalletBridgeErrorNoAccount, "Your Solflare wallet has no account to sign with. Add or connect an account in the wallet, then try again."),
            ("phantom-connect", SdkSolanaWalletBridgeErrorUserRejected, "The request was declined in your wallet. Start again and approve it to continue."),
            ("phantom-connect", SdkSolanaWalletBridgeErrorSessionNotFound, "The wallet connection wasn't found in this browser. Start again to reconnect your wallet."),
        ]
        for c in cases {
            #expect(Self.returnText(host: c.host, errorCode: c.code, errorMessage: english) == c.text, "\(c.host) \(c.code)")
        }
        // the page's other failures, a code this app does not know, and a page
        // before the codes: the page's text
        for code in [SdkSolanaWalletBridgeErrorInvalidRequest, SdkSolanaWalletBridgeErrorWallet, "wallet_locked", "-1"] {
            #expect(Self.returnText(host: "phantom-connect", errorCode: code, errorMessage: english)
                == "Wallet connect error: \(english)", "\(code)")
        }
    }

    // the sign step's refusal comes back the same way (the bridge on macOS)
    @Test func aSignatureRefusalCarriesTheAppsWordsToo() {
        #expect(Self.returnText(host: "phantom-sign-message", errorCode: SdkSolanaWalletBridgeErrorSessionNotFound, errorMessage: "No wallet session found. Please connect first.")
            == "The wallet connection wasn't found in this browser. Start again to reconnect your wallet.")
        // a code this app does not know keeps the wallet's own text
        #expect(Self.returnText(host: "phantom-sign-message", errorCode: "wallet_locked", errorMessage: "The wallet is locked.")
            == "Wallet signing error: The wallet is locked.")
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

    // …/apple/app/networkTests/SolanaWalletReturnTests.swift -> …/apple/app
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
}
