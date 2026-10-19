import SwiftUI

private struct NetworkLoginContextKey: EnvironmentKey {
    static let defaultValue: NetworkLoginContext? = nil
}

extension EnvironmentValues {
    var networkLoginContext: NetworkLoginContext? {
        get { self[NetworkLoginContextKey.self] }
        set { self[NetworkLoginContextKey.self] = newValue }
    }
}
