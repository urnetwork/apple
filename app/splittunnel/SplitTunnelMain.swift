//
//  SplitTunnelMain.swift
//  URnetworkSplitTunnel (macOS split tunnel system extension)
//
//  Entry point of the split tunnel system extension (targets
//  URnetworkSplitTunnel, App Store family, and URnetworkSplitTunnelDirect,
//  direct-download family). A system extension is its own executable, so it
//  hands itself to NetworkExtension here and never returns; the provider
//  class is named by NEProviderClasses in its Info.plist.
//

import Foundation
import NetworkExtension

/// The extension's entry point.
@main
enum SplitTunnelMain {
    /// Hands the process to NetworkExtension; never returns.
    static func main() {
        autoreleasepool {
            NEProvider.startSystemExtensionMode()
        }
        dispatchMain()
    }
}
