//
//  NoWalletManualEntryTests.swift
//  networkTests
//
//  The Solana payout wallet's connect sheet when no wallet can connect: on
//  iOS neither Phantom nor Solflare is installed, on macOS the ur.io bridge
//  finds no extension of the chosen wallet. The sheet also takes a typed
//  address, which works with any wallet (a Brave Wallet user on android was
//  told only to install a wallet, although entering the address worked), so
//  both lines point at its manual entry, naming the control in its own words,
//  and macOS offers the control. Signing in has no manual entry and keeps its
//  own words.
//

import Foundation
import Testing

struct NoWalletManualEntryTests {

    // …/apple/app/networkTests/NoWalletManualEntryTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let noWalletAppLine = "No compatible Solana wallet app was found on this device. Choose “Enter address manually” to paste your wallet address instead."
    private static let noExtensionLine = "The %@ extension was not found in this browser. Install it and try again, or choose “Enter address manually” to paste your wallet address."

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func eachLineNamesEnterAddressManuallyInEveryLocale() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        let value = { (entry: [String: Any], locale: String) -> String? in
            let localizations = entry["localizations"] as? [String: Any]
            let unit = (localizations?[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
            return unit?["value"] as? String
        }
        let control = try #require(strings["Enter address manually"] as? [String: Any])
        let locales = try #require(control["localizations"] as? [String: Any]).keys.sorted()
        #expect(locales.contains("zh-Hans"))
        for key in [Self.noWalletAppLine, Self.noExtensionLine] {
            let entry = try #require(strings[key] as? [String: Any], "the catalog has no \(key)")
            #expect(entry["extractionState"] as? String != "stale")
            var wrong: [String] = []
            for locale in locales {
                let label = try #require(value(control, locale))
                guard let line = value(entry, locale), !line.isEmpty else {
                    wrong.append("\(locale): not translated")
                    continue
                }
                if locale != "en" && line == key {
                    wrong.append("\(locale): English")
                }
                if !line.contains(label) {
                    wrong.append("\(locale): does not name \(label): \(line)")
                }
                if line.contains("%@") != key.contains("%@") {
                    wrong.append("\(locale): \(line)")
                }
            }
            #expect(wrong.isEmpty, "\(key): \(wrong)")
        }
    }

    // iOS: the chooser's line when neither wallet app is installed sits above
    // Enter address manually
    @Test func theChooserPointsAtManualEntryWhenNoWalletAppIsInstalled() throws {
        let sheet = try Self.source("network/Main/Account/Earnings/Usdc/ConnectSolanaWalletSheet.swift")
        let note = try #require(sheet.range(of: "if !isPhantomInstalled && !isSolflareInstalled {"))
        let manual = try #require(sheet.range(of: "flow.enterManually()"))
        #expect(sheet[note.upperBound...].hasPrefix("\n                Text(\"\(Self.noWalletAppLine)\")"))
        #expect(note.upperBound < manual.lowerBound)
        // the retired line said a wallet app is the only way
        #expect(!sheet.contains("Please install Phantom or Solflare to use this feature"))
    }

    // macOS: the bridge's missing extension is a stage of its own, with the
    // line and Enter address manually
    @Test func aMissingExtensionOffersManualEntry() throws {
        let flow = try Self.source("network/Main/Account/Earnings/Usdc/ConnectSolanaWalletFlow.swift")
        #expect(flow.contains("String(localized: \"The \\(walletName) extension was not found in this browser. Install it and try again, or choose “Enter address manually” to paste your wallet address.\")"))
        let sheet = try Self.source("network/Main/Account/Earnings/Usdc/ConnectSolanaWalletSheet.swift")
        let stage = try #require(sheet.range(of: "case .extensionNotFound(let app):"), "the sheet has no missing extension stage")
        let rest = sheet[stage.upperBound...]
        let end = rest.range(of: "\n        }\n    }")?.lowerBound ?? rest.endIndex
        let body = rest[..<end]
        #expect(body.contains("ConnectSolanaWalletFlow.extensionNotFoundMessage(for: app)"))
        #expect(body.contains("text: \"Enter address manually\""))
        #expect(body.contains("flow.enterManually()"))
    }

    // signing in needs a wallet's signature: no address field to point at
    @Test func signingInKeepsItsOwnNoWalletWords() throws {
        let login = try Self.source("network/Authenticate/LoginInitial/LoginInitialView.swift")
        #expect(login.contains("No Solana wallets were found installed on this device. Please install a wallet and try again."))
        #expect(!login.contains("Enter address manually"))
        let signSheet = try Self.source("network/Shared/Views/SolanaSignMessageSheet.swift")
        #expect(signSheet.contains("Please install Phantom or Solflare to use this feature"))
        #expect(!signSheet.contains("Enter address manually"))
        let provider = try Self.source("network/Shared/ViewModels/ConnectWalletProviderViewModel.swift")
        #expect(provider.contains("return String(localized: \"The \\(walletName) extension was not found in this browser. Install it, then try again.\")"))
    }
}
