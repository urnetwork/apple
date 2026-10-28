//
//  TabletLayout.swift
//  URnetwork
//
//  The tablet (regular width) layout convention: full-screen content sits in
//  a readable centered column, auth screens in a narrower form column, and
//  the phone drawer wraps its content at the column width in a wide window.
//  Both clamps are no-ops on phone widths, which are narrower than either
//  column, so the same views serve every window. Layout follows the window's
//  size class and measured size, never the device idiom or orientation: an
//  unfolded iPhone Duo is a phone with a regular width.
//

import SwiftUI

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
 * The auth screens' page layout in a regular-width window, the treatment the
 * sign-in page already has: wider than tall, the carousel takes the left half
 * and the form column the right half, both centered vertically; taller than
 * wide, the form column sits centered on the page. Compact windows scroll the
 * form from the top as before. The content stays in one place in the view
 * tree whichever way the window turns, so its state does too.
 */
struct AuthTabletLayout<Content: View>: View {

    @Environment(\.isRegularWidth) private var isRegularWidth

    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let besideCarousel = TabletLayout.showsCarouselBesideForm(
                isRegularWidth: isRegularWidth,
                size: proxy.size
            )

            ScrollView {
                HStack(alignment: .center, spacing: 0) {
                    if besideCarousel {
                        LoginCarousel()
                            .frame(width: proxy.size.width / 2)
                    }
                    content()
                        .tabletForm()
                        .frame(width: besideCarousel ? proxy.size.width / 2 : proxy.size.width)
                }
                // centered on a regular-width page; compact windows keep the
                // form at the top
                .frame(minHeight: isRegularWidth ? proxy.size.height : 0)
            }
        }
    }
}

extension TabletLayout {

    /// Whether the auth screens show the carousel beside the form: a
    /// regular-width window that is wider than it is tall. The window's
    /// shape, not the device's orientation, which a resizable window does
    /// not follow.
    static func showsCarouselBesideForm(isRegularWidth: Bool, size: CGSize) -> Bool {
        isRegularWidth && size.height < size.width
    }
}

extension GeometryProxy {

    /// The fold dividing this view (iPhone Duo, iOS 27.1): its division
    /// reserved region, flat or folded, an active one first. Nil without a
    /// hinge, on the Mac, and before iOS 27.1.
    var windowFold: WindowFold? {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            let divisions = reservedRegions(kind: .division, options: .includeInactive)
            if let division = divisions.first(where: { $0.isActive }) ?? divisions.first {
                return WindowFold(frame: division.frame, isActive: division.isActive)
            }
        }
        #endif
        return nil
    }
}

extension EnvironmentValues {

    /// Whether the window has a regular width size class: iPad, a wide iPad
    /// window, iPhone Duo's inner display. Never the idiom: an unfolded
    /// iPhone Duo is a phone. The desktop app lays its windows out with its
    /// own split views, so this is false there.
    var isRegularWidth: Bool {
        #if os(iOS)
        return horizontalSizeClass == .regular
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
