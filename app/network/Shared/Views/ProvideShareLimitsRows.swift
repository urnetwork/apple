//
//  ProvideShareLimitsRows.swift
//  URnetwork
//
//  "Sharing limits" (owner decision 2026-11-28, feature 10), the section after
//  the provide settings: the owner's caps on what this device shares with
//  others, a maximum sharing speed and a monthly data limit, with this month's
//  sharing under them. The sdk keeps and applies the limits in the device
//  process (provide_share.go): the speed paces what the provider sends back to
//  the clients it serves, and once the month's data reaches the monthly limit,
//  providing to others pauses until the next calendar month. Zero is no limit.
//

import SwiftUI
import URnetworkSdk

/// a speed choice's bytes per second for each Mbps
private let provideShareBytesPerSecondPerMbps: Int64 = 125_000
/// a monthly choice's bytes for each GiB
private let provideShareBytesPerGib: Int64 = 1024 * 1024 * 1024

private let provideShareSpeedMbpsChoices: [Int64] = [1, 2, 5, 10, 20, 50, 100]
private let provideShareMonthlyGibChoices: [Int64] = [5, 10, 25, 50, 100, 250, 500, 1024]

/// The speed picker's values, bytes per second: no limit, the Mbps choices,
/// and `current` among them in order when it is none of them (a limit set
/// outside the app, such as by the CLI).
func provideShareSpeedOptions(current: Int64) -> [Int64] {
    provideShareOptions(
        [0] + provideShareSpeedMbpsChoices.map { $0 * provideShareBytesPerSecondPerMbps },
        current: current
    )
}

/// The monthly data picker's values, bytes: no limit, the GiB choices, and
/// `current` among them in order when it is none of them.
func provideShareMonthlyOptions(current: Int64) -> [Int64] {
    provideShareOptions(
        [0] + provideShareMonthlyGibChoices.map { $0 * provideShareBytesPerGib },
        current: current
    )
}

private func provideShareOptions(_ options: [Int64], current: Int64) -> [Int64] {
    guard !options.contains(current) else {
        return options
    }
    return (options + [current]).sorted()
}

/// "No limit", else the speed in whole Mbps, rounded for a limit set outside
/// the app.
private func provideShareSpeedLabel(_ bytesPerSecond: Int64) -> Text {
    guard 0 < bytesPerSecond else {
        return Text("No limit")
    }
    let mbps = Int((Double(bytesPerSecond) / Double(provideShareBytesPerSecondPerMbps)).rounded())
    return Text("\(mbps) Mbps")
}

/// "No limit", else the data in the app's compact byte form ("50 GiB",
/// "1 TiB").
private func provideShareMonthlyLabel(_ byteCount: Int64) -> Text {
    guard 0 < byteCount else {
        return Text("No limit")
    }
    return Text(verbatim: formatBalanceBytes(Int(clamping: byteCount)))
}

/**
 * The rows of the sharing limits section: the two limits, the month's sharing
 * under them, and what a limit costs. Its own view with its own store, like
 * `ExtenderPanel`, so the status the device publishes about once a second
 * while it shares re-renders these rows alone. The store follows the device
 * while the rows show and closes its subscription when they go. One view, a
 * single row of the iOS settings form, so the store sets up and resets once
 * per showing.
 */
struct ProvideShareLimitsRows: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager

    @StateObject private var store = ProvideShareStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            limitPicker(
                "Max sharing speed",
                selection: $store.maxBytesPerSecond,
                options: provideShareSpeedOptions(current: store.maxBytesPerSecond),
                label: provideShareSpeedLabel
            )

            rowSeparator

            limitPicker(
                "Monthly data limit",
                selection: $store.monthlyByteCount,
                options: provideShareMonthlyOptions(current: store.monthlyByteCount),
                label: provideShareMonthlyLabel
            )

            rowSeparator

            if let status = store.status {
                statusLine(status)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer().frame(height: 4)
            }

            Text("A limit lowers how much this device shares, which can lower its reliability ranking and its earnings.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            attach()
        }
        // the device is replaced on a sign-in and on a reconnect: follow it
        // rather than sampling it once
        .onChange(of: deviceManager.device.map(ObjectIdentifier.init)) { _ in
            attach()
        }
        .onDisappear {
            store.reset()
        }
    }

    private func attach() {
        if let device = deviceManager.device {
            store.setup(device)
        } else {
            store.reset()
        }
    }

    /// The space between the rows: on macOS the card's divider, as between
    /// its other settings; on iOS a gap within the form's row.
    @ViewBuilder
    private var rowSeparator: some View {
        #if os(macOS)
        Spacer().frame(height: 16)
        Divider()
        Spacer().frame(height: 16)
        #else
        Spacer().frame(height: 12)
        #endif
    }

    /// One limit's picker, drawn as the provide settings' pickers are: on iOS
    /// the provide mode picker's label beside its menu (`ProvideControlPicker`),
    /// on macOS the card's labelled popup.
    @ViewBuilder
    private func limitPicker(
        _ title: LocalizedStringKey,
        selection: Binding<Int64>,
        options: [Int64],
        label: @escaping (Int64) -> Text
    ) -> some View {
        #if os(macOS)
        HStack {
            Picker(selection: selection) {
                ForEach(options, id: \.self) { option in
                    label(option)
                        .font(themeManager.currentTheme.bodyFont)
                        .tag(option)
                }
            } label: {
                Text(title)
                    .font(themeManager.currentTheme.bodyFont)
            }
            .accentColor(themeManager.currentTheme.textColor)

            Spacer()
        }
        #else
        LabeledContent {
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { option in
                    label(option)
                        .font(themeManager.currentTheme.bodyFont)
                        .tag(option)
                }
            }
            .accentColor(themeManager.currentTheme.textColor)
        } label: {
            HStack {
                Text(title)
                    .font(themeManager.currentTheme.bodyFont)

                Spacer()
            }
        }
        #endif
    }

    /// The month's sharing as the device reports it: when the monthly limit
    /// was reached, the day sharing with others resumes (the next month's
    /// first, in the reader's time zone), else the data shared, against the
    /// monthly limit when there is one.
    private func statusLine(_ status: ProvideShareStatusModel) -> Text {
        if status.budgetReached {
            let date = Date(timeIntervalSince1970: TimeInterval(status.periodEndMillis) / 1000)
                .formatted(date: .abbreviated, time: .omitted)
            return Text("Monthly limit reached. Sharing with others resumes \(date).")
        }
        let data = formatBalanceBytes(Int(clamping: status.byteCount))
        if 0 < status.monthlyByteCount {
            let limit = formatBalanceBytes(Int(clamping: status.monthlyByteCount))
            return Text("\(data) of \(limit) shared this month")
        }
        return Text("\(data) shared this month")
    }
}

