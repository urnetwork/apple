//
//  ExtenderProvideRowTests.swift
//  networkTests
//

import Foundation
import SwiftUI
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The Extender row's reading of the provider extender status (EXTENDER.md N3,
 * N7): whether the row shows, the color of its dot and its one line of text,
 * picked by `State` and, in the error state, by `ErrorCase` alone; and the
 * switch's local repaint before the next status arrives. The state rule itself
 * is the sdk's and is table-tested there.
 */
struct ExtenderProvideRowTests {

    private static let everyState = [
        SdkExtenderProvideStateOff,
        SdkExtenderProvideStateNotProviding,
        SdkExtenderProvideStateSettingUp,
        SdkExtenderProvideStateActive,
        SdkExtenderProvideStateError,
    ]

    private func reading(
        state: String,
        errorCase: String = "",
        reason: String = "",
        activatedV4: Bool = false,
        activatedV6: Bool = false,
        lastActivationRefused: Bool = false
    ) -> ExtenderProvideDisplay {
        ExtenderProvideDisplay.of(status: ExtenderProvideStatusModel(
            supported: true,
            state: state,
            errorCase: errorCase,
            reason: reason,
            activatedV4: activatedV4,
            activatedV6: activatedV6,
            lastActivationRefused: lastActivationRefused
        ))
    }

    // MARK: visibility

    // N1: a device without the role shows no row whatever state it reports,
    // and a device with the role shows it in every state
    @Test func unsupportedIsHidden() {
        #expect(!ExtenderProvideDisplay.of(status: .unsupported).visible)
        for state in Self.everyState + ["something-newer"] {
            let unsupported = ExtenderProvideStatusModel(supported: false, state: state)
            #expect(!ExtenderProvideDisplay.of(status: unsupported).visible)
            let supported = ExtenderProvideStatusModel(supported: true, state: state)
            #expect(ExtenderProvideDisplay.of(status: supported).visible)
        }
    }

    // N2: what the app holds before any device reports
    @Test func theUnsupportedStatusIsOffAndNotRunning() {
        let status = ExtenderProvideStatusModel.unsupported
        #expect(!status.supported)
        #expect(status.state == SdkExtenderProvideStateOff)
        #expect(!status.enabled)
    }

    @Test @MainActor func aManagerWithNoDeviceHidesTheRow() {
        let manager = DeviceManager(startupMode: .production, automaticallyInitialize: false)
        #expect(manager.extenderProvideStatus == .unsupported)
        #expect(!manager.extenderProvideDisplay.visible)
        #expect(manager.extenderProvideGuess == nil)
        // the setting is on before any read, as the sdk's default
        #expect(manager.provideExtender)
    }

