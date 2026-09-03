//
//  URnetworkWidgets.swift
//  URnetworkWidgets
//
//  Entry point for the widget extension: the Control Center / Lock Screen /
//  Action button toggle (iOS 18, macOS 26) and the Home Screen widgets
//  (iOS 17, macOS 14).
//
//  Everything in this target is SDK-free. Tunnel state comes from
//  NetworkExtension directly; everything else is read from the snapshots the
//  app and the packet tunnel extension write into the App Group (see
//  network/Shared/Widgets/WidgetSnapshots.swift).
//

import SwiftUI
import WidgetKit

@main
struct URnetworkWidgetBundle: WidgetBundle {

    @WidgetBundleBuilder
    var body: some Widget {
        DashboardWidget()
        ProviderGlobeWidget()
        ContractsWidget()
        // iOS only at compile time: the control's WidgetKit types are
        // macOS 26 symbols and are absent from the macOS 15 SDK CI builds
        // against, so QuickConnectControl itself is not compiled there. The
        // macOS bundle is still valid, with the three Home Screen widgets.
        #if os(iOS)
        if #available(iOS 18.0, macOS 26.0, *) {
            QuickConnectControl()
        }
        #endif
    }
}
