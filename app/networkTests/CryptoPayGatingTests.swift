//
//  CryptoPayGatingTests.swift
//  networkTests
//
//  The App Store builds keep store billing with no toggle and no crypto copy
//  (mmm ZCASH.md §0.1, mmm/ZCASH-CONTRACT.md §6.3): every crypto view and
//  every crypto string compiles only under DIRECT_DOWNLOAD, while the pure
//  logic compiles in both builds (this test host is the App Store app) and
//  carries no copy. And the copy the direct-download build shows is in the
//  string catalog, the interpolated keys too, which CatalogLookupTests cannot
//  see.
//
//  Reads the Swift sources and the generated string catalog; no device.
//

import Foundation
import Testing

struct CryptoPayGatingTests {

    // …/apple/app/networkTests/CryptoPayGatingTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let network = appRoot.appendingPathComponent("network")

    /// The direct-download build's crypto views and the files that hold them.
    private static let viewsDirectory = "Shared/Views/CryptoPay"

    /// The pure crypto files both builds compile.
    private static let pureFiles = [
        "Shared/Billing/CryptoPayment.swift",
        "Shared/Billing/CryptoInvoiceStore.swift",
        "Shared/Billing/CryptoPaymentSdk.swift",
    ]

    /// What only the direct-download build may name: the crypto views, their
    /// copy, and the store (only that build creates and injects one).
    private static let gatedSymbols = [
        "CryptoInvoiceView",
        "PaymentMethodRowView",
        "CryptoPayCopy",
        "CryptoTermNotice",
        "CryptoPaymentInProgressRow",
        "CryptoPaymentQrCode",
        "cryptoInvoiceStore",
    ]

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: network.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func swiftFiles() throws -> [(path: String, source: String)] {
        let files = try #require(FileManager.default.enumerator(at: network, includingPropertiesForKeys: nil))
        let rootPath = network.resolvingSymlinksInPath().path + "/"
        var sources: [(String, String)] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let path = url.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
            sources.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return sources
    }

