//
//  SectionLoad.swift
//  URnetwork
//
//  What a section filled by a network fetch shows: its data, a spinner while
//  the first fetch runs, or an error with a retry once a fetch failed with
//  nothing fetched to show. A failed fetch must not read as real data (points
//  of 0, "No epochs yet", no payout wallet) or leave a spinner up for good. A
//  failed refresh keeps the data already on screen.
//

import SwiftUI

enum SectionLoad: Equatable {
    case loading
    case loaded
    case failed

    /// `hasData`: something fetched is on screen. `settled`: a fetch has
    /// finished, so empty data is a real answer rather than a pending one.
    static func of(hasData: Bool, settled: Bool, failed: Bool) -> SectionLoad {
        if hasData {
            return .loaded
        }
        if failed {
            return .failed
        }
        return settled ? .loaded : .loading
    }
}

/// The failed state of a section, in place of its data or spinner.
struct SectionLoadFailedView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Couldn't load. Check your connection and try again.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry", action: retry)
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(themeManager.currentTheme.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    let themeManager = ThemeManager.shared
    SectionLoadFailedView(retry: {})
        .environmentObject(themeManager)
        .padding()
        .background(themeManager.currentTheme.backgroundColor)
}
