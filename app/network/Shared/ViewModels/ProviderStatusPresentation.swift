//
//  ProviderStatusPresentation.swift
//  URnetwork
//
//  What the provider statistics show from the server's provider status
//  (P008): the reason line merged with the local idle reason, the "Demand"
//  histogram of how often clients were offered this device per minute over
//  the last hour, and the rows of the "Why?" panel. Kept pure so it is unit
//  testable; ProviderStatusStore reads the sdk controller into a snapshot.
//

import Foundation
import URnetworkSdk

// MARK: the reason line

/// The line under the provide mode row.
enum ProviderStatusLine: Equatable {
    /// a local reason (ProviderIdleReason.text)
    case idle(ProviderIdleReason)
    /// a server reason code this build knows (providerStatusReasonText)
    case server(String)
    /// a server reason code this build does not know: the server's English
    /// text, which keeps the line forward compatible
    case serverText(String)
}

/// The line under the provide mode row. Local state wins because it is
/// immediate: the server's ranking is cached for about 5 minutes, so right
/// after a mode change it can still say network_only. The server's `none`
/// says nothing, and no traffic yet is said only when the server has nothing
/// more specific.
///
/// - Parameters:
///   - serverReason: the controller's reason code, "" without a status
///   - serverReasonText: the server's English text for it
func providerStatusLine(
    idleReason: ProviderIdleReason,
    serverReason: String,
    serverReasonText: String
) -> ProviderStatusLine? {
    switch idleReason {
    case .autoNotConnected, .networkOnly, .pausedWifiOnly, .pausedNoNetwork, .pausedLowPower, .pausedNotCharging:
        return .idle(idleReason)
    case .none, .noTrafficYet:
        break
    }
    if !serverReason.isEmpty && serverReason != SdkProviderStatusReasonNone {
        if providerStatusReasonText(serverReason) != nil {
            return .server(serverReason)
        }
        if !serverReasonText.isEmpty {
            return .serverText(serverReasonText)
        }
    }
    if idleReason == .noTrafficYet {
        return .idle(.noTrafficYet)
    }
    return nil
}

/// The text of a server reason code (localizations
/// `provider_status_reason_<code>`), nil for a code this build does not know.
func providerStatusReasonText(_ reason: String) -> LocalizedStringResource? {
    switch reason {
    case SdkProviderStatusReasonNotProviding:
        return "This device isn't set to share its connection."
    case SdkProviderStatusReasonNotConnected:
        return "This device isn't connected right now. Clients are offered only connected devices."
    case SdkProviderStatusReasonLocationInvalid:
        return "This device is connecting from more than one address, or its location is unknown. Clients are offered only devices with one address and a known location."
    case SdkProviderStatusReasonNetworkOnly:
        return "This device provides only to your own devices. Choose Always to share with everyone."
    case SdkProviderStatusReasonReliabilityWarmingUp:
        return "Building reliability. This device has been steady for the last hour; clients are offered it once its 12-hour reliability reaches the minimum, about 8 hours after a fresh start."
    case SdkProviderStatusReasonReliabilityLow:
        return "Reliability over the last hour is below what clients need. It rises with every minute this device stays connected; disconnects lower it."
    case SdkProviderStatusReasonNotEligible:
        return "This connection isn't eligible to provide right now."
    case SdkProviderStatusReasonEgressUnprobed:
        return "The network check hasn't run on this connection yet. Until it passes, clients are offered this device only when checked providers run out."
    case SdkProviderStatusReasonEgressFailing:
        return "Too many test sites failed to load through this connection in the last 8 hours. Clients are offered this device only when checked providers run out."
    case SdkProviderStatusReasonSpeedTestMissing:
        return "No speed test yet. Until one completes, clients are offered this device much less often."
    case SdkProviderStatusReasonSlow:
        return "This connection measured slower than clients need, so it is offered much less often."
    case SdkProviderStatusReasonNone:
        return "Everything checks out. How often clients are offered this device depends on demand in its region and on how it ranks against nearby providers."
    default:
        return nil
    }
}

// MARK: the histogram

/// The "Demand" chart: how often clients were offered this device per
/// minute over the last hour, oldest first. The last bar is the current,
/// partial minute.
struct ProviderDemandHistogram: Equatable {

    static let barCount = 60

    /// exactly `barCount` bar heights as a fraction of the chart height
    let fractions: [Double]
    let total: Int64
    /// every count is 0: the chart keeps its baseline and axis and says so
    let isEmpty: Bool

    /// - Parameter counts: the appearances per minute, oldest first. A list
    ///   that is not 60 long keeps its newest 60, padded with zeros on the
    ///   oldest side.
    init(counts: [Int64]) {
        var bars = Array(counts.suffix(Self.barCount)).map { max($0, 0) }
        if bars.count < Self.barCount {
            bars = Array(repeating: 0, count: Self.barCount - bars.count) + bars
        }
        // a zero maximum scales by 1, so an empty chart has no bars
        let scale = Double(max(bars.max() ?? 0, 1))
        fractions = bars.map { Double($0) / scale }
        total = bars.reduce(0, +)
        isEmpty = bars.allSatisfy { $0 == 0 }
    }

