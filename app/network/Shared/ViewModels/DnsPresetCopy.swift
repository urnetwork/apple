//
//  DnsPresetCopy.swift
//  URnetwork
//

import Foundation

/**
 * The words of the dns screen's provider picker (connect ADBLOCK3RD.md F1,
 * G1). The sdk decides what the screen shows and hands it localization key
 * ids (`GetDnsPicks`, `DescribeDnsResolverSettings`,
 * `DescribeDnsResolverStatus`, `ValidateDnsPresetPersonalId`); each id maps
 * here to its message.
 *
 * Apple keys a string by its English text, so every message is the
 * localizations store's `source` exactly: its English with `%@` for a String
 * argument and `%lld` for an Int, in order. Change a message only together
 * with the store. A provider's name, operator and jurisdiction are never
 * translated (G2): they reach a message only as its argument.
 *
 * Only words live here. Which line shows, for which provider, is the sdk's
 * (app logic lives in the sdk, owner 2026-11-03). An id this build does not
 * know shows nothing rather than the id.
 */

/// The key ids the sdk returns for the dns screen (sdk dns_presets_ui.go).
/// Each is also the localization key id of its message.
enum DnsPresetKey {
    // the picker's group headings (DnsPick.GroupKey)
    static let groupBlockAds = "block_ads_and_trackers"
    static let groupBlockMalware = "dns_group_block_malware"
    static let groupFamily = "dns_group_family"
    static let groupMyAccount = "dns_group_my_account"
    static let groupNoFiltering = "dns_group_no_filtering"

    // the labels of the picks that are not presets (DnsPick.LabelKey)
    static let providerDefault = "dns_provider_default"
    static let providerCustom = "dns_provider_custom"
    static let providerRegional = "dns_provider_regional"

    // the line under a pick (DnsPick.CopyKey)
    static let providerDefaultCopy = "dns_provider_default_copy"
    static let providerCustomCopy = "dns_provider_custom_copy"
    static let providerRegionalCopy = "dns_recommendation_message"
    static let presetCopyAdsPhishing = "dns_preset_copy_ads_phishing"
    static let presetCopyAdsMalware = "dns_preset_copy_ads_malware"
    static let presetCopyAdsMalwarePhishing = "dns_preset_copy_ads_malware_phishing"
    static let presetCopyMalware = "dns_preset_copy_malware"
    static let presetCopyMalwarePhishing = "dns_preset_copy_malware_phishing"
    static let presetCopyAdsAdultSafeSearch = "dns_preset_copy_ads_adult_safe_search"
    static let presetCopyMalwareAdult = "dns_preset_copy_malware_adult"
    static let presetCopyAdsMalwareAdultDrugs = "dns_preset_copy_ads_malware_adult_drugs"
    static let presetCopyChild = "dns_preset_copy_child"
    static let presetCopyChildAds = "dns_preset_copy_child_ads"
    static let presetCopyNothing = "dns_preset_copy_nothing"
    static let presetCopyCourtOrders = "dns_preset_copy_court_orders"
    static let presetCopyPersonal = "dns_preset_copy_personal"

    // the summary row (DnsSelectionSummary.SummaryKey)
    static let summaryDefault = "dns_summary_default"
    static let summaryAdBlocking = "dns_summary_ad_blocking"
    static let summaryMalwareBlocking = "dns_summary_malware_blocking"
    static let summaryFamily = "dns_summary_family"
    static let summaryNoFiltering = "dns_summary_no_filtering"
    static let summaryPersonal = "dns_summary_personal"
    static let summaryCustom = "dns_summary_custom"
    static let summaryCustomUnencrypted = "dns_summary_custom_unencrypted"
    static let summaryRegional = "dns_summary_regional"

    // the pill over the summary (DnsSelectionSummary.PillKey)
    static let pillRecommended = "dns_pill_recommended"
    static let pillDefaults = "dns_pill_defaults"

    // the status line and the line under it (DnsStatusSummary.StatusKey,
    // StatusDetailKey)
    static let statusProvider = "dns_status_provider"
    static let statusPaused = "dns_status_paused"
    static let statusFallback = "dns_status_fallback"
    static let statusUnreachable = "dns_status_unreachable"
    static let statusPausedDetail = "dns_status_paused_detail"
    static let statusUnreachableDetail = "dns_status_unreachable_detail"

