//
//  QuickConnectControl.swift
//  URnetworkWidgets
//
//  The quick connect toggle for Control Center, the Lock Screen's bottom
//  slots and the Action button (iOS 18+; macOS 26 Control Center and menu
//  bar; mirrored to Apple Watch by the system because its intent never
//  foregrounds the app). It is the iOS counterpart of the Android Quick
//  Settings tile.
//
//  State is the live NEVPNStatus of the app's tunnel configuration, read in
//  this process. The action starts or stops that configuration in this
//  process too: the packet tunnel extension boots from its saved
//  configuration and self-refreshes its credential, so no app launch is
//  involved. A device that has never installed the tunnel (fresh install, or
//  logged out) shows the toggle disabled with a "Not signed in" value, the way
//  the system's own VPN control greys out with no VPN configured: only the app
//  can create the configuration and obtain the system's VPN consent, and a
//  control's template cannot switch to an "open the app" button by state.
//
//  Symbol-only surfaces (the small Control Center tile, the Lock Screen slot,
//  the Action button hint) show the solid UR connector mark, white when off
//  and pink when connected; larger tiles add the title and the
//  connected/disconnected value text.
//

//  iOS only at compile time: ControlWidget, StaticControlConfiguration,
//  ControlWidgetToggle and ControlValueProvider are macOS 26 symbols, absent
//  from the macOS 15 SDK that the CI toolchain (Xcode 16.4) builds against.
//  The `@available` annotations below stay because they are still the correct
//  runtime guard on iOS; only the compile-time platform test can keep the
//  macOS leg from needing declarations its SDK does not have.
//

#if os(iOS)

import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, macOS 26.0, *)
struct QuickConnectControl: ControlWidget {

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: WidgetKinds.quickConnectControl,
            provider: Provider()
        ) { state in
            ControlWidgetToggle(
                "URnetwork",
                isOn: state.isOn,
                action: ToggleTunnelIntent(value: !state.isOn, source: TunnelIntentStore.sourceControl)
            ) { isOn in
                Label {
                    if !state.isConfigured {
                        Text("Not signed in")
                    } else if isOn {
                        Text("Connected")
                    } else {
                        Text("Disconnected")
                    }
                } icon: {
                    // the solid connector in both states: white when off,
                    // the tint (pink) when on, as the system renders toggles
                    Image(WidgetTheme.connectorSymbolFill)
                }
                .controlWidgetActionHint(isOn ? "Disconnect" : "Connect")
            }
            .tint(WidgetTheme.tint)
            .disabled(!state.isConfigured)
        }
        .displayName("URnetwork")
        .description("Connect or disconnect the URnetwork VPN.")
    }
}

@available(iOS 18.0, macOS 26.0, *)
extension QuickConnectControl {

    struct Provider: ControlValueProvider {

        /// The gallery shows controls in their off state.
        var previewValue: QuickConnectState {
            QuickConnectState(isConfigured: true, isOn: false)
        }

        func currentValue() async throws -> QuickConnectState {
            await TunnelControlSupport.currentState()
        }
    }
}

#endif
