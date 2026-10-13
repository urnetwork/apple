//
//  NetworkTestsPrincipal.swift
//  networkTests
//
//  The test bundle's principal class (INFOPLIST_KEY_NSPrincipalClass in the
//  networkTests build settings). XCTest makes one when it loads the bundle,
//  before any test runs, so the bundle turns off here what no test may do: the
//  SDK's extender network client. A space keyed by a dotted host starts it as
//  soon as the space is built, and it resolves the space's api host through
//  the public DoH servers and dials it. The hosting app has built no space by
//  then: NetworkApp skips its startup initialization when it hosts unit tests.
//

import Foundation
import URnetworkSdk

@objc(NetworkTestsPrincipal)
final class NetworkTestsPrincipal: NSObject {
    override init() {
        super.init()
        _ = SdkSetExtenderNetworkClientEnabled(false)
    }
}