    // the verification line and its link (DnsStatusSummary.VerificationKey,
    // VerificationLinkKey)
    static let verifyNotFiltering = "dns_verify_not_filtering"
    static let verifyUnconfirmed = "dns_verify_unconfirmed"
    static let verifyRejected = "dns_verify_rejected_controld"
    static let verifyMalformed = "dns_verify_malformed_adguard"
    static let personalIdDashboardLink = "dns_personal_id_dashboard_link"

    // the personal id field (DnsPreset.PersonalIdWhereKey,
    // PersonalIdFormatKey, QuotaNoteKey)
    static let personalIdWhereNextDns = "dns_personal_id_where_nextdns"
    static let personalIdWhereControlD = "dns_personal_id_where_controld"
    static let personalIdWhereAdGuard = "dns_personal_id_where_adguard"
    static let personalIdFormatNextDns = "dns_personal_id_format_nextdns"
    static let personalIdFormatControlD = "dns_personal_id_format_controld"
    static let personalIdFormatAdGuard = "dns_personal_id_format_adguard"
    static let personalIdQuotaNextDns = "dns_personal_id_quota_nextdns"
    static let personalIdQuotaAdGuard = "dns_personal_id_quota_adguard"

    // the personal id's errors (ValidateDnsPresetPersonalId, the sdk's
    // DnsPresetError*)
    static let errorUnknown = "dns_preset_error_unknown"
    static let errorPersonalIdRequired = "dns_preset_error_personal_id_required"
    static let errorPersonalIdInvalid = "dns_preset_error_personal_id_invalid"
    static let errorPersonalIdOtherProvider = "dns_preset_error_personal_id_other_provider"
    static let errorPersonalIdNotAccepted = "dns_preset_error_personal_id_not_accepted"
}

/// The help page of the dns providers on ur.io, behind "Learn more". The
/// app links ur.io in English (as ApiKeysLinks.docs); the page's anchors are
/// the same in every language.
enum DnsProvidersHelp {
    static let url = URL(string: "https://ur.io/docs/faq#dns-providers")!
    /// where each provider shows a personal id, and the block response to keep
    static let personalIdsUrl = URL(string: "https://ur.io/docs/faq#dns-personal-ids")!
}

/// A group heading of the picker (DnsPick.GroupKey).
func dnsGroupHeading(_ groupKey: String) -> LocalizedStringResource? {
    switch groupKey {
    case DnsPresetKey.groupBlockAds:
        return "Block ads and trackers"
    case DnsPresetKey.groupBlockMalware:
        return "Block malware"
    case DnsPresetKey.groupFamily:
        return "Family"
    case DnsPresetKey.groupMyAccount:
        return "Use my account"
    case DnsPresetKey.groupNoFiltering:
        return "No filtering"
    default:
        return nil
    }
}

/// The label of a pick that is not a preset (DnsPick.LabelKey). A preset
/// pick shows its provider's name instead. `country` names a regional pick's
/// country.
func dnsPickLabel(_ labelKey: String, country: String) -> LocalizedStringResource? {
    switch labelKey {
    case DnsPresetKey.providerDefault:
        return "URnetwork (default)"
    case DnsPresetKey.providerCustom:
        return "Custom"
    case DnsPresetKey.providerRegional:
        return "Regional (\(country)), unencrypted"
    default:
        return nil
    }
}

