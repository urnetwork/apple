//
//  BalanceCodeRedeemConfirmationTests.swift
//  networkTests
//
//  A redeem is confirmed as what the server's answer granted
//  (BalanceCodeRedeemedView), not as a bare success the flows confirmed with
//  "You're premium." and the Pro poll:
//  - a data code: the server grants its transfer balance with pro = false and
//    the answer has no pro, so the confirmation is the data the code added;
//  - a gift code (mmm/GIFTOFPRIVACY.md §5, §10.2): the answer carries pro
//    {start_time, end_time, queued} and a transfer balance of 0 bytes, so the
//    confirmation is the year of Pro in place of the data line, and a year
//    queued after the network's paid Pro says when it starts.
//  Every flow that redeems reads the plan after it, so a gift's Pro reaches the
//  plan and the jwt, and confirms the redeem. A redeem whose answer was lost
//  is found in the redeemed list and confirmed the same way, and the list
//  reads a redeemed gift as "A year of Pro" (GIFTOFPRIVACY.md 10.5).
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/// Answers every redeem with a credited transfer balance of `byteCount` and,
/// for a gift code, its year of Pro.
private final class CreditingUrApiService: MockUrApiService {
    let byteCount: Int64
    let pro: SdkRedeemBalanceCodePro?
    private(set) var listReads = 0
    private(set) var sentCodes: [String] = []

    init(byteCount: Int64, pro: SdkRedeemBalanceCodePro? = nil) {
        self.byteCount = byteCount
        self.pro = pro
    }

    override func redeemBalanceCode(_ code: String) async throws -> SdkRedeemBalanceCodeResult {
        sentCodes.append(code)
        let transferBalance = SdkRedeemBalanceCodeTransferBalance()
        transferBalance.balanceByteCount = byteCount
        transferBalance.startTime = pro?.startTime
        transferBalance.endTime = pro?.endTime
        let result = SdkRedeemBalanceCodeResult()
        result.transferBalance = transferBalance
        result.pro = pro
        return result
    }

    override func getRedeemedBalanceCodes() async throws -> SdkGetNetworkRedeemedBalanceCodesResult {
        listReads += 1
        return SdkGetNetworkRedeemedBalanceCodesResult()
    }
}

/// A redeem that did not credit: the server's refusal ("Unknown balance
/// code.", its answer for a code this network already redeemed too) or no
/// answer at all, beside the network's redeemed list (nil: it can't be read).
private final class UncreditedUrApiService: MockUrApiService {
    enum Answer {
        case refused
        case lost
    }

    let answer: Answer
    let listed: [SdkRedeemedBalanceCode]?

    init(answer: Answer, listed: [SdkRedeemedBalanceCode]?) {
        self.answer = answer
        self.listed = listed
    }

    override func redeemBalanceCode(_ code: String) async throws -> SdkRedeemBalanceCodeResult {
        switch answer {
        case .refused:
            let error = SdkRedeemBalanceCodeError()
            error.message = "Unknown balance code."
            let result = SdkRedeemBalanceCodeResult()
            result.error = error
            return result
        case .lost:
            throw URLError(.networkConnectionLost)
        }
    }

    override func getRedeemedBalanceCodes() async throws -> SdkGetNetworkRedeemedBalanceCodesResult {
        guard let listed else {
            throw URLError(.notConnectedToInternet)
        }
        let list = SdkNewRedeemedBalanceCodeList()
        for code in listed {
            list?.add(code)
        }
        let result = SdkGetNetworkRedeemedBalanceCodesResult()
        result.balanceCodes = list
        return result
    }
}

@MainActor
struct BalanceCodeRedeemConfirmationTests {

    private static let code = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let fiveGib: Int64 = 5 * 1024 * 1024 * 1024

    private static let yearMillis: Int64 = 365 * 24 * 60 * 60 * 1000
    /// 2026-11-13T18:00:00Z: a gift redeemed by a network without paid Pro
    private static let redeemMillis: Int64 = 1_794_592_800_000
    /// 2027-03-15T12:00:00Z: the end of the network's paid Pro period, where a
    /// queued gift year starts (the same date in every zone)
    private static let paidEndMillis: Int64 = 1_805_112_000_000

