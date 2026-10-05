//
//  CloudProxyLink.swift
//  URnetwork
//

import Foundation

/// The cloud proxies page on ur.io. The app has no protocol switch: someone who
/// needs WireGuard, SOCKS or an HTTPS proxy (an app or a device that cannot run
/// the VPN) creates one there, and Settings links to it. The link carries no
/// credential; ur.io asks the user to sign in when it needs to.
enum CloudProxyLink {
    static let url = URL(string: "https://ur.io/app/proxies")!
}
