//
//  PaymentPastDueTests.swift
//  networkTests
//
//  The past-due notice for a renewal whose payment did not go through (support
//  review 2026-10-26: Stripe failed renewals). It shows exactly while the
//  latest balance carries payment_past_due, and "Update payment method" opens
//  ur.io's Manage Subscription signed in with a one-time code, or without one
//  when no code could be made, never the wire's update_payment_url. Both plan
//  cards show it in every build, and its copy is in the string catalog in
//  every language.
//
//  No network and no device: gomobile values, a fake api service, and the
//  Swift sources and the generated string catalog.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/// Makes `authCode` for every code request, or fails each one when nil.
private final class AuthCodeUrApiService: MockUrApiService {
    let authCode: String?
    private(set) var codeRequestCount = 0

    init(authCode: String?) {
        self.authCode = authCode
    }

    override func createAuthCode() async throws -> SdkAuthCodeCreateResult {
        codeRequestCount += 1
        guard let authCode else {
            throw URLError(.notConnectedToInternet)
        }
        let result = SdkAuthCodeCreateResult()
        result.authCode = authCode
        return result
    }
}

/// A purchase confirmation that never runs (these tests read no states).
@MainActor
private final class IdlePurchaseConfirmation: PurchaseConfirming {
    var onStateChanged: ((String) -> Void)?
    func start() {}
    func stop() {}
    func setForeground(_ foreground: Bool) {}
    func startPurchaseConfirmation() {}
}

@MainActor
struct PaymentPastDueTests {

    private static let manageSubscription = URL(string: "https://ur.io/app/subscription")!

    // …/apple/app/networkTests/PaymentPastDueTests.swift -> …/apple/app/network
    private static let network = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("network")

    /// The server's value, as the SDK decodes it.
    private static func sdkPastDue(updatePaymentUrl: String = "https://ur.io/app/subscription") -> SdkPaymentPastDue {
        let pastDue = SdkPaymentPastDue()
        pastDue.store = "stripe"
        pastDue.failTime = "2026-10-20T18:00:00Z"
        pastDue.updatePaymentUrl = updatePaymentUrl
        return pastDue
    }

    private static func balance(_ pastDue: SdkPaymentPastDue?) -> SdkSubscriptionBalanceResult {
        let result = SdkSubscriptionBalanceResult()
        result.paymentPastDue = pastDue
        return result
    }

    private func makeViewModel(_ urApiService: UrApiServiceProtocol = MockUrApiService()) -> SubscriptionBalanceViewModel {
        // a Pro network: no background poll, and these tests start nothing
        SubscriptionBalanceViewModel(
            urApiService: urApiService,
            isPro: true,
            refreshJwt: {},
            purchaseConfirmation: IdlePurchaseConfirmation()
        )
    }

    // MARK: when it shows

    @Test func aBalanceCarryingPaymentPastDueShowsTheNotice() throws {
        let viewModel = makeViewModel()
        #expect(viewModel.paymentPastDue == nil)

        viewModel.applyPlanData(Self.balance(Self.sdkPastDue()))

        let pastDue = try #require(viewModel.paymentPastDue)
        #expect(pastDue == PaymentPastDue(store: "stripe", failTime: "2026-10-20T18:00:00Z"))
    }

    @Test func aBalanceWithoutPaymentPastDueHidesTheNotice() {
        // an older server's balance has no such field at all
        let viewModel = makeViewModel()
        viewModel.applyPlanData(SdkSubscriptionBalanceResult())
        #expect(viewModel.paymentPastDue == nil)

        // the renewal went through, or the retries ended: the next balance
        // without it hides the notice, with no state left behind
        viewModel.applyPlanData(Self.balance(Self.sdkPastDue()))
        #expect(viewModel.paymentPastDue != nil)
        viewModel.applyPlanData(Self.balance(nil))
        #expect(viewModel.paymentPastDue == nil)
        #expect(PaymentPastDue(nil) == nil)
    }

    // MARK: the link

