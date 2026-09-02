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
        if #available(iOS 18.0, macOS 26.0, *) {
            QuickConnectControl()
        }
    }
}