    // the model keeps exactly the fields the row and the section read
    @Test func theModelReadsTheSdkStatus() {
        let sdk = SdkExtenderProvideStatus()
        sdk.supported = true
        sdk.state = SdkExtenderProvideStateActive
        sdk.errorCase = ""
        sdk.reason = "dial tcp6 [2001:db8::1]:443: connect: no route to host"
        sdk.activatedV4 = true
        sdk.activatedV6 = false
        sdk.lastActivationRefused = true
        sdk.enabled = true
        // fields only the sdk's state rule reads
        sdk.startError = "not read"
        sdk.listening = false
        sdk.listenError = "not read"
        sdk.lastActivationError = "not read"
        sdk.revokedTime = 1_700_000_000_000
        #expect(ExtenderProvideStatusModel(sdk) == ExtenderProvideStatusModel(
            supported: true,
            state: SdkExtenderProvideStateActive,
            errorCase: "",
            reason: "dial tcp6 [2001:db8::1]:443: connect: no route to host",
            activatedV4: true,
            activatedV6: false,
            lastActivationRefused: true,
            enabled: true
        ))
    }

    // MARK: every case of N3

    @Test func offIsGrey() {
        let row = reading(state: SdkExtenderProvideStateOff)
        #expect(row.dot == .grey)
        #expect(row.text == "Off")
        #expect(!row.isError)
    }

    @Test func notProvidingIsGrey() {
        let row = reading(state: SdkExtenderProvideStateNotProviding)
        #expect(row.dot == .grey)
        #expect(row.text == "Not providing")
        #expect(!row.isError)
    }

    @Test func settingUpIsYellow() {
        let row = reading(state: SdkExtenderProvideStateSettingUp)
        #expect(row.dot == .yellow)
        #expect(row.text == "Setting up")
        #expect(!row.isError)
    }

    @Test func activeIsGreen() {
        let row = reading(state: SdkExtenderProvideStateActive, activatedV4: true, activatedV6: true)
        #expect(row.dot == .green)
        #expect(row.text == "Active · IPv4 and IPv6")
        #expect(!row.isError)
    }

    @Test func revokedIsRedWithNoReason() {
        let row = reading(
            state: SdkExtenderProvideStateError,
            errorCase: SdkExtenderProvideErrorRevoked
        )
        #expect(row.dot == .red)
        #expect(row.text == "Revoked by the operator")
        #expect(row.isError)
    }

    @Test func aStartFailureIsRedWithItsReason() {
        let row = reading(
            state: SdkExtenderProvideStateError,
            errorCase: SdkExtenderProvideErrorStart,
            reason: "no extender directory"
        )
        #expect(row.dot == .red)
        #expect(row.text == "Could not start: no extender directory")
        #expect(row.isError)
    }

    @Test func aListenFailureIsRedWithEveryCarrier() {
        let reason = "tcp 443: bind: permission denied; udp 443: bind: permission denied"
        let row = reading(
            state: SdkExtenderProvideStateError,
            errorCase: SdkExtenderProvideErrorListen,
            reason: reason
        )
        #expect(row.dot == .red)
        #expect(row.text == "Could not listen: \(reason)")
        #expect(row.isError)
    }

    @Test func aRefusedActivationIsRedWithTheOperatorsReason() {
        let row = reading(
            state: SdkExtenderProvideStateError,
            errorCase: SdkExtenderProvideErrorActivationRefused,
            reason: "the operator refused the activation",
            lastActivationRefused: true
        )
        #expect(row.dot == .red)
        #expect(row.text == "Activation refused: the operator refused the activation")
        #expect(row.isError)
    }

    @Test func aFailedActivationIsRedWithTheError() {
        let row = reading(
            state: SdkExtenderProvideStateError,
            errorCase: SdkExtenderProvideErrorActivationFailed,
            reason: "context deadline exceeded"
        )
        #expect(row.dot == .red)
        #expect(row.text == "Activation failed: context deadline exceeded")
        #expect(row.isError)
    }

    // N7: an error's label comes from `ErrorCase` alone. Every other field here
    // points the other way, and none of it moves the text
    @Test func eachErrorCaseIsPickedByTheErrorCaseAlone() {
        let error = SdkExtenderProvideStateError
        #expect(reading(
            state: error,
            errorCase: SdkExtenderProvideErrorActivationRefused,
            reason: "x",
            activatedV4: true,
            activatedV6: true,
            lastActivationRefused: false
        ).text == "Activation refused: x")
        #expect(reading(
            state: error,
            errorCase: SdkExtenderProvideErrorActivationFailed,
            reason: "x",
            activatedV4: true,
            lastActivationRefused: true
        ).text == "Activation failed: x")
        #expect(reading(
            state: error,
            errorCase: SdkExtenderProvideErrorRevoked,
            reason: "x",
            lastActivationRefused: true
        ).text == "Revoked by the operator")
        #expect(reading(
            state: error,
            errorCase: SdkExtenderProvideErrorStart,
            reason: "x",
            activatedV6: true,
            lastActivationRefused: true
        ).text == "Could not start: x")
        #expect(reading(
            state: error,
            errorCase: SdkExtenderProvideErrorListen,
            reason: "x",
            activatedV4: true,
            lastActivationRefused: true
        ).text == "Could not listen: x")
    }

    // phase 11: a refusal and a request error render as distinct cases, even
    // over the same text
    @Test func aRefusalAndARequestErrorAreDistinct() {
        let refused = reading(
            state: SdkExtenderProvideStateError,
            errorCase: SdkExtenderProvideErrorActivationRefused,
            reason: "same text"
        )
        let failed = reading(
            state: SdkExtenderProvideStateError,
            errorCase: SdkExtenderProvideErrorActivationFailed,
            reason: "same text"
        )
        #expect(refused.text != failed.text)
        #expect(refused.dot == .red)
        #expect(failed.dot == .red)
    }

    // MARK: the active line

    @Test func theThreeFamilyTexts() {
        let active = SdkExtenderProvideStateActive
        #expect(reading(state: active, activatedV4: true, activatedV6: true).text == "Active · IPv4 and IPv6")
        #expect(reading(state: active, activatedV4: true).text == "Active · IPv4")
        #expect(reading(state: active, activatedV6: true).text == "Active · IPv6")
    }

    @Test func theActiveLineCarriesTheOtherFamilysRefusal() {
        let row = reading(
            state: SdkExtenderProvideStateActive,
            reason: "the operator refused the activation",
            activatedV4: true,
            lastActivationRefused: true
        )
        #expect(row.dot == .green)
        #expect(row.text == "Active · IPv4 · Activation refused: the operator refused the activation")
        #expect(!row.isError)
    }

    @Test func theActiveLineCarriesTheOtherFamilysFailure() {
        let row = reading(
            state: SdkExtenderProvideStateActive,
            reason: "dial tcp4 192.0.2.1:443: i/o timeout",
            activatedV6: true
        )
        #expect(row.dot == .green)
        #expect(row.text == "Active · IPv6 · Activation failed: dial tcp4 192.0.2.1:443: i/o timeout")
        #expect(!row.isError)
    }

    // MARK: what this app does not know

    @Test func anUnknownErrorCaseRendersTheReasonBare() {
        let row = reading(
            state: SdkExtenderProvideStateError,
            errorCase: "something-newer",
            reason: "a newer failure"
        )
        #expect(row.dot == .red)
        #expect(row.text == "a newer failure")
        #expect(row.isError)
    }

    @Test func anUnknownStateRendersTheReasonBareInGrey() {
        let row = reading(state: "something-newer", reason: "a newer state")
        #expect(row.dot == .grey)
        #expect(row.text == "a newer state")
        #expect(!row.isError)
    }

    // MARK: the switch's guess

    @Test func turningOnWhileProvidingGuessesSettingUp() {
        let guess = ExtenderProvideDisplay.guess(on: true, providing: true)
        #expect(guess.visible)
        #expect(guess.dot == .yellow)
        #expect(guess.text == "Setting up")
    }

    @Test func turningOnWhileNotProvidingGuessesNotProviding() {
        let guess = ExtenderProvideDisplay.guess(on: true, providing: false)
        #expect(guess.visible)
        #expect(guess.dot == .grey)
        #expect(guess.text == "Not providing")
    }

    @Test func turningOffGuessesOff() {
        for providing in [false, true] {
            let guess = ExtenderProvideDisplay.guess(on: false, providing: providing)
            #expect(guess.visible)
            #expect(guess.dot == .grey)
            #expect(guess.text == "Off")
        }
    }

    // MARK: colors

    // grey is the theme's muted text; the rest are the provide glyph's assets
    @Test func theDotColors() {
        let muted = Color(red: 0.6, green: 0.6, blue: 0.6)
        #expect(ExtenderProvideDot.grey.color(mutedColor: muted) == muted)
        #expect(ExtenderProvideDot.yellow.color(mutedColor: muted) == .urYellow)
        #expect(ExtenderProvideDot.green.color(mutedColor: muted) == .urGreen)
        #expect(ExtenderProvideDot.red.color(mutedColor: muted) == .urCoral)
    }
}
