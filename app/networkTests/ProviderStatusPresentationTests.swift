//
//  ProviderStatusPresentationTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * What the provider statistics show from the server's provider status
 * (P008): the "Demand" histogram model, the reason line merged with the local
 * idle reason, the "Why?" rows of every ranking number, and the states of the
 * chart area.
 */
struct ProviderStatusPresentationTests {

    private static let en = Locale(identifier: "en_US")

    private static func row(_ number: ProviderStatusNumber) -> ProviderStatusRow? {
        providerStatusRow(number, locale: en)
    }

    // MARK: the histogram

    @Test func theBarsAreTheCountsOverTheLargestCount() {
        var counts = [Int64](repeating: 0, count: 60)
        counts[0] = 2
        counts[30] = 8
        counts[59] = 4
        let histogram = ProviderDemandHistogram(counts: counts)
        #expect(histogram.fractions.count == 60)
        #expect(histogram.fractions[0] == 0.25)
        #expect(histogram.fractions[30] == 1)
        #expect(histogram.fractions[59] == 0.5)
        #expect(histogram.fractions.filter { $0 == 0 }.count == 57)
        #expect(histogram.total == 14)
        #expect(!histogram.isEmpty)
    }

    // a zero maximum scales by 1: no bars, and the empty state
    @Test func allZeroCountsAreEmpty() {
        let histogram = ProviderDemandHistogram(counts: [Int64](repeating: 0, count: 60))
        #expect(histogram.fractions == [Double](repeating: 0, count: 60))
        #expect(histogram.fractions.allSatisfy { $0.isFinite })
        #expect(histogram.total == 0)
        #expect(histogram.isEmpty)
    }

    @Test func oneAppearanceIsAFullBarAndNotEmpty() {
        var counts = [Int64](repeating: 0, count: 60)
        counts[12] = 1
        let histogram = ProviderDemandHistogram(counts: counts)
        #expect(histogram.fractions[12] == 1)
        #expect(histogram.total == 1)
        #expect(!histogram.isEmpty)
    }

    // exactly 60 bars, newest on the right, whatever length arrives
    @Test func thereAreAlwaysSixtyBarsWithTheNewestOnTheRight() {
        let short = ProviderDemandHistogram(counts: [1, 2])
        #expect(short.fractions.count == 60)
        #expect(Array(short.fractions.suffix(2)) == [0.5, 1])
        #expect(short.fractions.dropLast(2).allSatisfy { $0 == 0 })
        #expect(short.total == 3)

        let long = ProviderDemandHistogram(counts: [100] + [Int64](repeating: 1, count: 60))
        #expect(long.fractions == [Double](repeating: 1, count: 60))
        #expect(long.total == 60)

        let none = ProviderDemandHistogram(counts: [])
        #expect(none.fractions.count == 60)
        #expect(none.isEmpty)
    }

    @Test func negativeCountsAreZero() {
        let histogram = ProviderDemandHistogram(counts: [-5, 5])
        #expect(Array(histogram.fractions.suffix(2)) == [0, 1])
        #expect(histogram.total == 5)
    }

    @Test func theTotalIsAPluralOfTheStore() {
        let five = ProviderDemandHistogram(counts: [2, 3]).totalText
        #expect(five.key == "%lld times in the last hour")
        #expect(String(localized: five) == "5 times in the last hour")
        #expect(String(localized: ProviderDemandHistogram(counts: [1]).totalText) == "1 time in the last hour")
    }

    // MARK: the reason line

    // a local reason is immediate and wins over the cached server reason
    @Test func aLocalReasonWinsOverTheServer() {
        for reason in [ProviderIdleReason.autoNotConnected, .networkOnly, .pausedWifiOnly, .pausedNoNetwork] {
            #expect(providerStatusLine(idleReason: reason, serverReason: SdkProviderStatusReasonReliabilityLow, serverReasonText: "Reliability is low.") == .idle(reason))
            #expect(providerStatusLine(idleReason: reason, serverReason: "", serverReasonText: "") == .idle(reason))
            #expect(providerStatusLine(idleReason: reason, serverReason: SdkProviderStatusReasonNone, serverReasonText: "") == .idle(reason))
        }
    }

    @Test func theServerReasonWinsOverNoTrafficYet() {
        #expect(providerStatusLine(idleReason: .noTrafficYet, serverReason: SdkProviderStatusReasonReliabilityWarmingUp, serverReasonText: "Building reliability.") == .server(SdkProviderStatusReasonReliabilityWarmingUp))
        #expect(providerStatusLine(idleReason: .none, serverReason: SdkProviderStatusReasonEgressFailing, serverReasonText: "") == .server(SdkProviderStatusReasonEgressFailing))
    }

