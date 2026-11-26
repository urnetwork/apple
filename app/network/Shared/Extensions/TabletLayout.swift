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
 * tree whichever way the window turns, so its state does too. The page's
 * shape is measured without the software keyboard (readsLayoutSize), so the
 * keyboard never moves the carousel in or out.
 */
struct AuthTabletLayout<Content: View>: View {

    @Environment(\.isRegularWidth) private var isRegularWidth
    // the page's size without the keyboard, nil until measured
    @State private var layoutSize: CGSize? = nil

    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let besideCarousel = TabletLayout.showsCarouselBesideForm(
                isRegularWidth: isRegularWidth,
                layoutSize: layoutSize,
                visibleSize: proxy.size
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
        .readsLayoutSize($layoutSize)
    }
}

extension TabletLayout {

    /// Whether the auth screens show the carousel beside the form: a
    /// regular-width window that is wider than it is tall. The window's
    /// shape, not the device's orientation, which a resizable window does
    /// not follow; and the whole page, not the part the software keyboard
    /// leaves. An 11-inch iPad's portrait sign-in page is about 820 x 1086
    /// pt, and a 316 pt keyboard leaves about 820 x 790 of it, wider than
    /// tall: deciding from that moved the form the keyboard was typing into,
    /// which closed the keyboard, so nothing could be typed (App Store
    /// review, iPadOS 27.2.1).
    ///
    /// `layoutSize` is the page measured without the keyboard
    /// (readsLayoutSize), nil until its first measurement; `visibleSize` is
    /// the page above the keyboard, the GeometryReader's, used only until
    /// then.
    static func showsCarouselBesideForm(isRegularWidth: Bool, layoutSize: CGSize?, visibleSize: CGSize) -> Bool {
        let size = layoutSize ?? visibleSize
        return isRegularWidth && size.height < size.width
    }
}

extension View {

    /// Keeps `size` at this view's size as if the software keyboard were
    /// hidden: the measurement extends under the keyboard's safe area, so the
    /// keyboard showing, hiding or docking leaves it as it was, while turning
    /// and resizing the window update it. The content itself keeps avoiding
    /// the keyboard. The Mac has no software keyboard and no regular-width
    /// auth layout (isRegularWidth), so it measures nothing.
    func readsLayoutSize(_ size: Binding<CGSize?>) -> some View {
        #if os(iOS)
        return background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        size.wrappedValue = proxy.size
                    }
                    .onChange(of: proxy.size) { measured in
                        size.wrappedValue = measured
                    }
            }
            .ignoresSafeArea(.keyboard)
        }
        #else
        return self
        #endif
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
