//
//  SystemExtensionMain.swift
//  network (packet tunnel SYSTEM extension)
//
//  Entry point of the URnetworkVPNSystem target (direct-download macOS
//  build). An app extension is loaded by the system's host process and has
//  no main; a system extension is its own executable, so it hands itself to
//  NetworkExtension here and never returns. The provider class is named by
//  NEProviderClasses in Info-macOS-sysext.plist.
//
//  Compiled into URnetworkVPN too (same synchronized folder) but empty there:
//  only the system-extension target defines DIRECT_DOWNLOAD.
//

#if DIRECT_DOWNLOAD

import Foundation
import NetworkExtension

@main
enum SystemExtensionMain {
    static func main() {
        autoreleasepool {
            NEProvider.startSystemExtensionMode()
        }
        dispatchMain()
    }
}

#endif