    /// "{count} times in the last hour", in the title row
    var totalText: LocalizedStringResource {
        "\(Int(total)) times in the last hour"
    }
}

// MARK: the states

/// What the chart area shows.
enum ProviderDemandArea: Equatable {
    /// before the first successful poll
    case loading
    /// no poll has succeeded and the last one failed (for example a server
    /// without the route), or the status has no histogram
    case unavailable
    /// the network's provider clients do not include this device
    case hidden
    /// the bars and their total, or the empty state
    case histogram(ProviderDemandHistogram)
}

struct ProviderStatusPresentation: Equatable {
    let area: ProviderDemandArea
    /// the expandable "Why?" with the ranking numbers
    let showsWhy: Bool
}

/// The chart area and the "Why?" panel from the controller state. The reason
/// line follows from the reason code alone, which is "" without a status.
///
/// - Parameter appearancesPerMinute: the status's histogram, nil without one
func providerStatusPresentation(
    isLoaded: Bool,
    lastFetchError: String,
    hasStatus: Bool,
    appearancesPerMinute: [Int64]?
) -> ProviderStatusPresentation {
    guard isLoaded else {
        return ProviderStatusPresentation(
            area: lastFetchError.isEmpty ? .loading : .unavailable,
            showsWhy: false
        )
    }
    guard hasStatus else {
        return ProviderStatusPresentation(area: .hidden, showsWhy: false)
    }
    guard let appearancesPerMinute else {
        return ProviderStatusPresentation(area: .unavailable, showsWhy: true)
    }
    return ProviderStatusPresentation(
        area: .histogram(ProviderDemandHistogram(counts: appearancesPerMinute)),
        showsWhy: true
    )
}

// MARK: the "Why?" rows

/// One number the provider search admits or ranks this device by, a mirror
/// of the sdk's `ProviderRankingNumber`. The unit follows the name:
/// reliability_* a share of steady uptime (0 to 1), url_checks a share of
/// loaded test sites with count of total, speed_test bytes per second,
/// latency milliseconds above the expected delay, weight_* a relative weight,
/// tier_* a tier (0 best).
struct ProviderStatusNumber: Equatable {
    var name: String
    var hasValue: Bool = false
    var value: Double = 0
    var hasMinimum: Bool = false
    var minimum: Double = 0
    var hasMaximum: Bool = false
    var maximum: Double = 0
    var passes: Bool = true
    var count: Int = 0
    var total: Int = 0
}

/// Where clients find this device.
struct ProviderStatusCountry: Equatable {
    var country: String
    var countryCode: String
}

/// One row of the "Why?" panel: a label, a value (amber when it does not
/// pass) and a muted help line under it.
struct ProviderStatusRow: Identifiable {
    let id: String
    let label: LocalizedStringResource
    let value: String
    let help: LocalizedStringResource
    let passes: Bool
}

private let reliabilityLookbackPrefix = "reliability_lookback_"

