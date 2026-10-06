// Native typechecking support only; no profile operation is executed.
import Foundation

enum TunnelIntentStore {
    static let sourceApp = "audit"
    static func startOptions(source: String) -> [String: NSObject] {
        ["audit-source": source as NSString]
    }
}
