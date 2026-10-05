//
//  VlessSettingsStore.swift
//  URnetwork
//

import Foundation
import SwiftUI
import URnetworkSdk

/**
 * The VLESS settings of a network space (connect issue 91), as the editor
 * loads, checks and saves them.
 *
 * The space stores the settings and applies them in place: a save replaces
 * the client strategy's VLESS dialer, and the space, a device bound to it and
 * this screen stay valid. The packet tunnel reads the space from its VPN
 * profile when it starts, on iOS and on macOS alike, so a running tunnel keeps
 * the settings it started with until it connects again.
 */

// MARK: - sdk values

extension VlessSettingsValues {

    init(_ settings: SdkVlessSettings) {
        self.init(
            enabled: settings.enabled,
            name: settings.name,
            address: settings.address,
            port: settings.port,
            id: settings.id_,
            flow: settings.flow,
            network: settings.network,
            security: settings.security,
            serverName: settings.serverName,
            fingerprint: settings.fingerprint,
            alpn: settings.alpn,
            allowInsecure: settings.allowInsecure,
            publicKey: settings.publicKey,
            shortId: settings.shortId,
            spiderX: settings.spiderX,
            path: settings.path,
            host: settings.host
        )
    }

    /// New sdk settings with exactly these values.
    func sdkSettings() -> SdkVlessSettings? {
        guard let settings = SdkVlessSettings() else {
            return nil
        }
        settings.enabled = enabled
        settings.name = name
        settings.address = address
        settings.port = port
        settings.id_ = id
        settings.flow = flow
        settings.network = network
        settings.security = security
        settings.serverName = serverName
        settings.fingerprint = fingerprint
        settings.alpn = alpn
        settings.allowInsecure = allowInsecure
        settings.publicKey = publicKey
        settings.shortId = shortId
        settings.spiderX = spiderX
        settings.path = path
        settings.host = host
        return settings
    }
}

// MARK: - store

/// What the last save came to.
enum VlessSettingsSaveOutcome: Equatable {
    case saved
    /// the sdk error id of settings that do not validate; nothing was saved
    case failed(errorId: String)
}

@MainActor
final class VlessSettingsStore: ObservableObject {

    /// the editable settings, bound by the form
    @Published var form = VlessSettingsForm() {
        didSet {
            if form != oldValue {
                formChanged()
            }
        }
    }

    /// the link field
    @Published var link: String = "" {
        didSet {
            if link != oldValue {
                linkErrorId = nil
            }
        }
    }

    /// true once the space's settings are read, so the form never saves a
    /// blank over them
    @Published private(set) var loaded = false
    @Published private(set) var saving = false

    /// the error id of the last link that did not read
    @Published private(set) var linkErrorId: String? = nil
    /// true from Copy link until the form changes
    @Published private(set) var linkCopied = false
    /// the outcome of the last save, until the form changes
    @Published private(set) var saveOutcome: VlessSettingsSaveOutcome? = nil
    /// The error id of the form as it stands, empty when the settings
    /// validate. Copy link is offered only then.
    @Published private(set) var validationErrorId: String = ""

    private var networkSpace: SdkNetworkSpace?

    /**
     * Loads the settings of `networkSpace`, the space the app has active.
     *
     * Opening the screen again on the same space keeps the form as it is, so
     * an edit survives a trip to another tab; a new screen starts from what
     * the space stores.
     */
    func setup(_ networkSpace: SdkNetworkSpace?) {
        if loaded && self.networkSpace === networkSpace {
            return
        }
        self.networkSpace = networkSpace
        loaded = false
        if let settings = networkSpace?.getVlessSettings() {
            form = VlessSettingsForm(VlessSettingsValues(settings))
            loaded = true
        } else {
            form = VlessSettingsForm()
        }
        link = ""
        linkErrorId = nil
        linkCopied = false
        saveOutcome = nil
        // set here as well: a form equal to the one before skips didSet's
        validationErrorId = vlessSettingsValidationErrorId(form.settings)
    }

    private func formChanged() {
        saveOutcome = nil
        linkCopied = false
        validationErrorId = vlessSettingsValidationErrorId(form.settings)
    }

    // MARK: link

    /**
     * Paste link: text on the clipboard replaces the link field, then the
     * field is read. With nothing on the clipboard the field's own text is
     * read, so a link typed or pasted into the field works the same way.
     */
    func pasteLink(_ clipboard: String?) {
        if let clipboard, !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            link = clipboard
        }
        readLink()
    }

    /// Reads the link field. A link that reads replaces the whole form with
    /// its settings, enabled; one that does not leaves the form as it is and
    /// says why.
    func readLink() {
        guard let result = SdkParseVlessLink(link) else {
            linkErrorId = VlessSettingsErrorId.linkInvalid
            return
        }
        guard result.error.isEmpty, let settings = result.settings else {
            linkErrorId = result.error.isEmpty ? VlessSettingsErrorId.linkInvalid : result.error
            return
        }
        form = VlessSettingsForm(VlessSettingsValues(settings))
        link = ""
        linkErrorId = nil
    }

    /// The share link of the form, nil when the form does not validate.
    func shareLink() -> String? {
        guard let settings = form.settings.sdkSettings() else {
            return nil
        }
        let link = SdkVlessSettingsLink(settings)
        return link.isEmpty ? nil : link
    }

    func didCopyLink() {
        linkCopied = true
    }

    // MARK: save

    /**
     * Saves the form to the space and shows what the space then holds. The
     * write persists through the space's manager and replaces the strategy's
     * dialer, so it runs off the main actor, as the developer settings write
     * the space.
     *
     * Reading the settings back is what the next screen loads: the sdk trims
     * and lower-cases what a form leaves, and settings that are off and name
     * no server are cleared, which reads back as the new-form defaults.
     */
    func save() async {
        guard loaded, !saving, let networkSpace, let settings = form.settings.sdkSettings() else {
            return
        }
        let savedForm = form
        saving = true
        defer {
            saving = false
        }
        let (errorId, stored) = await Task.detached(priority: .userInitiated) { () -> (String, VlessSettingsValues?) in
            let errorId = networkSpace.setVlessSettings(settings)
            let stored = networkSpace.getVlessSettings().map { VlessSettingsValues($0) }
            return (errorId, stored)
        }.value
        // an edit made meanwhile is kept, unsaved, and the outcome of the
        // form before it is not shown over it
        guard self.networkSpace === networkSpace, form == savedForm else {
            return
        }
        if errorId.isEmpty {
            if let stored {
                form = VlessSettingsForm(stored)
            }
            saveOutcome = .saved
        } else {
            saveOutcome = .failed(errorId: errorId)
        }
    }
}

/// The sdk's error id for `settings`, empty when they validate.
func vlessSettingsValidationErrorId(_ settings: VlessSettingsValues) -> String {
    guard let sdkSettings = settings.sdkSettings() else {
        return VlessSettingsErrorId.linkInvalid
    }
    return SdkValidateVlessSettings(sdkSettings)
}