/// The row of a number, nil for a name this build does not know. Rows are
/// shown in the server's order; whatever arrives is rendered, nothing is
/// inferred.
func providerStatusRow(
    _ number: ProviderStatusNumber,
    locale: Locale = .current
) -> ProviderStatusRow? {
    let label: LocalizedStringResource
    let help: LocalizedStringResource
    let value: String

    switch number.name {
    case SdkProviderStatusNumberReliability5m:
        label = "Reliability, last 5 minutes"
        help = "How steadily this device stayed connected over the last 5 minutes. It scales how often clients are offered this device; staying connected raises it."
        value = number.hasValue
            ? providerStatusPercent(number.value, locale: locale)
            : String(localized: "No history yet")
    case SdkProviderStatusNumberReliability1h:
        label = "Reliability, last hour"
        help = "How steadily this device stayed connected over the last hour. It must reach the minimum to be offered to clients; disconnects lower it and steady uptime raises it."
        value = providerStatusReliabilityValue(number, locale: locale)
    case SdkProviderStatusNumberReliability12h:
        label = "Reliability, last 12 hours"
        help = "How steadily this device stayed connected over the last 12 hours. It must reach the minimum to be offered to clients; from a fresh start this takes about 8 hours of steady uptime."
        value = providerStatusReliabilityValue(number, locale: locale)
    case let name where name.hasPrefix(reliabilityLookbackPrefix):
        label = "Reliability"
        help = "How steadily this device stayed connected over a longer window. It must reach the minimum to be offered to clients."
        value = providerStatusReliabilityValue(number, locale: locale)
    case SdkProviderStatusNumberUrlChecks:
        label = "Network checks"
        help = "Test sites that loaded through this connection in the last 8 hours. Most must load; filtering by your internet provider lowers it."
        if number.hasValue {
            let loaded = String(localized: "\(number.count) of \(number.total) loaded")
            value = providerStatusWithMinimum(
                loaded,
                number.hasMinimum ? providerStatusPercent(number.minimum, locale: locale) : nil
            )
        } else {
            value = String(localized: "Not yet")
        }
    case SdkProviderStatusNumberSpeedTest:
        label = "Speed test"
        help = "Speed measured through this device. Faster connections are offered more often."
        if number.hasValue {
            value = providerStatusWithMinimum(
                formatByteRate(Int64(number.value.rounded())),
                number.hasMinimum ? formatByteRate(Int64(number.minimum.rounded())) : nil
            )
        } else {
            value = String(localized: "Not yet")
        }
    case SdkProviderStatusNumberLatency:
        label = "Delay"
        help = "Delay measured above what is expected for this location. Lower delay is offered more often."
        if number.hasValue {
            let delay = providerStatusMillis(number.value)
            if number.hasMaximum {
                let maximum = providerStatusMillis(number.maximum)
                value = String(localized: "\(delay) (at most \(maximum))")
            } else {
                value = delay
            }
        } else {
            value = String(localized: "Not yet")
        }
    case SdkProviderStatusNumberWeightQuality:
        label = "Selection weight (quality)"
        help = "Combines reliability, speed and passed network checks. Clients are offered providers with a higher weight more often."
        value = providerStatusWeightValue(number, locale: locale)
    case SdkProviderStatusNumberWeightSpeed:
        label = "Selection weight (speed)"
        help = "Combines reliability, speed and passed network checks. Clients are offered providers with a higher weight more often."
        value = providerStatusWeightValue(number, locale: locale)
    case SdkProviderStatusNumberTierQuality:
        label = "Tier (quality)"
        help = "Clients try lower tiers first. 0 is best; 3 means past the speed or delay cutoff."
        value = "\(Int(number.value.rounded()))"
    case SdkProviderStatusNumberTierSpeed:
        label = "Tier (speed)"
        help = "Clients try lower tiers first. 0 is best; 3 means past the speed or delay cutoff."
        value = "\(Int(number.value.rounded()))"
    default:
        return nil
    }

    return ProviderStatusRow(
        id: number.name,
        label: label,
        value: value,
        help: help,
        passes: number.passes
    )
}

/// The country row after the numbers, nil without a country.
func providerStatusCountryRow(_ country: ProviderStatusCountry) -> ProviderStatusRow? {
    let value = country.country.isEmpty ? country.countryCode.uppercased() : country.country
    guard !value.isEmpty else {
        return nil
    }
    return ProviderStatusRow(
        id: "country",
        label: "Country",
        value: value,
        help: "Clients who choose this country can be offered this device.",
        passes: true
    )
}

/// Every row of the "Why?" panel: the numbers in server order, then the
/// country.
func providerStatusRows(
    numbers: [ProviderStatusNumber],
    country: ProviderStatusCountry?,
    locale: Locale = .current
) -> [ProviderStatusRow] {
    var rows = numbers.compactMap { providerStatusRow($0, locale: locale) }
    if let country, let row = providerStatusCountryRow(country) {
        rows.append(row)
    }
    return rows
}

/// A 0-1 ratio as a whole percent, "82%".
func providerStatusPercent(_ ratio: Double, locale: Locale = .current) -> String {
    ratio.formatted(.percent.precision(.fractionLength(0)).locale(locale))
}

/// "35 ms". Not localized: the store has no key for it.
private func providerStatusMillis(_ millis: Double) -> String {
    "\(Int(millis.rounded())) ms"
}

/// "{value} (needs {minimum})", or the value alone without a minimum.
private func providerStatusWithMinimum(_ value: String, _ minimum: String?) -> String {
    guard let minimum else {
        return value
    }
    return String(localized: "\(value) (needs \(minimum))")
}

/// A reliability number with its minimum, or no history.
private func providerStatusReliabilityValue(_ number: ProviderStatusNumber, locale: Locale) -> String {
    guard number.hasValue else {
        return String(localized: "No history yet")
    }
    return providerStatusWithMinimum(
        providerStatusPercent(number.value, locale: locale),
        number.hasMinimum ? providerStatusPercent(number.minimum, locale: locale) : nil
    )
}

/// A selection weight with 2 decimals, or not in this pool when the device is
/// outside the mode's pool.
private func providerStatusWeightValue(_ number: ProviderStatusNumber, locale: Locale) -> String {
    guard number.passes else {
        return String(localized: "Not in this pool")
    }
    return number.value.formatted(.number.precision(.fractionLength(2)).locale(locale))
}
