//
//  LogViewerView.swift
//  URnetwork
//
//  Settings > View Logs: the last lines of the app's and the packet tunnel
//  extension's logs, read-only (https://github.com/urnetwork/apple/issues/223).
//  The sdk reads them (LogExport.tails, SdkLogTails): the last 500 lines of
//  each process's newest INFO log, the file glog writes every line to. They are
//  read when the view opens, after the steps the app's own upload takes first,
//  so the extension's newest lines are in.
//

import SwiftUI

struct LogViewerView: View {

    @EnvironmentObject var themeManager: ThemeManager

    /// nil while the logs are read
    @State private var sections: [LogTailSection]?

    private let bottomId = "log-viewer-bottom"

    var body: some View {
        Group {
            if let sections {
                if sections.isEmpty {
                    Text("No log file found")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    logLines(sections)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            sections = await LogExport.tails()
        }
    }

    /// Each log under its process and file name, oldest line first, opened at
    /// the newest line, the last. A tail that leaves out the log's earlier
    /// lines starts with an ellipsis.
    private func logLines(_ sections: [LogTailSection]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        Text(verbatim: "\(section.source)/\(section.name)")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                            .padding(.top, section.id == 0 ? 0 : 16)
                            .padding(.bottom, 4)
                        if section.truncated {
                            Text(verbatim: "…")
                                .font(.system(size: 11).monospaced())
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                        }
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line)
                                .font(.system(size: 11).monospaced())
                                .foregroundColor(themeManager.currentTheme.textColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomId)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .textSelection(.enabled)
            }
            .onAppear {
                proxy.scrollTo(bottomId, anchor: .bottom)
            }
        }
    }
}
