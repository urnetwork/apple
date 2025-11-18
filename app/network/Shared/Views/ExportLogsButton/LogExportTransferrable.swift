//
//  URLogFile.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 11/18/25.
//

import Foundation
import CoreTransferable
import URnetworkSdk

/**
 * Used for ShareLink
 */

struct LogExportTransferrable: Transferable {
    
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .utf8PlainText) { logs in
            let url = try LogExportService.generateShareableURL()
            return SentTransferredFile(url)
        }
    }    
    
}
