//
//  AppClientInfo.swift
//  URnetwork
//
//  The device type and app version this app reports with its api calls (the
//  SDK sends them as X-UR-ClientInfo and in the connect auth). The server
//  keeps them with each session's last use, which Account > Sessions shows,
//  e.g. "iOS · 2026.10.8-1066894190". They are advisory presentation data,
//  not a device identity.
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

    /// Reports this app's device type and version with every call `api` makes.
    static func apply(to api: SdkApi?) {
        api?.setClientInfo(SdkNewClientInfo(deviceType, bundleAppVersion))
    }
}
