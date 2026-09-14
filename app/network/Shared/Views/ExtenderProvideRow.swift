//
//  ExtenderProvideRow.swift
//  URnetwork
//
//  The Extender row: the provider extender setting and its status, directly
//  under the provide mode (EXTENDER.md N1, N7). macOS only; iOS runs no role.
//

#if os(macOS)
import SwiftUI

/// The Extender row, in one of two kinds.
///
/// `.setting` is the row of the Connections card in settings: the switch bound
/// to the setting, the state line and the description. `.readOnly` is the same
/// row under the provide mode row of the provider statistics, with that row's
/// chevron in place of the switch and no description; it opens the settings,
/// where the switch is. Both draw `DeviceManager.extenderProvideDisplay`, and
/// each placement shows the row only while the device reports the role
/// supported: hidden, never disabled.
struct ExtenderProvideRow: View {

    enum Kind {
        /// settings: the switch and the description
        case setting
        /// the stats screens: the chevron, opening the screen with the switch
        case readOnly(action: () -> Void)
    }

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager

    let kind: Kind

    /// between the dot and the title
    private static let spacing: CGFloat = 8
    /// the read-only row's dot sits in `ProvideModeIndicator`'s frame
    private static let framedIndicatorSize: CGFloat = 14

    var body: some View {
        let display = deviceManager.extenderProvideDisplay
        if display.visible {
            switch kind {
            case .setting:
                setting(display)
            case .readOnly(let action):
                readOnly(display, action: action)
            }
        }
    }

    private func setting(_ display: ExtenderProvideDisplay) -> some View {
        // the lines under the title start under it: the bare dot and the gap
        let textInset = ExtenderProvideIndicator.size + Self.spacing
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $deviceManager.provideExtender) {
                HStack(spacing: Self.spacing) {
                    // bare, like the provide mode picker's own dot above it,
                    // so both titles start on one x
                    ExtenderProvideIndicator(dot: display.dot)
                    title
                    Spacer()
                }
            }
            // the native switch, trailing. A toggle with no style draws as a
            // leading checkbox in this card, which would move the dot off the
            // picker's x
            .toggleStyle(.switch)
            .accessibilityValue(Text(display.text))

            stateLine(display)
                .padding(.leading, textInset)

            Text("While you are providing, this device also relays for people whose access to the network is blocked, on TCP and UDP 443 and UDP 4053.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, textInset)
        }
    }

    private func readOnly(
        _ display: ExtenderProvideDisplay,
        action: @escaping () -> Void
    ) -> some View {
        let textInset = Self.framedIndicatorSize + Self.spacing
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Self.spacing) {
                    ExtenderProvideIndicator(dot: display.dot)
                        .frame(width: Self.framedIndicatorSize, height: Self.framedIndicatorSize)
                    title
                    Spacer()
                    // `ProvideModeRow`'s chevron
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(themeManager.currentTheme.textFaintColor)
                }
                stateLine(display)
                    .padding(.leading, textInset)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Extender")
        .accessibilityValue(display.text)
        // `.ignore` rebuilds the element without the button's role on macOS;
        // the trait puts it back, so the row reads as the button it is (N1)
        .accessibilityAddTraits(.isButton)
    }

    private var title: some View {
        Text("Extender")
            .font(themeManager.currentTheme.bodyFont)
            .foregroundColor(themeManager.currentTheme.textColor)
    }

    /// One line in the note style, muted or in the error color, cut with an
    /// ellipsis at the row's width. The whole text is the tooltip, since a
    /// listen failure names every carrier.
    private func stateLine(_ display: ExtenderProvideDisplay) -> some View {
        Text(display.text)
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(
                display.isError
                    ? themeManager.currentTheme.dangerColor
                    : themeManager.currentTheme.textMutedColor
            )
            .lineLimit(1)
            .truncationMode(.tail)
            .help(display.text)
            // a new state repaints at once
            .transaction { $0.animation = nil }
    }
}

/// The Extender row's dot: `ProvideModeIndicator`'s 8 pt dot without the public
/// ring, in the color of the state (N7). Decorative, and never animated: a
/// state change repaints it at once.
struct ExtenderProvideIndicator: View {

    @EnvironmentObject var themeManager: ThemeManager

    let dot: ExtenderProvideDot

    static let size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(dot.color(mutedColor: themeManager.currentTheme.textMutedColor))
            .frame(width: Self.size, height: Self.size)
            .transaction { $0.animation = nil }
            .accessibilityHidden(true)
    }
}
#endif
