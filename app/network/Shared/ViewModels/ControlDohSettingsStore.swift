//
//  ControlDohSettingsStore.swift
//  URnetwork
//

import Foundation
import SwiftUI
import URnetworkSdk

/**
 * The bootstrap DNS-over-HTTPS servers of a network space (P216), as the field
 * loads, checks and saves them.
 *
 * The space stores the list and applies it in place: a save swaps the client
 * strategy's DoH settings, and the space, a device bound to it and this screen
 * stay valid, so the app's own lookups take the new servers at once. The
 * packet tunnel reads the space from the app group when it starts, on iOS and
 * on macOS alike, so a running tunnel keeps the servers it started with until
 * it connects again, which the screen says.
 */

/// What the last save came to.
enum ControlDohSaveOutcome: Equatable {
    case saved
    /// the sdk error id of a url that does not validate, or of too many
    /// servers; nothing was saved
    case failed(errorId: String)
}

/// The strings of an sdk string list, in order.
func controlDohStrings(_ list: SdkStringList?) -> [String] {
    guard let list else {
        return []
    }
    return (0..<list.len()).map { list.get($0) }
}

/// The servers of the "Use China resolvers" preset, v4 first.
func controlDohChinaPreset() -> [String] {
    controlDohStrings(SdkRegionalControlDohUrls(ControlDohPreset.china))
}

/// The sdk's error id for the first line of `urls` that does not validate,
/// empty when every line does.
func controlDohValidationErrorId(_ urls: [String]) -> String {
    for url in urls {
        let errorId = SdkValidateControlDohUrl(url)
        if !errorId.isEmpty {
            return errorId
        }
    }
    return ""
}

/// The field of the active network space's bootstrap DoH servers: its text,
/// the check of each line, and the save.
@MainActor
final class ControlDohSettingsStore: ObservableObject {

    /// the field, one url per line
    @Published var text: String = "" {
        didSet {
            if text != oldValue {
                textChanged()
            }
        }
    }

    /// true once the space's servers are read, so the field never saves a
    /// blank over them
    @Published private(set) var loaded = false
    @Published private(set) var saving = false

    /// the outcome of the last save, until the field changes
    @Published private(set) var saveOutcome: ControlDohSaveOutcome? = nil
    /// The error id of the first line that does not validate, empty when every
    /// line does.
    @Published private(set) var validationErrorId: String = ""

    private var networkSpace: SdkNetworkSpace?

    /**
     * Loads the servers of `networkSpace`, the space the app has active.
     *
     * Opening the screen again on the same space keeps the field as it is, so
     * an edit survives a trip to another tab; a new screen starts from what
     * the space stores.
     */
    func setup(_ networkSpace: SdkNetworkSpace?) {
        if loaded && self.networkSpace === networkSpace {
            return
        }
        self.networkSpace = networkSpace
        reload()
    }

    /// Reads the space's servers again, replacing the field: an import with
    /// settings may have replaced them.
    func reload() {
        if let networkSpace {
            text = controlDohText(controlDohStrings(networkSpace.getControlDohUrls()))
            loaded = true
        } else {
            text = ""
            loaded = false
        }
        saveOutcome = nil
        // set here as well: a text equal to the one before skips didSet's
        validationErrorId = controlDohValidationErrorId(controlDohUrls(text))
    }

    /// An edit: the last save's outcome no longer applies, and each line is
    /// checked again.
    private func textChanged() {
        saveOutcome = nil
        validationErrorId = controlDohValidationErrorId(controlDohUrls(text))
    }

    /// The error shown under the field: what the last save answered, until the
    /// field changes (too many servers is only known then), else the check of
    /// each line as it is typed. nil when there is none.
    var errorId: String? {
        if case .failed(let errorId) = saveOutcome {
            return errorId
        }
        return validationErrorId.isEmpty ? nil : validationErrorId
    }

    /// "Use China resolvers": the preset replaces the field, one server per
    /// line. Nothing is saved until the user reviews it and saves.
    func useChinaPreset() {
        text = controlDohText(controlDohChinaPreset())
    }

    // MARK: save

    /**
     * Saves the field's servers. Every line must validate, otherwise nothing
     * is saved and the error id shows under the field, which keeps the text
     * as typed. On success the field shows the list the space read back,
     * which is normalized, without repeats, v4 first.
     *
     * The write persists through the space's manager and swaps the strategy's
     * DoH cache, which waits for its requests in flight, so it runs off the
     * main actor.
     */
    func save() async {
        await store(controlDohUrls(text))
    }

    /// "Use built-in servers only": clears the field and saves the empty list
    /// at once, which leaves the default servers alone.
    func reset() async {
        guard loaded, !saving else {
            return
        }
        text = ""
        await store([])
    }

    /// Writes `urls` to the space off the main actor and shows the list it
    /// read back, unless the space or the field changed meanwhile.
    private func store(_ urls: [String]) async {
        guard loaded, !saving, let networkSpace else {
            return
        }
        let savedText = text
        saving = true
        defer {
            saving = false
        }
        let (errorId, stored) = await Task.detached(priority: .userInitiated) { () -> (String, [String]) in
            let list = SdkNewStringList()
            for url in urls {
                list?.add(url)
            }
            let errorId = networkSpace.setControlDohUrls(list)
            return (errorId, controlDohStrings(networkSpace.getControlDohUrls()))
        }.value
        // an edit made meanwhile is kept, unsaved, and the outcome of the
        // text before it is not shown over it
        guard self.networkSpace === networkSpace, text == savedText else {
            return
        }
        if errorId.isEmpty {
            text = controlDohText(stored)
            saveOutcome = .saved
        } else {
            saveOutcome = .failed(errorId: errorId)
        }
    }
}