/// The line under a pick (DnsPick.CopyKey): what a preset blocks, or what
/// the default, custom and regional picks are. `provider` is a personal
/// preset's provider, `country` a regional pick's country.
func dnsPickCopy(_ copyKey: String, provider: String, country: String) -> LocalizedStringResource? {
    switch copyKey {
    case DnsPresetKey.providerDefaultCopy:
        return "Encrypted DNS through the tunnel, with no filtering"
    case DnsPresetKey.providerCustomCopy:
        return "Your own DNS over HTTPS URLs and DNS servers"
    case DnsPresetKey.providerRegionalCopy:
        return "The strongest security rules are known not to work in \(country). There are less secure recommended DNS settings that work better."
    case DnsPresetKey.presetCopyAdsPhishing:
        return "Blocks ads, trackers and phishing"
    case DnsPresetKey.presetCopyAdsMalware:
        return "Blocks ads, trackers and malware"
    case DnsPresetKey.presetCopyAdsMalwarePhishing:
        return "Blocks ads, trackers, malware and phishing"
    case DnsPresetKey.presetCopyMalware:
        return "Blocks malware, not ads"
    case DnsPresetKey.presetCopyMalwarePhishing:
        return "Blocks malware and phishing, not ads"
    case DnsPresetKey.presetCopyAdsAdultSafeSearch:
        return "Blocks ads, trackers and adult sites, and turns on safe search"
    case DnsPresetKey.presetCopyMalwareAdult:
        return "Blocks malware and adult sites, not ads"
    case DnsPresetKey.presetCopyAdsMalwareAdultDrugs:
        return "Blocks ads, trackers, malware, adult sites and drugs"
    case DnsPresetKey.presetCopyChild:
        return "Blocks malware, adult sites, gambling, drugs and violence, not ads"
    case DnsPresetKey.presetCopyChildAds:
        return "Blocks ads, trackers, malware, adult sites, gambling, drugs and violence"
    case DnsPresetKey.presetCopyNothing:
        return "Blocks nothing"
    case DnsPresetKey.presetCopyCourtOrders:
        return "Blocks only what courts order it to block"
    case DnsPresetKey.presetCopyPersonal:
        return "Uses the filters you set up in your \(provider) account"
    default:
        return nil
    }
}

/// The summary row of the settings in force (DnsSelectionSummary.SummaryKey),
/// with the selected preset's provider.
func dnsSummaryText(_ summaryKey: String, provider: String) -> LocalizedStringResource? {
    switch summaryKey {
    case DnsPresetKey.summaryDefault:
        return "DNS: URnetwork"
    case DnsPresetKey.summaryAdBlocking:
        return "DNS: \(provider) · Ad blocking"
    case DnsPresetKey.summaryMalwareBlocking:
        return "DNS: \(provider) · Malware blocking"
    case DnsPresetKey.summaryFamily:
        return "DNS: \(provider) · Family filter"
    case DnsPresetKey.summaryNoFiltering:
        return "DNS: \(provider) · No filtering"
    case DnsPresetKey.summaryPersonal:
        return "DNS: \(provider) · your profile"
    case DnsPresetKey.summaryCustom:
        return "DNS: Custom"
    case DnsPresetKey.summaryCustomUnencrypted:
        return "DNS: Custom (unencrypted)"
    case DnsPresetKey.summaryRegional:
        return "DNS: Regional (unencrypted)"
    default:
        return nil
    }
}

/// The pill over the summary (DnsSelectionSummary.PillKey). `country` names
/// the exit's country, for the recommendation. These are the texts the pill
/// showed before the sdk chose it.
func dnsPillText(_ pillKey: String, country: String) -> LocalizedStringResource? {
    switch pillKey {
    case DnsPresetKey.pillRecommended:
        return "There are unapplied recommended settings for \(country)"
    case DnsPresetKey.pillDefaults:
        return "The default safe settings are not applied"
    default:
        return nil
    }
}

/// The status line of the selected preset (DnsStatusSummary.StatusKey).
func dnsStatusText(_ statusKey: String, provider: String) -> LocalizedStringResource? {
    switch statusKey {
    case DnsPresetKey.statusProvider:
        return "DNS: \(provider)"
    case DnsPresetKey.statusPaused:
        return "Ad blocking paused: \(provider) isn't answering"
    case DnsPresetKey.statusFallback:
        return "\(provider) isn't answering. Using URnetwork DNS."
    case DnsPresetKey.statusUnreachable:
        return "\(provider) isn't answering"
    default:
        return nil
    }
}

/// The line under the status line (DnsStatusSummary.StatusDetailKey).
func dnsStatusDetailText(_ statusDetailKey: String) -> LocalizedStringResource? {
    switch statusDetailKey {
    case DnsPresetKey.statusPausedDetail:
        return "Using URnetwork DNS until it answers. Ad blocking comes back on its own."
    case DnsPresetKey.statusUnreachableDetail:
        return "To keep filtering on, URnetwork doesn't switch DNS for you. Sites may not load until it answers."
    default:
        return nil
    }
}

