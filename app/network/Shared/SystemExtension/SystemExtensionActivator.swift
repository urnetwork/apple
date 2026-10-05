//
//  SystemExtensionActivator.swift
//  URnetwork
//
//  Asks macOS to install a SYSTEM extension embedded in this app bundle
//  (Contents/Library/SystemExtensions). Two use it: the direct-download
//  build (`DIRECT_DOWNLOAD`) for its packet tunnel
//  (URnetworkVPNSystem.systemextension, bundle id
//  TunnelProviderIdentity.bundleIdentifier -- the same provider id the
//  tunnel manager uses), and both macOS builds for the split tunnel
//  (TunnelProviderIdentity.splitTunnelBundleIdentifier, activated by
//  SplitTunnelProxyController once an app is excluded).
//
//  The tunnel's is driven at launch and again before every connect:
//  activation is idempotent, so the second call is free when the extension
//  is already installed, and it is what re-prompts the user who skipped the
//  one-time System Settings approval the first time. The decisions live in
//  SystemExtensionActivation.swift; this file only talks to the framework
//  and draws the tunnel's prompt.
//

#if os(macOS)

import Foundation
import SwiftUI
import SystemExtensions
import AppKit

final class SystemExtensionActivator: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {

    /// PRODUCT_BUNDLE_IDENTIFIER of the extension's target. The default is
    /// the URnetworkVPNSystem target's, what VPNManager installs as
    /// `providerBundleIdentifier`.
    let extensionBundleIdentifier: String

    init(extensionBundleIdentifier: String = TunnelProviderIdentity.bundleIdentifier) {
        self.extensionBundleIdentifier = extensionBundleIdentifier
        super.init()
    }

    /// System Settings > General > Login Items & Extensions > Network Extensions.
    static let networkExtensionsSettingsURL = URL(string:
        "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier="
        + "com.apple.system_extension.network_extension.extension-point")!

    @Published private(set) var state: SystemExtensionActivationState = .idle
    /// The prompt is shown whenever the state first needs the user, and
    /// stays dismissed until the state needs them again.
    @Published var isPromptPresented = false

    private var request: OSSystemExtensionRequest?

    var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "URnetwork"
    }

    func activateIfNeeded() {
        guard SystemExtensionActivation.shouldSubmit(from: state) else { return }
        let location = SystemExtensionInstallLocation.classify(bundlePath: Bundle.main.bundlePath)
        apply(.activationRequested(location))
        guard location.canActivate else { return }

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        self.request = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.networkExtensionsSettingsURL)
    }

    /// Copies this bundle to /Applications and relaunches from there.
    ///
    /// The app is sandboxed, and the sandbox denies writes to /Applications
    /// without a user-granted bookmark, so the copy is expected to fail for a
    /// plain DMG launch. In that case the bundle is revealed in Finder next
    /// to an Applications folder the DMG carries, and the prompt copy tells
    /// the user to drag it. TODO(hardware): verify on a notarized DMG build
    /// which of the two paths a sandboxed Developer ID app takes, and whether
    /// an NSOpenPanel-granted /Applications bookmark is worth adding.
    func moveToApplications() {
        let source = URL(fileURLWithPath: Bundle.main.bundlePath)
        let destination = URL(fileURLWithPath:
            SystemExtensionInstallLocation.moveDestination(bundlePath: source.path))
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            NSWorkspace.shared.activateFileViewerSelecting([source])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func apply(_ event: SystemExtensionActivationEvent) {
        let needed = state.needsUserAction
        state = SystemExtensionActivation.reduce(state, event)
        if state.needsUserAction && !needed {
            isPromptPresented = true
        }
        if !state.needsUserAction {
            isPromptPresented = false
        }
    }

    // MARK: OSSystemExtensionRequestDelegate (queue: .main)

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        apply(.replacing(
            existingVersion: existing.bundleShortVersion,
            candidateVersion: ext.bundleShortVersion
        ))
        switch SystemExtensionActivation.replacementDecision(
            existingVersion: existing.bundleShortVersion,
            candidateVersion: ext.bundleShortVersion
        ) {
        case .replace:
            return .replace
        case .cancel:
            return .cancel
        }
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        apply(.needsUserApproval)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        self.request = nil
        apply(.finished(willCompleteAfterReboot: result == .willCompleteAfterReboot))
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        self.request = nil
        apply(.failed(Self.failure(for: error)))
    }

    /// Exhaustive over the framework's codes, so a new code is a compile
    /// error here rather than a silent `other`.
    static func failure(for error: Error) -> SystemExtensionActivationFailure {
        guard let code = (error as? OSSystemExtensionError)?.code else {
            let nsError = error as NSError
            return .other(code: nsError.code, description: nsError.localizedDescription)
        }
        switch code {
        case .unsupportedParentBundleLocation:
            return .unsupportedParentBundleLocation
        case .missingEntitlement:
            return .missingEntitlement
        case .extensionNotFound:
            return .extensionNotFound
        case .codeSignatureInvalid:
            return .codeSignatureInvalid
        case .validationFailed:
            return .validationFailed
        case .forbiddenBySystemPolicy:
            return .forbiddenBySystemPolicy
        case .requestCanceled:
            return .requestCanceled
        case .requestSuperseded:
            return .requestSuperseded
        case .authorizationRequired:
            return .authorizationRequired
        case .unknown, .extensionMissingIdentifier, .duplicateExtensionIdentifer,
             .unknownExtensionCategory:
            return .other(code: code.rawValue, description: error.localizedDescription)
        @unknown default:
            return .other(code: code.rawValue, description: error.localizedDescription)
        }
    }
}

/// The packet tunnel's one-time approval / move-to-Applications prompt
/// (direct-download build).
struct SystemExtensionApprovalView: View {

    @EnvironmentObject var activator: SystemExtensionActivator
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let state = activator.state
        let appName = activator.appName
        VStack(alignment: .leading, spacing: 16) {
            Text(SystemExtensionActivationCopy.title(for: state, appName: appName) ?? "")
                .font(themeManager.currentTheme.secondaryTitleFont)
            Text(SystemExtensionActivationCopy.message(for: state, appName: appName) ?? "")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not now") {
                    activator.isPromptPresented = false
                }
                if let action = SystemExtensionActivationCopy.primaryAction(for: state) {
                    Button(action) {
                        if state.needsMoveToApplications {
                            activator.moveToApplications()
                        } else {
                            activator.openSystemSettings()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(themeManager.currentTheme.backgroundColor)
    }
}

#endif
