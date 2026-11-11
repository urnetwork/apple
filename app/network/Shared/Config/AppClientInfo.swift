//
//  AppClientInfo.swift
//  URnetwork
//
//  The device type, app version and distribution this app reports with its
//  api calls (the SDK sends them as X-UR-ClientInfo and in the connect auth).
//  The server keeps the device type and version with each session's last use,
//  which Account > Sessions shows, e.g. "iOS · 2026.10.8-1066894190". They are
//  advisory presentation data, not a device identity. The distribution tells
//  the server who bills this build: the App Store builds and the
//  direct-download DMG send the same device type and version, and the
//  onboarding emails' billing copy and offers follow it.
//
//  Set on every api the app creates or replaces: each network space owns one
//  api, so DeviceManager sets it whenever its network space changes. The
//  packet tunnel sets the same values on the api of its own network space.
//

import Foundation
import URnetworkSdk

enum AppClientInfo {

    /// One of the server's device types.
    static var deviceType: String {
        #if os(macOS)
        return "macos"
        #else
        return "ios"
        #endif
    }

    /// The build's distribution (the SDK's ClientDistribution values): the
    /// App Store builds, iOS and the Mac App Store, or the direct-download Mac
    /// build, as BillingDistribution reads the DIRECT_DOWNLOAD flag.
    static func distribution(_ billing: BillingDistribution) -> String {
        switch billing {
        case .appStore:
            return SdkClientDistributionAppStore
        case .direct:
            return SdkClientDistributionMacDirect
        }
    }

    /// This build's distribution.
    static var buildDistribution: String {
        distribution(BillingDistribution.current)
    }

    /**
     * The release name, `<YYYY.M.D>-<code>`: CFBundleShortVersionString and
     * CFBundleVersion joined by "-", as the release tags and the tunnel's
     * device version are. The short version alone without a build code, and
     * empty (unknown) without a short version.
     */
    static func appVersion(shortVersion: String?, buildVersion: String?) -> String {
        let short = (shortVersion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let build = (buildVersion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if short.isEmpty {
            return ""
        }
        if build.isEmpty {
            return short
        }
        return "\(short)-\(build)"
    }

    /// The running bundle's release name.
    static var bundleAppVersion: String {
        appVersion(
            shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    /// Reports this app's device type, version and distribution with every
    /// call `api` makes.
    static func apply(to api: SdkApi?) {
        api?.setClientInfo(SdkNewClientInfoWithDistribution(deviceType, bundleAppVersion, buildDistribution))
    }
}
