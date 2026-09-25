//
//  LicensesView.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk

/**
 * A value copy of one SDK `LicenseInfo`. The SDK list is read once, off the
 * main thread, and copied into these so the lazy list and the navigation path
 * never call back into the gomobile objects while rendering.
 */
struct LicenseEntry: Identifiable, Hashable {
    let id: Int
    let name: String
    let version: String
    let kind: String
    let origin: String
    let url: String
    let spdx: String
    let copyright: String
    // must be shown verbatim when non-empty (e.g. the MaxMind attribution)
    let notice: String
    let text: String

    var isData: Bool { kind == "data" }

    /// "version · spdx", omitting whichever is empty
    var summary: String {
        [version, spdx].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    init(id: Int, info: SdkLicenseInfo) {
        self.id = id
        self.name = info.name
        self.version = info.version
        self.kind = info.kind
        self.origin = info.origin
        self.url = info.url
        self.spdx = info.spdx
        self.copyright = info.copyright
        self.notice = info.notice
        self.text = info.text
    }

    /**
     * Reads the apple license list. The first call parses the SDK's embedded
     * license.yml (hundreds of KB), so callers run this off the main thread.
     * Uses the device when there is one; the package-level function otherwise.
     */
    static func load(device: SdkDeviceRemote?) -> [LicenseEntry] {
        guard let list = device?.getLicenses(SdkLicenseAppApple) ?? SdkGetLicenses(SdkLicenseAppApple) else {
            return []
        }
        var entries: [LicenseEntry] = []
        entries.reserveCapacity(list.len())
        for i in 0..<list.len() {
            if let info = list.get(i) {
                entries.append(LicenseEntry(id: i, info: info))
            }
        }
        return entries
    }
}

struct LicensesView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let device: SdkDeviceRemote?
    let navigate: (AccountNavigationPath) -> Void

    @State private var entries: [LicenseEntry]? = nil

    var body: some View {
        List {
            Section {
                Text("URnetwork is built with the open source software and data below. Each entry shows its license and any notice it requires.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }

            if let entries {
                let data = entries.filter { $0.isData }
                let software = entries.filter { !$0.isData }

                if !data.isEmpty {
                    Section("Data attributions") {
                        ForEach(data) { entry in
                            row(entry)
                        }
                    }
                }
                if !software.isEmpty {
                    Section("Open source software") {
                        ForEach(software) { entry in
                            row(entry)
                        }
                    }
                }
            } else {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #elseif os(macOS)
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(themeManager.currentTheme.backgroundColor)
        .task {
            guard entries == nil else { return }
            let device = self.device
            entries = await Task.detached(priority: .userInitiated) {
                LicenseEntry.load(device: device)
            }.value
        }
    }

    private func row(_ entry: LicenseEntry) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)

                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }

                if !entry.notice.isEmpty {
                    Text(verbatim: entry.notice)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(themeManager.currentTheme.textMutedColor)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            navigate(.licenseDetail(entry))
        }
    }
}

struct LicenseDetailView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let entry: LicenseEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                        .font(themeManager.currentTheme.secondaryTitleFont)
                        .foregroundColor(themeManager.currentTheme.textColor)

                    if !entry.summary.isEmpty {
                        Text(entry.summary)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                }

                if !entry.notice.isEmpty {
                    Text(verbatim: entry.notice)
                        .font(themeManager.currentTheme.bodyFont)
                        .fontWeight(.semibold)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(themeManager.currentTheme.tintedBackgroundBase)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if !entry.copyright.isEmpty {
                    Text(verbatim: entry.copyright)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let url = URL(string: entry.url), !entry.url.isEmpty {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Text("Project page")
                            Image(systemName: "arrow.up.right.square")
                        }
                        .font(themeManager.currentTheme.bodyFont)
                    }
                }

                if !entry.text.isEmpty {
                    Divider()

                    Text(verbatim: entry.text)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            #if os(macOS)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            #endif
        }
        .background(themeManager.currentTheme.backgroundColor)
    }
}
