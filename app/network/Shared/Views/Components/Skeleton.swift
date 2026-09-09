//
//  Skeleton.swift
//  URnetwork
//

import SwiftUI

/**
 * The shared placeholder for content that arrives after first paint
 * (mmm/DESIGNSTYLE.md "Placeholders, not pop-in"): a low-contrast rounded bar
 * with a slow shimmer, sized by the caller to exactly the box the loaded
 * content will occupy, so the layout around it never moves when the data lands.
 *
 * The shimmer runs only while the skeleton is on screen and stands still under
 * Reduce Motion. The bar itself is hidden from assistive tech; the container
 * that holds a group of skeletons carries the loading label.
 */
struct Skeleton: View {

    var width: CGFloat? = nil
    var height: CGFloat = 12
    var cornerRadius: CGFloat = 6

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(themeManager.currentTheme.textFaintColor.opacity(0.18))
            .overlay(
                GeometryReader { geometry in
                    if !reduceMotion {
                        LinearGradient(
                            colors: [
                                .clear,
                                themeManager.currentTheme.textFaintColor.opacity(0.16),
                                .clear,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geometry.size.width * 0.6)
                        .offset(x: phase * geometry.size.width)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                phase = -1
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .onDisappear {
                // stop the repeat: an always-mounted animation keeps the
                // render loop awake even when the drawer is collapsed
                phase = -1
            }
    }
}

extension View {
    /// Marks a group of skeletons for assistive tech: one element that says what
    /// is loading instead of an empty region.
    func skeletonGroup(_ label: LocalizedStringKey) -> some View {
        self
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityAddTraits(.updatesFrequently)
    }
}
