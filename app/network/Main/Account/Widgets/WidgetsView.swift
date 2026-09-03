//
//  WidgetsView.swift
//  URnetwork
//
//  Account > Widgets: the quick connect control and the Home Screen widgets
//  with the steps to add them. The content is QuickConnectAndWidgetsView, the
//  same view the last onboarding page shows, so a user who skipped onboarding
//  (or wants the steps again) finds it here.
//

import SwiftUI

struct WidgetsView: View {

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        ScrollView {
            QuickConnectAndWidgetsView()
                .padding()
        }
    }
}

#Preview {
    WidgetsView()
        .background(Color.urBlack)
        .environmentObject(ThemeManager.shared)
}
