//
//  BuildInfo.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 6/14/25.
//

import Foundation

#if os(iOS)
import UIKit
class BuildInfoHelper {
    
    // Get the app version (CFBundleShortVersionString)
    static var appVersion: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }
    
    // Get the build number (CFBundleVersion)
    static var buildNumber: String {
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }
    
    // Get both version and build in a formatted string
    static var versionAndBuild: String {
        return "\(appVersion) (\(buildNumber))"
    }
    
    // Get the bundle identifier
    static var bundleIdentifier: String {
        return Bundle.main.bundleIdentifier ?? "Unknown"
    }
}
#elseif os(macOS)
import AppKit
class BuildInfoHelper {
    
    // Get the app version (CFBundleShortVersionString)
    static var appVersion: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }
    
    // Get the build number (CFBundleVersion)
    static var buildNumber: String {
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }
    
    // Get both version and build in a formatted string
    static var versionAndBuild: String {
        return "\(appVersion) (\(buildNumber))"
    }
    
    // Get the bundle identifier
    static var bundleIdentifier: String {
        return Bundle.main.bundleIdentifier ?? "Unknown"
    }
    
    // macOS-specific: Get the app name
    static var appName: String {
        return Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Unknown"
    }
}
#endif
