//
//  IntroductionQuickConnectView.swift
//  URnetwork
//
//  The last onboarding page: the Control Center quick connect toggle and the
//  Home Screen widgets with the steps to add them (QuickConnectAndWidgetsView,
//  shared with Account > Widgets), under the onboarding chrome.
//

import SwiftUI

struct IntroductionQuickConnectView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let close: () -> Void
    let back: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    IntroductionTopBar(step: 5, onSkip: close, onBack: back)

                    Spacer().frame(height: 16)

                    Text("Connect in one tap")
                        .font(themeManager.currentTheme.titleFont)

                    Spacer().frame(height: 16)

                    // sample data: nobody has connected yet at this point
                    QuickConnectAndWidgetsView(data: .sample())

                    Spacer(minLength: 24)

                    UrButton(text: "Get connected", action: close)
                        .accessibilityIdentifier("acceptance.introduction.finish")
                }
                .padding()
                .frame(minHeight: proxy.size.height)
            }
        }
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }
}

#Preview {
    IntroductionQuickConnectView(close: {}, back: {})
        .background(Color.urBlack)
        .environmentObject(ThemeManager.shared)
        .environmentObject(IntroConnectorState())
}