    /// Each line of a source with whether it compiles only with
    /// DIRECT_DOWNLOAD (inside `#if DIRECT_DOWNLOAD`, or the `#else` of
    /// `#if !DIRECT_DOWNLOAD`), and the depth of the #if it is in.
    static func lines(_ source: String) -> [(number: Int, text: String, directOnly: Bool, depth: Int)] {
        enum Branch {
            case direct
            case notDirect
            case other
        }
        var stack: [Branch] = []
        var result: [(Int, String, Bool, Int)] = []
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") {
                let condition = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
                stack.append(condition == "DIRECT_DOWNLOAD" ? .direct : (condition == "!DIRECT_DOWNLOAD" ? .notDirect : .other))
            } else if trimmed.hasPrefix("#elseif") {
                if !stack.isEmpty {
                    stack[stack.count - 1] = .other
                }
            } else if trimmed.hasPrefix("#else") {
                if let last = stack.last {
                    stack[stack.count - 1] = last == .direct ? .notDirect : (last == .notDirect ? .direct : .other)
                }
            } else if trimmed.hasPrefix("#endif") {
                _ = stack.popLast()
            }
            result.append((index + 1, line, stack.contains(.direct), stack.count))
        }
        return result
    }

    /// The code of a line, without its `//` comment; a doc or block comment line is no code.
    private static func code(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
            return ""
        }
        guard let comment = line.range(of: "//") else {
            return line
        }
        return String(line[..<comment.lowerBound])
    }

    private static func names(_ code: String, _ symbol: String) -> Bool {
        code.range(of: "\\b\(symbol)\\b", options: .regularExpression) != nil
    }

    @Test func theScannerKnowsWhichLinesAreDirectOnly() {
        let source = """
            a
            #if DIRECT_DOWNLOAD
            b
            #else
            c
            #endif
            #if !DIRECT_DOWNLOAD
            d
            #else
            e
            #endif
            #if os(macOS)
            #if DIRECT_DOWNLOAD
            f
            #endif
            g
            #endif
            """
        let direct = Self.lines(source).filter { $0.directOnly }.map { $0.text.trimmingCharacters(in: .whitespaces) }
        #expect(direct.filter { $0.count == 1 } == ["b", "e", "f"])
    }

    @Test func everyCryptoViewFileCompilesOnlyInTheDirectDownloadBuild() throws {
        let views = try Self.swiftFiles().filter { $0.path.hasPrefix(Self.viewsDirectory + "/") }
        #expect(views.count >= 3, "the crypto views live in \(Self.viewsDirectory)")
        for (path, source) in views {
            // every line of code sits in the file's one #if DIRECT_DOWNLOAD
            for line in Self.lines(source) where !line.text.hasPrefix("#") {
                let code = Self.code(line.text).trimmingCharacters(in: .whitespaces)
                if code.isEmpty {
                    continue
                }
                #expect(line.directOnly, "\(path):\(line.number) compiles into the App Store build: \(code)")
            }
        }
    }

    @Test func theSharedSurfacesNameTheCryptoViewsOnlyInTheDirectDownloadBuild() throws {
        var leaks: [String] = []
        var named = 0
        for (path, source) in try Self.swiftFiles() where !path.hasPrefix(Self.viewsDirectory + "/") {
            for line in Self.lines(source) {
                let code = Self.code(line.text)
                for symbol in Self.gatedSymbols where Self.names(code, symbol) {
                    named += 1
                    if !line.directOnly {
                        leaks.append("\(path):\(line.number): \(symbol)")
                    }
                }
            }
        }
        // the surfaces do name them: the scan is looking at the right files
        #expect(named > 20)
        #expect(leaks.isEmpty, "only the direct-download build may show crypto:\n\(leaks.joined(separator: "\n"))")
    }

    @Test func thePureLogicCarriesNoViewsAndNoCopy() throws {
        let markers = [#"import\s+SwiftUI"#, #"String\(\s*localized"#, #"\bLocalizedStringKey\b"#, #"\bText\("#, #"#if\s+DIRECT_DOWNLOAD"#]
        for path in Self.pureFiles {
            let source = try Self.source(path)
            for line in Self.lines(source) {
                let code = Self.code(line.text)
                for marker in markers {
                    #expect(code.range(of: marker, options: .regularExpression) == nil, "\(path):\(line.number) is not pure: \(code)")
                }
            }
        }
    }

    // MARK: the wiring

    /// A refused crypto start reaches the same guest gates as a refused card
    /// checkout, and a paid invoice starts the confirmation poll a card
    /// purchase starts (the balance refresh, which re-signs the jwt to Pro).
    @Test func theCryptoRefusalsAndPaymentsReachTheCardsHandlers() throws {
        let main = try Self.source("Main/MainView.swift")
        let guest = try #require(main.range(of: ".onChange(of: cryptoInvoiceStore.guestSignInRequiredSequence)"))
        #expect(main.range(of: "subscriptionBalanceViewModel.serverRefusedGuestPurchase()", range: guest.upperBound..<main.endIndex) != nil)
        let paid = try #require(main.range(of: ".onChange(of: cryptoInvoiceStore.paidSequence)"))
        #expect(main.range(of: "subscriptionBalanceViewModel.startPolling()", range: paid.upperBound..<main.endIndex) != nil)
        // the launch's resume, and the activation the invoice polls with
        #expect(main.contains("cryptoInvoiceStore.resume()"))
        #expect(main.contains("cryptoInvoiceStore.setAppActive(active)"))

        // the intro sells a plan without a gate: it opens the upgrade sheet's
        let intro = try Self.source("Shared/Views/Introduction/IntroductionView.swift")
        let introGuest = try #require(intro.range(of: ".onChange(of: cryptoInvoiceStore.guestSignInRequiredSequence)"))
        #expect(intro.range(of: "openGuestConversion()", range: introGuest.upperBound..<intro.endIndex) != nil)

        // the account screen resumes a saved invoice when it appears
        let account = try Self.source("Main/Account/AccountRootView.swift")
        #expect(account.contains("cryptoInvoiceStore.resume()"))
    }

    // MARK: the copy

    private static func catalogStrings() throws -> [String: Any] {
        let data = try Data(contentsOf: network.appendingPathComponent("Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(catalog?["strings"] as? [String: Any])
    }

    /// The direct-download build's crypto copy: each key (the store's apple
    /// `source`), and for an interpolated one the call that looks it up.
    private static let copy: [(key: String, call: String?)] = [
        ("Pay with", nil),
        ("Card", nil),
        ("USDC", nil),
        ("Zcash", nil),
        ("Monero", nil),
        ("Monthly is card only", nil),
        ("Temporarily unavailable", nil),
        ("Pay with %@", #""Pay with \(method.title)""#),
        ("A one-time payment for a year of Pro. It doesn't renew, and there's no free trial.", nil),
        ("USDC on Solana", nil),
        ("Zcash, shielded", nil),
        ("Send exactly", nil),
        ("To this address", nil),
        ("Memo, if you send by hand", nil),
        ("Open in wallet", nil),
        ("Copy", nil),
        ("Copied", nil),
        ("Quote expires in %@", #""Quote expires in \(time)""#),
        ("Refresh quote", nil),
        ("This quote expired. Refresh it for a new amount.", nil),
        ("%@ more to send", #""\(remaining) more to send""#),
        ("Waiting for your payment", nil),
        ("Payment seen", nil),
        ("Confirming: %lld of %lld", #""Confirming: \(count) of \(required)""#),
        ("Paid. Thank you!", nil),
        ("We received a payment that needs a manual check. Contact support and we'll sort it out.", nil),
        ("Pay another way", nil),
        ("Wallets that work: %@", #""Wallets that work: \(ListFormatter.localizedString(byJoining: display.wallets))""#),
        ("Exchanges such as Coinbase and Robinhood can't send to this shielded address. Send from a shielded wallet.", nil),
        ("Paying with %@ is temporarily unavailable. Try again later, or pay another way.", #""Paying with \(method.title) is temporarily unavailable. Try again later, or pay another way.""#),
        ("Send USDC on the Solana network only. USDC sent on any other network will not arrive.", nil),
        ("Your paid year of Pro has ended. Renew by %@ to keep Pro.", #""Your paid year of Pro has ended. Renew by \(date) to keep Pro.""#),
        ("Renew", nil),
        ("Payment in progress", nil),
        ("Does not renew. Pay again when it ends.", nil),
        ("We're confirming your purchase. Your plan will update automatically.", nil),
    ]

    /// Product names the store keeps untranslated.
    private static let untranslated: Set<String> = ["USDC", "Zcash", "Monero"]

    @Test func everyCryptoStringIsALiveCatalogEntryAndTranslated() throws {
        let strings = try Self.catalogStrings()
        for (key, _) in Self.copy {
            guard let entry = strings[key] as? [String: Any] else {
                Issue.record("\(key.debugDescription) is not in the catalog")
                continue
            }
            #expect(entry["extractionState"] as? String != "stale", "\(key.debugDescription) is stale")
            if Self.untranslated.contains(key) {
                #expect(entry["shouldTranslate"] as? Bool == false, "\(key) is a product name")
                continue
            }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            #expect(localizations.keys.contains("de") && localizations.keys.contains("zh-Hans"), "\(key.debugDescription) is not translated")
        }
    }

    @Test func theInterpolatedKeysAreLookedUpInTheirCatalogForm() throws {
        let views = try Self.swiftFiles()
            .filter { $0.path.hasPrefix(Self.viewsDirectory + "/") }
            .map(\.source)
            .joined(separator: "\n")
        for (key, call) in Self.copy {
            guard let call else {
                continue
            }
            // a String interpolation becomes %@, an Int one %lld
            #expect(views.contains(call), "\(key.debugDescription) is looked up as \(call)")
        }
    }
}
