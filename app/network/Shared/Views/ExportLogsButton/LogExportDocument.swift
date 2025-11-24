import Foundation
import SwiftUI
import UniformTypeIdentifiers
import URnetworkSdk

struct LogExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    static var writableContentTypes: [UTType] { [.plainText] }

    let data: Data
    let suggestedName: String

    init() {
        do {
            let url = try LogExportService.generateShareableURL()
            self.data = (try? Data(contentsOf: url)) ?? Data("Log file unavailable".utf8)
            self.suggestedName = LogExportService.suggestedFilename(for: url)
        } catch {
            self.data = Data("Log file unavailable: \(error)".utf8)
            self.suggestedName = "URnetwork.log"
        }
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
        self.suggestedName = "URnetwork.log"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return .init(regularFileWithContents: data)
    }
}
