//
//  DataInfoSheet.swift
//  URnetwork
//

import SwiftUI

/**
 * "About your data": what Used, Pending and Available mean, the daily balance
 * and when the free data refreshes. See DataInfo.swift.
 */
struct DataInfoSheet: View {

    @EnvironmentObject var themeManager: ThemeManager

    let startBalanceByteCount: Int
    let availableByteCount: Int
    let pendingByteCount: Int
    let showsFreeRefresh: Bool

    private var info: DataInfo {
        dataInfo(
            startBalanceByteCount: startBalanceByteCount,
            availableByteCount: availableByteCount,
            pendingByteCount: pendingByteCount
        )
    }

    var body: some View {
        StatsSheetContainer(title: "About your data") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // the same names and colors as the usage bar
                    row(
                        label: String(localized: "Used"),
                        color: Color.urElectricBlue,
                        amount: info.used,
                        explanation: Text("Data you've used so far.")
                    )

                    row(
                        label: String(localized: "Pending"),
                        color: Color.urCoral,
                        amount: info.pending,
                        explanation: Text("Data reserved for your open connections. What they don't use is returned when they close.")
                    )

                    row(
                        label: String(localized: "Available"),
                        color: themeManager.currentTheme.textFaintColor,
                        amount: info.available,
                        explanation: Text("Data you can still use.")
                    )

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Daily Data Balance:")
                            Spacer()
                            Text(info.daily)
                        }
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundStyle(themeManager.currentTheme.textMutedColor)

                        if showsFreeRefresh {
                            TimelineView(.everyMinute) { context in
                                Text("Free data refreshes daily at 00:00 UTC (in \(freeRefreshCountdownLabel(now: context.date))).")
                                    .font(themeManager.currentTheme.secondaryBodyFont)
                                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
    }

    private func row(label: String, color: Color, amount: String, explanation: Text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                Spacer()
                Text(amount)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
            }
            explanation
                .font(themeManager.currentTheme.bodyFont)
                .foregroundStyle(themeManager.currentTheme.textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/**
 * Presents the "About your data" sheet from the current balance. A modifier,
 * so the usage bar's hosts (Connect on iOS and macOS, Account) share one
 * presentation.
 */
struct DataInfoSheetPresenter: ViewModifier {

    @Binding var isPresented: Bool
    let isPro: Bool

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                DataInfoSheet(
                    startBalanceByteCount: subscriptionBalanceViewModel.startBalanceByteCount,
                    availableByteCount: subscriptionBalanceViewModel.availableByteCount,
                    pendingByteCount: subscriptionBalanceViewModel.pendingByteCount,
                    showsFreeRefresh: dataInfoShowsFreeRefresh(isPro: isPro)
                )
                .environmentObject(themeManager)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #endif
            }
    }
}

extension View {
    func dataInfoSheet(isPresented: Binding<Bool>, isPro: Bool) -> some View {
        modifier(DataInfoSheetPresenter(isPresented: isPresented, isPro: isPro))
    }
}

/// "Free data refreshes in {time}." for the out-of-balance notice and the
/// upgrade sheet, kept current once per minute.
struct FreeRefreshCountdownText: View {

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text("Free data refreshes in \(freeRefreshCountdownLabel(now: context.date)).")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