    // the server's none says nothing: no traffic yet when there is none
    @Test func theServerNoneSaysNothingOfItsOwn() {
        #expect(providerStatusLine(idleReason: .noTrafficYet, serverReason: SdkProviderStatusReasonNone, serverReasonText: "Everything checks out.") == .idle(.noTrafficYet))
        #expect(providerStatusLine(idleReason: .none, serverReason: SdkProviderStatusReasonNone, serverReasonText: "Everything checks out.") == nil)
    }

    // without a status the line is the local one alone
    @Test func withoutAStatusTheLineIsLocal() {
        #expect(providerStatusLine(idleReason: .noTrafficYet, serverReason: "", serverReasonText: "") == .idle(.noTrafficYet))
        #expect(providerStatusLine(idleReason: .none, serverReason: "", serverReasonText: "") == nil)
    }

    // a code this build does not know shows the server's English
    @Test func anUnknownCodeShowsTheServerText() {
        #expect(providerStatusLine(idleReason: .none, serverReason: "maintenance", serverReasonText: "Providing is paused for maintenance.") == .serverText("Providing is paused for maintenance."))
        #expect(providerStatusLine(idleReason: .noTrafficYet, serverReason: "maintenance", serverReasonText: "Providing is paused for maintenance.") == .serverText("Providing is paused for maintenance."))
        // and with no text there is nothing to show from the server
        #expect(providerStatusLine(idleReason: .noTrafficYet, serverReason: "maintenance", serverReasonText: "") == .idle(.noTrafficYet))
        #expect(providerStatusLine(idleReason: .none, serverReason: "maintenance", serverReasonText: "") == nil)
    }

    @Test func theReasonCodesAreTheSdkCodes() {
        #expect(SdkProviderStatusReasonNotProviding == "not_providing")
        #expect(SdkProviderStatusReasonNotConnected == "not_connected")
        #expect(SdkProviderStatusReasonLocationInvalid == "location_invalid")
        #expect(SdkProviderStatusReasonNetworkOnly == "network_only")
        #expect(SdkProviderStatusReasonReliabilityWarmingUp == "reliability_warming_up")
        #expect(SdkProviderStatusReasonReliabilityLow == "reliability_low")
        #expect(SdkProviderStatusReasonNotEligible == "not_eligible")
        #expect(SdkProviderStatusReasonEgressUnprobed == "egress_unprobed")
        #expect(SdkProviderStatusReasonEgressFailing == "egress_failing")
        #expect(SdkProviderStatusReasonSpeedTestMissing == "speed_test_missing")
        #expect(SdkProviderStatusReasonSlow == "slow")
        #expect(SdkProviderStatusReasonNone == "none")
    }

    private static let reasonEnglish: [String: String] = [
        "not_providing": "This device isn't set to share its connection.",
        "not_connected": "This device isn't connected right now. Clients are offered only connected devices.",
        "location_invalid": "This device is connecting from more than one address, or its location is unknown. Clients are offered only devices with one address and a known location.",
        "network_only": "This device provides only to your own devices. Choose Always to share with everyone.",
        "reliability_warming_up": "Building reliability. This device has been steady for the last hour; clients are offered it once its 12-hour reliability reaches the minimum, about 8 hours after a fresh start.",
        "reliability_low": "Reliability over the last hour is below what clients need. It rises with every minute this device stays connected; disconnects lower it.",
        "not_eligible": "This connection isn't eligible to provide right now.",
        "egress_unprobed": "The network check hasn't run on this connection yet. Until it passes, clients are offered this device only when checked providers run out.",
        "egress_failing": "Too many test sites failed to load through this connection in the last 8 hours. Clients are offered this device only when checked providers run out.",
        "speed_test_missing": "No speed test yet. Until one completes, clients are offered this device much less often.",
        "slow": "This connection measured slower than clients need, so it is offered much less often.",
        "none": "Everything checks out. How often clients are offered this device depends on demand in its region and on how it ranks against nearby providers.",
    ]

    // every code has its store text, and an unknown code has none
    @Test func everyReasonCodeHasTheStoreEnglish() {
        #expect(Self.reasonEnglish.count == 12)
        for (code, english) in Self.reasonEnglish {
            #expect(providerStatusReasonText(code)?.key == english, "\(code)")
        }
        #expect(providerStatusReasonText("maintenance") == nil)
        #expect(providerStatusReasonText("") == nil)
    }