    private static func date(_ millis: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }

    /// A gift's pro, as the sdk reads it from the answer.
    private static func sdkPro(startMillis: Int64, queued: Bool) -> SdkRedeemBalanceCodePro {
        let pro = SdkRedeemBalanceCodePro()
        pro.startTime = SdkTime(unixMilli: startMillis)
        pro.endTime = SdkTime(unixMilli: startMillis + yearMillis)
        pro.queued = queued
        return pro
    }

    private static func grant(startMillis: Int64, queued: Bool) -> RedeemedBalanceCode.ProGrant {
        RedeemedBalanceCode.ProGrant(
            startTime: date(startMillis),
            endTime: date(startMillis + yearMillis),
            queued: queued
        )
    }

    private static func redeem(_ api: UrApiServiceProtocol) async throws -> RedeemedBalanceCode {
        let viewModel = RedeemBalanceCodeSheet.ViewModel(api: api)
        viewModel.code = code
        return try await viewModel.redeem().get()
    }

    // MARK: data codes

    @Test func creditedRedeemReportsTheDataTheCodeAdded() async throws {
        let redeemed = try await Self.redeem(CreditingUrApiService(byteCount: Self.fiveGib))

        #expect(redeemed == RedeemedBalanceCode(addedByteCount: Self.fiveGib))
        #expect(redeemed.pro == nil)
    }

    @Test func confirmationStatesTheDataAdded() {
        let redeemed = RedeemedBalanceCode(addedByteCount: Self.fiveGib)
        let message = BalanceCodeRedeemedView.dataAddedMessage(redeemed)

        #expect(message == String(localized: "\(formatBalanceBytes(Int(Self.fiveGib))) of data added to your balance."))
        #expect(message?.contains("5") == true)
        // the line the screen shows
        #expect(BalanceCodeRedeemedView.message(redeemed) == message)
    }

    @Test func confirmationWithoutAByteCountIsTheTitleAlone() {
        let redeemed = RedeemedBalanceCode(addedByteCount: 0)

        #expect(BalanceCodeRedeemedView.dataAddedMessage(redeemed) == nil)
        #expect(BalanceCodeRedeemedView.message(redeemed) == nil)
    }

    // MARK: gift codes