/// What verification found out about the selected preset
/// (DnsStatusSummary.VerificationKey).
func dnsVerificationText(_ verificationKey: String, provider: String) -> LocalizedStringResource? {
    switch verificationKey {
    case DnsPresetKey.verifyNotFiltering:
        return "\(provider) isn't filtering from this location"
    case DnsPresetKey.verifyUnconfirmed:
        return "Saved, but we can't confirm this profile. If the ID is wrong, \(provider) answers without filtering."
    case DnsPresetKey.verifyRejected:
        return "\(provider) doesn't recognize this resolver ID"
    case DnsPresetKey.verifyMalformed:
        return "\(provider) rejected this device ID"
    default:
        return nil
    }
}

/// The link to the provider's dashboard (DnsStatusSummary.VerificationLinkKey).
/// The personal id field shows the same link.
func dnsDashboardLinkText(_ linkKey: String, provider: String) -> LocalizedStringResource? {
    switch linkKey {
    case DnsPresetKey.personalIdDashboardLink:
        return "Open your \(provider) dashboard"
    default:
        return nil
    }
}

/// Where the provider shows the personal id (DnsPreset.PersonalIdWhereKey).
func dnsPersonalIdWhereText(_ whereKey: String, provider: String) -> LocalizedStringResource? {
    switch whereKey {
    case DnsPresetKey.personalIdWhereNextDns:
        return "Find it on the Setup page of your \(provider) account."
    case DnsPresetKey.personalIdWhereControlD:
        return "In your \(provider) dashboard, choose Show Resolvers on your endpoint."
    case DnsPresetKey.personalIdWhereAdGuard:
        return "Find it on your device's page in your \(provider) dashboard."
    default:
        return nil
    }
}

/// The provider's id format (DnsPreset.PersonalIdFormatKey), shown with the
/// invalid id error. `example` is the provider's own example of an id.
func dnsPersonalIdFormatText(_ formatKey: String, provider: String, example: String) -> LocalizedStringResource? {
    switch formatKey {
    case DnsPresetKey.personalIdFormatNextDns:
        return "\(provider) IDs are 6 characters: digits and the letters a to f, like \(example)."
    case DnsPresetKey.personalIdFormatControlD:
        return "\(provider) resolver IDs use only letters and digits, like \(example)."
    case DnsPresetKey.personalIdFormatAdGuard:
        return "\(provider) device IDs are 8 characters: digits and the letters a to f, like \(example)."
    default:
        return nil
    }
}

/// The free plan's note under the personal id field (DnsPreset.QuotaNoteKey),
/// nil for a provider without one.
func dnsPersonalIdQuotaText(_ quotaNoteKey: String, provider: String) -> LocalizedStringResource? {
    switch quotaNoteKey {
    case DnsPresetKey.personalIdQuotaNextDns:
        return "\(provider)'s free plan stops filtering after 300,000 queries a month."
    case DnsPresetKey.personalIdQuotaAdGuard:
        return "\(provider)'s free plan is limited to 300,000 requests a month."
    default:
        return nil
    }
}

/// The message of an sdk error id of a personal id
/// (ValidateDnsPresetPersonalId). An id this build does not know reads as an
/// id in the wrong format, the sdk's most common refusal.
func dnsPresetErrorMessage(_ errorId: String) -> LocalizedStringResource {
    switch errorId {
    case DnsPresetKey.errorUnknown:
        return "This preset isn't available. Choose another one."
    case DnsPresetKey.errorPersonalIdRequired:
        return "Enter your profile ID."
    case DnsPresetKey.errorPersonalIdOtherProvider:
        return "This address belongs to another adblock provider. Choose that adblock provider instead."
    case DnsPresetKey.errorPersonalIdNotAccepted:
        return "This preset doesn't use a profile ID."
    default:
        // dns_preset_error_personal_id_invalid, and any id this build does
        // not know
        return "This ID isn't in the right format."
    }
}