    @Test(arguments: ["de", "es", "ru"])
    func everyReasonCodeIsTranslated(_ locale: String) throws {
        for code in Self.reasonEnglish.keys {
            var text = try #require(providerStatusReasonText(code))
            text.locale = Locale(identifier: locale)
            let translated = String(localized: text)
            #expect(!translated.isEmpty)
            #expect(translated != text.key, "\(locale) \(code)")
        }
    }

    // MARK: the rows

    @Test func theNumberNamesAreTheSdkNames() {
        #expect(SdkProviderStatusNumberReliability5m == "reliability_5m")
        #expect(SdkProviderStatusNumberReliability1h == "reliability_1h")
        #expect(SdkProviderStatusNumberReliability12h == "reliability_12h")
        #expect(SdkProviderStatusNumberUrlChecks == "url_checks")
        #expect(SdkProviderStatusNumberSpeedTest == "speed_test")
        #expect(SdkProviderStatusNumberLatency == "latency")
        #expect(SdkProviderStatusNumberWeightQuality == "weight_quality")
        #expect(SdkProviderStatusNumberWeightSpeed == "weight_speed")
        #expect(SdkProviderStatusNumberTierQuality == "tier_quality")
        #expect(SdkProviderStatusNumberTierSpeed == "tier_speed")
    }

    @Test func theFiveMinuteReliabilityIsAPercent() throws {
        let row = try #require(Self.row(ProviderStatusNumber(name: "reliability_5m", hasValue: true, value: 0.82, passes: true)))
        #expect(row.id == "reliability_5m")
        #expect(row.label.key == "Reliability, last 5 minutes")
        #expect(row.value == "82%")
        #expect(row.help.key == "How steadily this device stayed connected over the last 5 minutes. It scales how often clients are offered this device; staying connected raises it.")
        #expect(row.passes)

        let noHistory = try #require(Self.row(ProviderStatusNumber(name: "reliability_5m")))
        #expect(noHistory.value == "No history yet")
        #expect(noHistory.passes)
    }

    @Test func theLongerReliabilitiesShowTheirMinimum() throws {
        let hour = try #require(Self.row(ProviderStatusNumber(name: "reliability_1h", hasValue: true, value: 0.64, hasMinimum: true, minimum: 0.7, passes: false)))
        #expect(hour.label.key == "Reliability, last hour")
        #expect(hour.value == "64% (needs 70%)")
        #expect(hour.help.key == "How steadily this device stayed connected over the last hour. It must reach the minimum to be offered to clients; disconnects lower it and steady uptime raises it.")
        #expect(!hour.passes)

        let twelve = try #require(Self.row(ProviderStatusNumber(name: "reliability_12h", hasValue: true, value: 0.906, hasMinimum: true, minimum: 0.7, passes: true)))
        #expect(twelve.label.key == "Reliability, last 12 hours")
        #expect(twelve.value == "91% (needs 70%)")
        #expect(twelve.help.key == "How steadily this device stayed connected over the last 12 hours. It must reach the minimum to be offered to clients; from a fresh start this takes about 8 hours of steady uptime.")
        #expect(twelve.passes)

        let noHistory = try #require(Self.row(ProviderStatusNumber(name: "reliability_12h", hasMinimum: true, minimum: 0.7)))
        #expect(noHistory.value == "No history yet")

        // a minimum the server does not send is not shown
        let withoutMinimum = try #require(Self.row(ProviderStatusNumber(name: "reliability_1h", hasValue: true, value: 0.5)))
        #expect(withoutMinimum.value == "50%")
    }

    @Test func otherLookbacksAreReliability() throws {
        let row = try #require(Self.row(ProviderStatusNumber(name: "reliability_lookback_3", hasValue: true, value: 0.9, hasMinimum: true, minimum: 0.6, passes: true)))
        #expect(row.id == "reliability_lookback_3")
        #expect(row.label.key == "Reliability")
        #expect(row.value == "90% (needs 60%)")
        #expect(row.help.key == "How steadily this device stayed connected over a longer window. It must reach the minimum to be offered to clients.")
    }

    @Test func theNetworkChecksAreACountOfTheTotal() throws {
        let row = try #require(Self.row(ProviderStatusNumber(name: "url_checks", hasValue: true, value: 0.8, hasMinimum: true, minimum: 0.8, passes: true, count: 4, total: 5)))
        #expect(row.label.key == "Network checks")
        #expect(row.value == "4 of 5 loaded (needs 80%)")
        #expect(row.help.key == "Test sites that loaded through this connection in the last 8 hours. Most must load; filtering by your internet provider lowers it.")

        let notYet = try #require(Self.row(ProviderStatusNumber(name: "url_checks", hasMinimum: true, minimum: 0.8, passes: false)))
        #expect(notYet.value == "Not yet")
        #expect(!notYet.passes)
    }

