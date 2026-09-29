// SPDX-License-Identifier: MPL-2.0

import Foundation

enum QuickConnectControlMetadata {
    // iOS 27 traps in LocalizedStringResource.init(stringLiteral:) while
    // constructing the control's metadata in the widget extension. Use the
    // distinct static-key/default-value initializer, preserving localization
    // keys, fallback text, and the default table, current locale, and bundle.
    // Computed properties keep the original per-render locale semantics.
    static var displayName: LocalizedStringResource {
        LocalizedStringResource("URnetwork", defaultValue: "URnetwork")
    }

    static var description: LocalizedStringResource {
        LocalizedStringResource(
            "Connect or disconnect the URnetwork VPN.",
            defaultValue: "Connect or disconnect the URnetwork VPN."
        )
    }
}
