//
//  ExportLogsButton.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 11/18/25.
//

import SwiftUI

struct ExportLogsButton: View {
    
    @State private var showExporter = false
    @State private var document: LogExportDocument?
    @State private var exporterSuggestedName: String = "URnetwork.log"
    
    
    var body: some View {
        
        HStack {
            // share
            ShareLink(item: LogExportTransferrable(), preview: .init("Export Logs")) {
                Label("Share Logs", systemImage: "square.and.arrow.up")
            }
            
            // save
            Button {
                document = LogExportDocument()
                showExporter = true
            } label: {
                Label("Save Logs", systemImage: "square.and.arrow.down")
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: document,
            contentType: .plainText,
            defaultFilename: document?.suggestedName ?? "URnetwork.log"
        ) { result in
            switch result {
            case .success(let url):
                print("Saved logs to: \(url.path)")
            case .failure(let error):
                print("Failed to save logs: \(error)")
            }
        }
    }
    
}

#Preview {
    ExportLogsButton()
}
