//
//  WidgetsView.swift
//  URnetwork
//
//  Account > Widgets: the quick connect control and the Home Screen widgets
//  with the steps to add them. The content is QuickConnectAndWidgetsView, the
//  same view the last onboarding page shows, so a user who skipped onboarding
//  (or wants the steps again) finds it here. Unlike onboarding, the widget
//  previews here are the real thing: they render the App Group snapshots the
//  pinned widgets render, live, refreshed the moment those change.
//

import SwiftUI

struct WidgetsView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var model = WidgetPreviewModel()

    var body: some View {
        ScrollView {
            QuickConnectAndWidgetsView(data: model.data)
                .padding()
        }
        .onAppear {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
        .onChange(of: scenePhase) { phase in
            // nothing to watch while backgrounded; re-read on return, since
            // notifications posted meanwhile were not delivered
            if phase == .active {
                model.start()
            } else {
                model.stop()
            }
        }
    }
}

#Preview {
    WidgetsView()
        .background(Color.urBlack)
        .environmentObject(ThemeManager.shared)
}