    @Test func theSpeedTestIsAByteRate() throws {
        let row = try #require(Self.row(ProviderStatusNumber(name: "speed_test", hasValue: true, value: 1_258_291, hasMinimum: true, minimum: 524_288, passes: true)))
        #expect(row.label.key == "Speed test")
        #expect(row.value == "1.20 MiB/s (needs 512 KiB/s)")
        #expect(row.help.key == "Speed measured through this device. Faster connections are offered more often.")

        let notYet = try #require(Self.row(ProviderStatusNumber(name: "speed_test", hasMinimum: true, minimum: 524_288, passes: false)))
        #expect(notYet.value == "Not yet")
        #expect(!notYet.passes)
    }

    @Test func theDelayIsMillisecondsWithItsMaximum() throws {
        let row = try #require(Self.row(ProviderStatusNumber(name: "latency", hasValue: true, value: 35, hasMaximum: true, maximum: 150, passes: true)))
        #expect(row.label.key == "Delay")
        #expect(row.value == "35 ms (at most 150 ms)")
        #expect(row.help.key == "Delay measured above what is expected for this location. Lower delay is offered more often.")

        let notYet = try #require(Self.row(ProviderStatusNumber(name: "latency", hasMaximum: true, maximum: 150, passes: false)))
        #expect(notYet.value == "Not yet")
    }

    @Test func theWeightsHaveTwoDecimalsOrAreNotInThePool() throws {
        let quality = try #require(Self.row(ProviderStatusNumber(name: "weight_quality", hasValue: true, value: 0.4567, passes: true)))
        #expect(quality.label.key == "Selection weight (quality)")
        #expect(quality.value == "0.46")
        #expect(quality.help.key == "Combines reliability, speed and passed network checks. Clients are offered providers with a higher weight more often.")

        let speed = try #require(Self.row(ProviderStatusNumber(name: "weight_speed", hasValue: true, value: 0.2, passes: false)))
        #expect(speed.label.key == "Selection weight (speed)")
        #expect(speed.value == "Not in this pool")
        #expect(speed.help.key == quality.help.key)
        #expect(!speed.passes)
    }

    @Test func theTiersAreIntegers() throws {
        let quality = try #require(Self.row(ProviderStatusNumber(name: "tier_quality", hasValue: true, value: 0, hasMaximum: true, maximum: 2, passes: true)))
        #expect(quality.label.key == "Tier (quality)")
        #expect(quality.value == "0")
        #expect(quality.help.key == "Clients try lower tiers first. 0 is best; 3 means past the speed or delay cutoff.")

        let speed = try #require(Self.row(ProviderStatusNumber(name: "tier_speed", hasValue: true, value: 3, hasMaximum: true, maximum: 2, passes: false)))
        #expect(speed.label.key == "Tier (speed)")
        #expect(speed.value == "3")
        #expect(!speed.passes)
    }

    // whatever this build does not know is skipped, never inferred
    @Test func unknownNamesAreSkipped() {
        for name in ["", "arin_risk", "blackhole", "reliability_7d", "weight_quality_v2"] {
            #expect(Self.row(ProviderStatusNumber(name: name, hasValue: true, value: 1, passes: true)) == nil, "\(name)")
        }
    }

    @Test func theCountryRowFallsBackToTheCode() throws {
        let named = try #require(providerStatusCountryRow(ProviderStatusCountry(country: "Germany", countryCode: "de")))
        #expect(named.label.key == "Country")
        #expect(named.value == "Germany")
        #expect(named.help.key == "Clients who choose this country can be offered this device.")
        #expect(named.passes)
        #expect(providerStatusCountryRow(ProviderStatusCountry(country: "", countryCode: "de"))?.value == "DE")
        #expect(providerStatusCountryRow(ProviderStatusCountry(country: "", countryCode: "")) == nil)
    }

    // in server order, unknown names out, then the country
    @Test func theRowsKeepTheServerOrderThenTheCountry() {
        let numbers = [
            ProviderStatusNumber(name: "url_checks"),
            ProviderStatusNumber(name: "arin_risk", hasValue: true, value: 1),
            ProviderStatusNumber(name: "reliability_5m"),
            ProviderStatusNumber(name: "tier_speed", hasValue: true, value: 1),
        ]
        let rows = providerStatusRows(numbers: numbers, country: ProviderStatusCountry(country: "Japan", countryCode: "jp"), locale: Self.en)
        #expect(rows.map(\.id) == ["url_checks", "reliability_5m", "tier_speed", "country"])
        #expect(providerStatusRows(numbers: numbers, country: nil, locale: Self.en).map(\.id) == ["url_checks", "reliability_5m", "tier_speed"])
        #expect(providerStatusRows(numbers: [], country: nil).isEmpty)
    }

