//
//  ReleaseNotesSheet.swift
//  URnetwork
//
//  The bundled release note (ReleaseNotes.swift), opened by tapping the
//  version in Account > Settings on iOS and macOS: the note's title, its
//  version and date, the intro, then each section's heading and bullets.
//  The note's text is the store's, shown as written and laid out in the
//  note's own direction; the sheet's title and close button keep the app's.
//

import SwiftUI

struct ReleaseNotesSheet: View {

    @EnvironmentObject var themeManager: ThemeManager

    let presentation: ReleaseNotesPresentation

    var body: some View {
        StatsSheetContainer(title: "Release notes") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: presentation.note.title)
                            .font(themeManager.currentTheme.secondaryTitleFont)
                            .foregroundStyle(themeManager.currentTheme.textColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)

                        if !presentation.subtitle.isEmpty {
                            Text(verbatim: presentation.subtitle)
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundStyle(themeManager.currentTheme.textMutedColor)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel(Text(verbatim: presentation.subtitleAccessibilityLabel))
                        }
                    }

                    if let intro = presentation.note.intro {
                        Text(verbatim: intro)
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundStyle(themeManager.currentTheme.textColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(Array(presentation.note.sections.enumerated()), id: \.offset) { _, section in
                        sectionView(section)
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // the note reads in its own language's direction, so the
                // English fallback runs left to right in an Arabic or Hebrew
                // app, its punctuation included
                .environment(\.layoutDirection, presentation.isRightToLeft ? .rightToLeft : .leftToRight)
                .padding(.horizontal)
                // a wide window keeps the note in the readable column
                .tabletReadableColumn()
                .padding(.bottom)
            }
        }
    }

    /// A section: its heading in the app's label style, then its bullets.
    private func sectionView(_ section: ReleaseNotes.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let heading = section.heading {
                Text(verbatim: heading)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }

            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "•")
                        .foregroundStyle(themeManager.currentTheme.textMutedColor)
                        .accessibilityHidden(true)
                    Text(verbatim: item)
                        .foregroundStyle(themeManager.currentTheme.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(themeManager.currentTheme.bodyFont)
            }
        }
    }
}

/**
 * Presents the release notes sheet. A modifier, so the iOS and macOS
 * settings share one presentation.
 */
struct ReleaseNotesSheetPresenter: ViewModifier {

    @Binding var isPresented: Bool
    let presentation: ReleaseNotesPresentation?

    @EnvironmentObject var themeManager: ThemeManager

    func body(content: Content) -> some View {
        content
            .sheetOffTheFold(isPresented: $isPresented) {
                if let presentation {
                    ReleaseNotesSheet(presentation: presentation)
                        .environmentObject(themeManager)
                        #if os(iOS)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        #endif
                }
            }
    }
}

extension View {
    /// Presents the bundled release note while `isPresented`.
    func releaseNotesSheet(isPresented: Binding<Bool>, presentation: ReleaseNotesPresentation?) -> some View {
        modifier(ReleaseNotesSheetPresenter(isPresented: isPresented, presentation: presentation))
    }
}
