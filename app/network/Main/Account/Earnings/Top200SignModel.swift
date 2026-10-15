//
//  Top200SignModel.swift
//  URnetwork
//
//  The state of the Sign fleet binding screen (Earnings › Top 200): this
//  device's client id and client key, the binding field, its check, and the
//  signed payload. The device calls go over DeviceLocalRpc to the network
//  extension (it holds the client key) and block, so they run off the main
//  actor; the model itself is main-actor bound.
//
//  Signing needs a validated binding of this device and an explicit call to
//  `sign()`: a pasted or linked binding only fills the field. Editing the
//  field drops the payload and any sign still running for the old text.
//  Nothing is sent over the network and nothing here logs the binding or the
//  payload.
//

import Combine
import Foundation

/// The device the screen signs with.
protocol Top200SignDevice: AnyObject, Sendable {
    /// the client id in uuid form, or nil before the device has one
    func clientId() -> String?
    /// the Ed25519 client public key (0x hex); "" when the network extension's
    /// service is not connected. Blocks.
    func clientKey() -> String
    /// the 64-byte client signature (0x hex) over the binding digest. Blocks.
    func signFleetBinding(_ bindingJson: String) throws -> String
}

@MainActor
final class Top200SignModel: ObservableObject {

    @Published private(set) var clientId: String? = nil
    @Published private(set) var clientKey: String = ""
    /// whether the client key was asked for at least once
    @Published private(set) var keyLoaded = false
    @Published var bindingText: String = "" {
        didSet {
            if bindingText != oldValue {
                edited()
            }
        }
    }
    @Published private(set) var check: Top200BindingCheck = .empty
    @Published private(set) var isSigning = false
    @Published private(set) var payload: String? = nil
    /// the sdk's error text of the last sign, or "empty signature"
    @Published private(set) var signFailure: String? = nil
    /// the app link that opened the screen carried no readable binding
    @Published private(set) var linkInvalid = false

    private let device: Top200SignDevice
    /// bumped on every edit, so a sign of an older text is dropped
    private var editGeneration = 0

    init(device: Top200SignDevice, link: Top200SignDestination? = nil) {
        self.device = device
        if let link {
            open(link)
        }
    }

    /// The device's fleet manifest member entry, nil without both the id and the key.
    var memberEntry: String? {
        Top200Bindings.memberEntry(deviceClientId: clientId, deviceClientKey: clientKey)
    }

    var canSign: Bool {
        guard case .valid = check else {
            return false
        }
        return !isSigning && payload == nil
    }

    var error: Top200SignError? {
        if let signFailure {
            return .failed(signFailure)
        }
        switch check {
        case .invalid:
            return .invalid
        case .noKey:
            return .noKey
        case .otherDevice:
            return .otherDevice
        case .empty:
            return linkInvalid ? .invalid : nil
        case .valid:
            return nil
        }
    }

    /// Fills the field from an app link. Never signs.
    func open(_ link: Top200SignDestination) {
        if let text = link.bindingText {
            bindingText = text
        } else {
            bindingText = ""
            linkInvalid = true
            check = .empty
        }
    }

    /// Reads the device's client id and client key, off the main actor.
    func load() async {
        let device = self.device
        let (clientId, clientKey) = await Task.detached {
            (device.clientId(), device.clientKey())
        }.value
        self.clientId = clientId
        self.clientKey = clientKey
        keyLoaded = true
        recheck()
    }

    /// Signs the validated binding, off the main actor.
    func sign() async {
        guard canSign, case .valid(let text, _) = check else {
            return
        }
        let generation = editGeneration
        isSigning = true
        let device = self.device
        let result = await Task.detached { () -> Result<String, Error> in
            Result { try device.signFleetBinding(text) }
        }.value
        guard generation == editGeneration else {
            // the field changed while signing: the result is for another text
            return
        }
        isSigning = false
        switch result {
        case .success(let signature) where signature.isEmpty:
            signFailure = "empty signature"
        case .success(let signature):
            payload = Top200Bindings.payload(bindingText: text, signature: signature)
        case .failure(let error):
            signFailure = error.localizedDescription
        }
    }

    private func edited() {
        editGeneration += 1
        isSigning = false
        payload = nil
        signFailure = nil
        linkInvalid = false
        recheck()
    }

    private func recheck() {
        check = Top200Bindings.check(bindingText, deviceClientId: clientId, deviceClientKey: clientKey)
    }
}

/// The screen's inline errors, each a top200_sign_error_* string.
enum Top200SignError: Equatable {
    case invalid
    case otherDevice
    case noKey
    case failed(String)

    var message: String {
        switch self {
        case .invalid:
            return String(localized: "This is not a fleet binding. Copy the whole binding from the Top 200 page.")
        case .otherDevice:
            return String(localized: "This binding is for another device. A device signs only the binding with its own client ID and client key.")
        case .noKey:
            return String(localized: "This device's client key is not available right now. Start URnetwork on this device, then try again.")
        case .failed(let detail):
            return String(localized: "The binding could not be signed: \(detail)")
        }
    }
}