    @Test func giftRedeemCarriesItsYearOfPro() async throws {
        let redeemed = try await Self.redeem(CreditingUrApiService(
            byteCount: 0,
            pro: Self.sdkPro(startMillis: Self.redeemMillis, queued: false)
        ))

        #expect(redeemed == RedeemedBalanceCode(
            addedByteCount: 0,
            pro: Self.grant(startMillis: Self.redeemMillis, queued: false)
        ))
    }

    @Test func giftConfirmationIsAYearOfProInPlaceOfTheDataLine() {
        let redeemed = RedeemedBalanceCode(
            addedByteCount: 0,
            pro: Self.grant(startMillis: Self.redeemMillis, queued: false)
        )

        #expect(BalanceCodeRedeemedView.message(redeemed) == String(localized: "A year of Pro is yours."))
    }

    @Test func queuedGiftRedeemCarriesTheQueuedYear() async throws {
        let redeemed = try await Self.redeem(CreditingUrApiService(
            byteCount: 0,
            pro: Self.sdkPro(startMillis: Self.paidEndMillis, queued: true)
        ))

        #expect(redeemed == RedeemedBalanceCode(
            addedByteCount: 0,
            pro: Self.grant(startMillis: Self.paidEndMillis, queued: true)
        ))
    }

    @Test func queuedGiftConfirmationSaysWhenTheYearStarts() throws {
        let redeemed = RedeemedBalanceCode(
            addedByteCount: 0,
            pro: Self.grant(startMillis: Self.paidEndMillis, queued: true)
        )

        let message = try #require(BalanceCodeRedeemedView.message(redeemed))

        let startText = Self.date(Self.paidEndMillis).formatted(date: .long, time: .omitted)
        let endText = Self.date(Self.paidEndMillis + Self.yearMillis).formatted(date: .long, time: .omitted)
        #expect(message == String(localized: "Your gift year of Pro starts on \(startText), after your current Pro period."))
        #expect(message.contains(startText))
        #expect(!message.contains(endText))
        #expect(message != String(localized: "A year of Pro is yours."))
    }

    @Test func queuedGiftWithoutAStartIsStillAYearOfPro() {
        let redeemed = RedeemedBalanceCode(
            addedByteCount: 0,
            pro: RedeemedBalanceCode.ProGrant(startTime: nil, endTime: nil, queued: true)
        )

        #expect(BalanceCodeRedeemedView.message(redeemed) == String(localized: "A year of Pro is yours."))
    }

    // MARK: a lost answer
    //
    // The server answers a code this network already redeemed as it answers
    // an unknown one, so a redeem whose answer was lost (the connection
    // dropped after the server granted) is found in the network's redeemed
    // list, matched as the server matches a code, and confirmed as redeemed.

    private static let otherCode = "QRSTUVWXYZABCDEFGHIJKLMNOP"

    /// A code in the network's redeemed list, as the sdk reads it.
    private static func listed(_ secret: String, kind: String, byteCount: Int64 = 0, endMillis: Int64? = nil) -> SdkRedeemedBalanceCode {
        let code = SdkRedeemedBalanceCode()
        code.secret = secret
        code.kind = kind
        code.balanceByteCount = byteCount
        code.proDays = kind == SdkBalanceCodeKindProGift ? 365 : 0
        code.redeemTime = SdkTime(unixMilli: redeemMillis)
        if let endMillis {
            code.endTime = SdkTime(unixMilli: endMillis)
        }
        return code
    }

    private static func redeem(typed: String, _ api: UrApiServiceProtocol) async -> (Result<RedeemedBalanceCode, Error>, ValidationState) {
        let viewModel = RedeemBalanceCodeSheet.ViewModel(api: api)
        viewModel.code = typed
        let result = await viewModel.redeem()
        return (result, viewModel.redeemState)
    }

    @Test func aRefusedRedeemOfAGiftThisNetworkRedeemedIsItsYearOfPro() async throws {
        let api = UncreditedUrApiService(answer: .refused, listed: [
            Self.listed(Self.otherCode, kind: SdkBalanceCodeKindData, byteCount: Self.fiveGib),
            Self.listed(Self.code, kind: SdkBalanceCodeKindProGift, endMillis: Self.redeemMillis + Self.yearMillis),
        ])
        // typed as the card prints it, in lower case, with a hyphen
        let (result, state) = await Self.redeem(typed: "abcd efgh ijkl-mnop qrst uvwx yz", api)

        let redeemed = try result.get()
        #expect(redeemed == RedeemedBalanceCode(
            addedByteCount: 0,
            pro: RedeemedBalanceCode.ProGrant(
                startTime: nil,
                endTime: Self.date(Self.redeemMillis + Self.yearMillis),
                queued: false
            )
        ))
        #expect(BalanceCodeRedeemedView.message(redeemed) == String(localized: "A year of Pro is yours."))
        #expect(state == .valid)
    }

    @Test func aLostAnswerAfterTheServerGrantedIsConfirmed() async throws {
        let api = UncreditedUrApiService(answer: .lost, listed: [
            Self.listed(Self.code, kind: SdkBalanceCodeKindData, byteCount: Self.fiveGib),
        ])
        let (result, state) = await Self.redeem(typed: Self.code, api)

        #expect(try result.get() == RedeemedBalanceCode(addedByteCount: Self.fiveGib))
        #expect(state == .valid)
    }

    @Test func aRefusedCodeThisNetworkNeverRedeemedStaysRefused() async {
        let api = UncreditedUrApiService(answer: .refused, listed: [
            Self.listed(Self.otherCode, kind: SdkBalanceCodeKindProGift),
        ])
        let (result, state) = await Self.redeem(typed: Self.code, api)

        var message: String?
        if case .failure(let error) = result,
           case .unknown(let text)? = error as? RedeemBalanceCodeSheet.RedeemBalanceCodeError {
            message = text
        }
        #expect(message == "Unknown balance code.")
        #expect(state == .invalid)
    }

    @Test func aLostAnswerWithoutTheListStaysAFailure() async {
        let api = UncreditedUrApiService(answer: .lost, listed: nil)
        let (result, state) = await Self.redeem(typed: Self.code, api)

        #expect((try? result.get()) == nil)
        #expect(state == .invalid)
    }

    @Test func aCreditedRedeemDoesNotReadTheList() async throws {
        let api = CreditingUrApiService(byteCount: Self.fiveGib)
        _ = try await Self.redeem(api)

        #expect(api.listReads == 0)
    }

    @Test func aCodeIsMatchedAsTheServerMatchesIt() {
        #expect(RedeemBalanceCodeSheet.ViewModel.normalizedSecret(" abcd-efgh ijkl.mnop\tqrst uvwx yz\n") == Self.code)
        #expect(RedeemBalanceCodeSheet.ViewModel.normalizedSecret(Self.code) == Self.code)
        #expect(RedeemBalanceCodeSheet.ViewModel.normalizedSecret(" - ").isEmpty)
    }

    // MARK: the Redeem button

    /// A code typed as the card prints it (groups of four with spaces), with
    /// hyphens, or in lower case is a code: Redeem is offered for it.
    @Test func redeemIsOfferedForACodeTypedAsTheCardPrintsIt() {
        let viewModel = RedeemBalanceCodeSheet.ViewModel(api: MockUrApiService())
        for typed in [
            Self.code,
            "ABCD EFGH IJKL MNOP QRST UVWX YZ",
            "ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ",
            "abcdefghijklmnopqrstuvwxyz",
            " abcd efgh-ijkl mnop qrst uvwx yz ",
        ] {
            viewModel.code = typed
            #expect(viewModel.canRedeem, "\(typed.debugDescription)")
        }
        for typed in [
            String(Self.code.dropLast()),
            Self.code + "A",
            "ABCD EFGH IJKL MNOP QRST UVWX Y",
            "abcd-efgh-ijkl-mnop-qrst-uvwx-yza",
            "",
        ] {
            viewModel.code = typed
            #expect(!viewModel.canRedeem, "\(typed.debugDescription)")
        }
    }

    @Test func redeemIsNotOfferedWhileARedeemIsInFlight() {
        let viewModel = RedeemBalanceCodeSheet.ViewModel(api: MockUrApiService())
        viewModel.code = Self.code
        viewModel.redeemState = .validating

        #expect(!viewModel.canRedeem)
    }

    @Test func aCodeTypedInGroupsIsSentAsTyped() async throws {
        let api = CreditingUrApiService(byteCount: Self.fiveGib)
        let viewModel = RedeemBalanceCodeSheet.ViewModel(api: api)
        viewModel.code = "abcd efgh ijkl-mnop qrst uvwx yz"
        _ = try await viewModel.redeem().get()

        #expect(api.sentCodes == ["abcd efgh ijkl-mnop qrst uvwx yz"])
    }

    // MARK: the redeemed list

    @Test func aRedeemedGiftReadsAsAYearOfProInTheList() throws {
        let gift = Self.listed(Self.code, kind: SdkBalanceCodeKindProGift, endMillis: Self.redeemMillis + Self.yearMillis)
        #expect(TransferBalanceCodesView.amountText(gift) == String(localized: "A year of Pro"))

        let data = Self.listed(Self.otherCode, kind: SdkBalanceCodeKindData, byteCount: Self.fiveGib)
        #expect(TransferBalanceCodesView.amountText(data) == String(localized: "+\(formatBalanceBytes(Int(Self.fiveGib)))"))
        #expect(TransferBalanceCodesView.amountText(data).contains("5"))

        // a code from a server that predates gift codes has no kind: data
        let older = SdkRedeemedBalanceCode()
        try older.unmarshalJSON(Data(#"{"balance_byte_count":5368709120,"secret":"QRSTUVWXYZABCDEFGHIJKLMNOP"}"#.utf8))
        #expect(older.kind == SdkBalanceCodeKindData)
        #expect(TransferBalanceCodesView.amountText(older) == TransferBalanceCodesView.amountText(data))
    }

    // MARK: the catalog and the flows

    // …/apple/app/networkTests/BalanceCodeRedeemConfirmationTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// CatalogLookupTests skips an interpolated literal, so it cannot see the
    /// queued line: both lines are in the catalog for every language it has,
    /// and every translation of the queued line keeps the date.
    @Test func giftLinesAreInTheCatalogWithTheDate() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        var locales = Set<String>()
        for case let row as [String: Any] in strings.values {
            if let localizations = row["localizations"] as? [String: Any] {
                locales.formUnion(localizations.keys)
            }
        }

        let immediate = "A year of Pro is yours."
        let queued = "Your gift year of Pro starts on %@, after your current Pro period."
        for key in [immediate, queued] {
            let entry = try #require(strings[key] as? [String: Any], "\(key) is not in the catalog")
            #expect(entry["extractionState"] as? String != "stale", "\(key) is a stale entry")
            let translations = try #require(entry["localizations"] as? [String: Any], "\(key) has no translations")
            for locale in locales.sorted() {
                let translation = translations[locale] as? [String: Any]
                let value = (translation?["stringUnit"] as? [String: Any])?["value"] as? String
                #expect(value?.isEmpty == false, "\(key) has no \(locale)")
                if key == queued, let value {
                    #expect(value.contains("%@") || value.contains("%1$@"), "\(locale) drops the date: \(value)")
                }
            }
        }
    }

    /// Every flow that redeems reads the plan (a gift's Pro reaches the plan
    /// and the jwt from there) and hands the redeem to the confirmation.
    @Test func everyRedeemFlowReadsThePlanAndConfirms() throws {
        let network = Self.appRoot.appendingPathComponent("network")
        let files = try #require(FileManager.default.enumerator(at: network, includingPropertiesForKeys: nil))
        var flows: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let code = try Self.withoutComments(String(contentsOf: url, encoding: .utf8))
            let file = url.lastPathComponent
            var searchStart = code.startIndex
            while let call = code.range(of: "RedeemBalanceCodeSheet(", range: searchStart..<code.endIndex) {
                searchStart = call.upperBound
                flows.append(file)
                let onSuccess = try #require(Self.closureBody(after: "onSuccess:", in: code, from: call.upperBound), "\(file): no onSuccess")
                #expect(onSuccess.contains("fetchSubscriptionBalance()"), "\(file): onSuccess does not read the plan")
                #expect(onSuccess.contains("redeemedBalanceCode = redeemed"), "\(file): onSuccess does not hand the redeem to the confirmation")
                #expect(onSuccess.contains("balanceCodeRedeemed = true"), "\(file): onSuccess does not present the confirmation")
                #expect(code.contains("BalanceCodeRedeemedView(redeemed:"), "\(file): no confirmation")
            }
        }
        #expect(
            Set(flows).isSuperset(of: ["IntroductionView.swift", "AccountRootView.swift", "TransferBalanceCodesView.swift"]),
            "the scan saw \(flows)"
        )
    }

    /// The source without its comments, which may name what the code does not.
    private static func withoutComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
            }
            .map { line in
                line.range(of: " // ").map { String(line[..<$0.lowerBound]) } ?? String(line)
            }
            .joined(separator: "\n")
    }

    /// The body of the closure that follows the first `label` after `start`.
    private static func closureBody(after label: String, in code: String, from start: String.Index) -> String? {
        guard let labelRange = code.range(of: label, range: start..<code.endIndex),
              let open = code[labelRange.upperBound...].firstIndex(of: "{") else {
            return nil
        }
        var depth = 0
        var index = open
        while index < code.endIndex {
            switch code[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(code[code.index(after: open)..<index])
                }
            default:
                break
            }
            index = code.index(after: index)
        }
        return nil
    }
}