    @Test func updatePaymentMethodOpensManageSubscriptionSignedInWithACode() async throws {
        // the server's codes are base64url with "=" padding
        let urApiService = AuthCodeUrApiService(authCode: "AbC-dEf_123=")
        let url = await makeViewModel(urApiService).updatePaymentMethodURL()

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "ur.io")
        #expect(components.path == "/app/subscription")
        #expect(components.queryItems == [URLQueryItem(name: "auth_code", value: "AbC-dEf_123=")])
        #expect(components.fragment == nil)
        // one code per tap
        #expect(urApiService.codeRequestCount == 1)
    }

    @Test func theCodeIsPercentEncodedAsOneQueryValue() async throws {
        // "&", "=", "#" and "+" stay inside the one parameter
        let code = "a&next=https://example.com/x#y+z"
        let url = await makeViewModel(AuthCodeUrApiService(authCode: code)).updatePaymentMethodURL()

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "ur.io")
        #expect(components.path == "/app/subscription")
        #expect(components.queryItems == [URLQueryItem(name: "auth_code", value: code)])
        #expect(components.fragment == nil)
        #expect(components.percentEncodedQuery == "auth_code=a%26next%3Dhttps://example.com/x%23y%2Bz")
    }

    @Test func withoutACodeUpdatePaymentMethodOpensManageSubscriptionToSignIn() async {
        // the code could not be made (offline, a server error): the web asks
        // the user to sign in
        let failing = AuthCodeUrApiService(authCode: nil)
        let url = await makeViewModel(failing).updatePaymentMethodURL()
        #expect(url == Self.manageSubscription)
        #expect(url.query == nil)
        #expect(failing.codeRequestCount == 1)

        // a blank code is no code
        let blank = await makeViewModel(AuthCodeUrApiService(authCode: " \n")).updatePaymentMethodURL()
        #expect(blank == Self.manageSubscription)
    }

    @Test func theLinkNeverComesFromTheWire() async {
        // a balance whose update_payment_url points somewhere else
        let elsewhere = "https://attacker.example/collect?next=1"

        let signedIn = makeViewModel(AuthCodeUrApiService(authCode: "code-1"))
        signedIn.applyPlanData(Self.balance(Self.sdkPastDue(updatePaymentUrl: elsewhere)))
        #expect(signedIn.paymentPastDue != nil)
        let url = await signedIn.updatePaymentMethodURL()
        #expect(url.absoluteString == "https://ur.io/app/subscription?auth_code=code-1")

        let withoutCode = makeViewModel(AuthCodeUrApiService(authCode: nil))
        withoutCode.applyPlanData(Self.balance(Self.sdkPastDue(updatePaymentUrl: elsewhere)))
        let fallback = await withoutCode.updatePaymentMethodURL()
        #expect(fallback == Self.manageSubscription)
    }

    // MARK: where it shows

    /// The code of a line, without its `//` comment; a doc or block comment
    /// line is no code.
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

    /// The notice on both plan cards, under no #if that names DIRECT_DOWNLOAD
    /// (the crypto lines sit in one), so every build shows it: iOS and macOS,
    /// App Store and direct download.
    @Test func bothPlanCardsShowTheNoticeInEveryBuild() throws {
        let planCards = [
            "Main/Account/AccountRootView.swift",
            "Main/Connect/ConnectActions/ConnectActions.swift",
        ]
        for path in planCards {
            let source = try String(contentsOf: Self.network.appendingPathComponent(path), encoding: .utf8)
            // the conditions of the #if blocks each line is in
            var conditions: [String] = []
            var shown = 0
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if ") {
                    conditions.append(String(trimmed.dropFirst(4)))
                } else if trimmed.hasPrefix("#elseif "), let last = conditions.popLast() {
                    // the branch depends on the #if's condition too
                    conditions.append(last + " " + trimmed.dropFirst(8))
                } else if trimmed.hasPrefix("#endif") {
                    _ = conditions.popLast()
                } else if Self.code(line).contains("PaymentPastDueNotice(") {
                    shown += 1
                    let gated = conditions.contains { $0.contains("DIRECT_DOWNLOAD") }
                    #expect(!gated, "\(path):\(index + 1) shows the notice only in some builds")
                }
            }
            #expect(shown == 1, "\(path) shows the notice \(shown) times")
        }
    }

    // MARK: the copy

    private static let notice = "Your UR Pro payment didn't go through. Update your payment method to keep Pro."
    private static let action = "Update payment method"

    @Test func theCopyIsTranslatedIntoEveryLanguage() throws {
        let data = try Data(contentsOf: Self.network.appendingPathComponent("Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        // every language the app ships
        var locales = Set<String>()
        for case let entry as [String: Any] in strings.values {
            if let localizations = entry["localizations"] as? [String: Any] {
                locales.formUnion(localizations.keys)
            }
        }
        #expect(locales.count == 27)

        for key in [Self.notice, Self.action] {
            let entry = try #require(strings[key] as? [String: Any], "\(key.debugDescription) is not in the catalog")
            #expect(entry["extractionState"] as? String != "stale", "\(key.debugDescription) is stale")
            let translations = try #require(entry["localizations"] as? [String: Any])
            for locale in locales.sorted() {
                let translation = try #require(translations[locale] as? [String: Any], "\(key.debugDescription) has no \(locale)")
                let unit = try #require(translation["stringUnit"] as? [String: Any])
                let value = try #require(unit["value"] as? String)
                #expect(unit["state"] as? String == "translated")
                if locale == "en" {
                    #expect(value == key)
                } else {
                    #expect(value != key, "\(locale) fell back to English")
                }
                if key == Self.notice {
                    // the product's name stays as it is, as in the other Pro copy
                    #expect(value.contains("UR Pro"), "\(locale) changed the name: \(value)")
                }
            }
        }
    }
}
