//
//  TabletLayout.swift
//  URnetwork
//
//  The tablet (regular width) layout convention: full-screen content sits in
//  a readable centered column, auth screens in a narrower form column, and
//  drawers wrap their content at the column width instead of spanning the
//  screen. Both clamps are no-ops on phone widths, which are narrower than
//  either column, so the same views serve both idioms.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum TabletLayout {

    /// The readable content column for full-screen views (onboarding, account
    /// sections, settings, leaderboard, the connect drawer). It is the width of
    /// one of the app's dialogs on iPad: a `.sheet` such as Provider Locations
    /// renders as the system form sheet, 540pt wide, which reads well as a
    /// column of body text.
    static let contentWidth: CGFloat = 540

    /// The form column for the auth screens (sign in, create network, instant
    /// account, seed phrase, verify, reset password).
    static let formWidth: CGFloat = 400
}

/**
 * The auth screens' page layout on a tablet, the treatment the sign-in page
 * already has: in landscape the carousel takes the left half and the form
 * column the right half, both centered vertically; in portrait the form column
 * sits centered on the page. Phones scroll the form from the top as before.
 */
struct AuthTabletLayout<Content: View>: View {

    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let isTablet = TabletLayout.isTablet
            let landscape = proxy.size.width > proxy.size.height

            ScrollView {
                if isTablet && landscape {
                    HStack(alignment: .center, spacing: 0) {
                        LoginCarousel()
                            .frame(width: proxy.size.width / 2)
                        content()
                            .tabletForm()
                            .frame(width: proxy.size.width / 2)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
                } else {
                    content()
                        .tabletForm()
                        // centered on the tablet page; phones keep the form at the top
                        .frame(minHeight: isTablet ? proxy.size.height : 0)
                }
            }
        }
    }
}

extension TabletLayout {

    /// Whether the app runs on a tablet idiom (iPad). The desktop app lays its
    /// windows out with its own split views and never takes this path.
    static var isTablet: Bool {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }
}

extension View {

    /// Clamps the view to the auth form column and centers it. Apply outside
    /// the content's own padding, the way the auth screens already do.
    func tabletForm() -> some View {
        self
            .frame(maxWidth: TabletLayout.formWidth)
            .frame(maxWidth: .infinity)
    }

    /// Clamps the view to the readable content column and centers it. Apply
    /// outside the content's own padding so the padding stays inside the
    /// column.
    func tabletReadableColumn() -> some View {
        self
            .frame(maxWidth: TabletLayout.contentWidth)
            .frame(maxWidth: .infinity)
    }
}