    @Test(arguments: ["de", "es", "ru"])
    func theRowTextsAreTranslated(_ locale: String) throws {
        let names = [
            "reliability_5m", "reliability_1h", "reliability_12h", "reliability_lookback_3", "url_checks",
            "speed_test", "latency", "weight_quality", "weight_speed", "tier_quality", "tier_speed",
        ]
        var texts: [LocalizedStringResource] = []
        for name in names {
            let row = try #require(Self.row(ProviderStatusNumber(name: name, hasValue: true, value: 1, passes: true)))
            texts += [row.label, row.help]
        }
        let country = try #require(providerStatusCountryRow(ProviderStatusCountry(country: "Japan", countryCode: "jp")))
        texts += [country.label, country.help]
        for var text in texts {
            text.locale = Locale(identifier: locale)
            #expect(String(localized: text) != text.key, "\(locale) \(text.key)")
        }
    }

    @Test func thePercentIsAWholeLocalePercent() {
        #expect(providerStatusPercent(0.82, locale: Self.en) == "82%")
        #expect(providerStatusPercent(0.825, locale: Self.en) == "82%" || providerStatusPercent(0.825, locale: Self.en) == "83%")
        #expect(providerStatusPercent(1, locale: Self.en) == "100%")
        #expect(providerStatusPercent(0, locale: Self.en) == "0%")
        #expect(providerStatusPercent(0.82, locale: Locale(identifier: "de_DE")).hasPrefix("82"))
    }

    // MARK: the states

    @Test func beforeTheFirstPollTheChartIsLoading() {
        let presentation = providerStatusPresentation(isLoaded: false, lastFetchError: "", hasStatus: false, appearancesPerMinute: nil)
        #expect(presentation == ProviderStatusPresentation(area: .loading, showsWhy: false))
    }

    // for example 404 before the server route is deployed
    @Test func aFailedFirstPollIsUnavailable() {
        let presentation = providerStatusPresentation(isLoaded: false, lastFetchError: "404 Not Found", hasStatus: false, appearancesPerMinute: nil)
        #expect(presentation == ProviderStatusPresentation(area: .unavailable, showsWhy: false))
    }

    @Test func withoutThisDeviceTheAreaIsHidden() {
        let presentation = providerStatusPresentation(isLoaded: true, lastFetchError: "", hasStatus: false, appearancesPerMinute: nil)
        #expect(presentation == ProviderStatusPresentation(area: .hidden, showsWhy: false))
    }

    @Test func aStatusWithoutAHistogramIsUnavailableWithWhy() {
        let presentation = providerStatusPresentation(isLoaded: true, lastFetchError: "", hasStatus: true, appearancesPerMinute: nil)
        #expect(presentation == ProviderStatusPresentation(area: .unavailable, showsWhy: true))
    }

    @Test func anAllZeroHistogramIsTheEmptyState() {
        let zeros = [Int64](repeating: 0, count: 60)
        let presentation = providerStatusPresentation(isLoaded: true, lastFetchError: "", hasStatus: true, appearancesPerMinute: zeros)
        #expect(presentation == ProviderStatusPresentation(area: .histogram(ProviderDemandHistogram(counts: zeros)), showsWhy: true))
        guard case .histogram(let histogram) = presentation.area else {
            Issue.record("no histogram")
            return
        }
        #expect(histogram.isEmpty)
    }

    @Test func aLoadedHistogramShowsTheBarsAndWhy() {
        var counts = [Int64](repeating: 0, count: 60)
        counts[59] = 3
        let presentation = providerStatusPresentation(isLoaded: true, lastFetchError: "", hasStatus: true, appearancesPerMinute: counts)
        #expect(presentation.showsWhy)
        guard case .histogram(let histogram) = presentation.area else {
            Issue.record("no histogram")
            return
        }
        #expect(!histogram.isEmpty)
        #expect(histogram.total == 3)
    }

    // a later failed poll keeps the last snapshot (the controller stays loaded)
    @Test func aLaterFailedPollKeepsTheLastAnswer() {
        let presentation = providerStatusPresentation(isLoaded: true, lastFetchError: "timeout", hasStatus: true, appearancesPerMinute: [1])
        #expect(presentation.showsWhy)
        guard case .histogram = presentation.area else {
            Issue.record("no histogram")
            return
        }
    }
}