/// The device's share status, as the rows draw it.
struct ProvideShareStatusModel: Equatable {
    /// the limits in force
    let maxBytesPerSecond: Int64
    let monthlyByteCount: Int64
    /// the data this device shared with others this month
    let byteCount: Int64
    /// the first instant of the next month, unix milliseconds, when the data
    /// starts again from zero
    let periodEndMillis: Int64
    /// the month's data reached the monthly limit: sharing with others is
    /// paused until `periodEndMillis`
    let budgetReached: Bool

    init(_ status: SdkProvideShareStatus) {
        maxBytesPerSecond = status.maxBytesPerSecond
        monthlyByteCount = status.monthlyByteCount
        byteCount = status.byteCount
        periodEndMillis = status.periodEndMillis
        budgetReached = status.budgetReached
    }
}

private class ProvideShareStatusChangeListener: NSObject, SdkProvideShareStatusChangeListenerProtocol {
    private let callback: (SdkProvideShareStatus?) -> Void
    init(callback: @escaping (SdkProvideShareStatus?) -> Void) {
        self.callback = callback
    }
    func provideShareStatusChanged(_ status: SdkProvideShareStatus?) {
        callback(status)
    }
}

/**
 * The sharing limits and the share status of one device, for the rows.
 *
 * The limits are the pickers' values: a change writes both through the
 * device, the changed one and the other as it is, and the device applies and
 * keeps them. They are read through the device at setup, and again when a
 * pushed status names other limits in force, as a limit set outside the app
 * or a write replayed when the device process came back does. The pickers
 * take the read rather than the status: the device answers a write still
 * queued for it, and a status in flight from before a write names the old
 * limits.
 */
@MainActor
class ProvideShareStore: ObservableObject {

    /// the speed limit, bytes per second, 0 for none
    @Published var maxBytesPerSecond: Int64 = 0 {
        didSet {
            guard !isLoadingFromDevice, maxBytesPerSecond != oldValue else {
                return
            }
            writeLimits()
        }
    }

    /// the monthly data limit, bytes, 0 for none
    @Published var monthlyByteCount: Int64 = 0 {
        didSet {
            guard !isLoadingFromDevice, monthlyByteCount != oldValue else {
                return
            }
            writeLimits()
        }
    }

    /// nil until the device's status is read
    @Published private(set) var status: ProvideShareStatusModel? = nil

    private var device: SdkDeviceRemote?
    private var statusSub: SdkSubProtocol?
    // advanced by every reset: a report from a retired listener changes
    // nothing, after the next setup too
    private var generation = 0
    // true while the limits take the device's values, which are not written
    // back
    private var isLoadingFromDevice = false

    func setup(_ device: SdkDeviceRemote) {
        reset()

        self.device = device
        let generation = self.generation
        // `AddProvideShareStatusChangeListener` binds as `add(_:)`: the
        // selector names the listener type, which swift strips
        statusSub = device.add(ProvideShareStatusChangeListener { [weak self] status in
            // the device hands a listener the published value, never nil
            guard let status else {
                return
            }
            let model = ProvideShareStatusModel(status)
            DispatchQueue.main.async {
                guard let self, self.generation == generation else {
                    return
                }
                self.apply(model)
            }
        })
        // the listener only reports changes; seed with what is already known
        readLimits()
        if let status = device.getProvideShareStatus() {
            apply(ProvideShareStatusModel(status))
        }
    }

    /// Closes the subscription and drops the device and its status. The
    /// limits keep their values until the next setup reads them.
    func reset() {
        generation += 1
        statusSub?.close()
        statusSub = nil
        device = nil
        status = nil
    }

    private func apply(_ model: ProvideShareStatusModel) {
        if model.maxBytesPerSecond != maxBytesPerSecond || model.monthlyByteCount != monthlyByteCount {
            readLimits()
        }
        guard model != status else {
            return
        }
        status = model
    }

    private func readLimits() {
        guard let limits = device?.getProvideShareLimits() else {
            return
        }
        isLoadingFromDevice = true
        // a negative limit is no limit, as the sdk reads it
        maxBytesPerSecond = max(limits.maxBytesPerSecond, 0)
        monthlyByteCount = max(limits.monthlyByteCount, 0)
        isLoadingFromDevice = false
    }

    private func writeLimits() {
        device?.setProvideShareLimits(SdkNewProvideShareLimits(maxBytesPerSecond, monthlyByteCount))
    }
}
