//
//  ReferralCodeFieldTests.swift
//  networkTests
//
//  Support inbox 1698: invitees missed the referral code entry, a faint
//  button under Continue that opened a sheet. Sign-up now shows the optional
//  field above Continue (the Windows sign-up's bonus code box); what the typed
//  text means and what the create call carries are pinned here, as is the
//  Referrals card's "Add referral code" action.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

@MainActor
struct ReferralCodeFieldTests {

    private struct CheckError: Error {}

    @MainActor
    private final class Recorder {
        var asked: [String] = []
        var entry: ReferralCodeEntry?
    }

    private static func result(valid: Bool, capped: Bool = false) -> SdkValidateReferralCodeResult {
        let result = SdkValidateReferralCodeResult()
        result.isValid = valid
        result.isCapped = capped
        return result
    }

    // a pause long enough that only checkNow() asks
    private static let held: Duration = .seconds(600)

    @Test func theCodeIsTrimmedAndUpperCased() {
        #expect(ReferralCodeField.normalize("  ab12cd \n") == "AB12CD")
        #expect(ReferralCodeField.normalize("9f1c-22ab") == "9F1C-22AB")
        #expect(ReferralCodeField.normalize("   ") == "")
    }

    @Test func onlyACodeIsChecked() {
        #expect(ReferralCodeField.shouldCheck(" AB12CD"))
        #expect(!ReferralCodeField.shouldCheck(""))
        #expect(!ReferralCodeField.shouldCheck("  "))
    }

    @Test func theServersAnswerIsTheVerdict() {
        #expect(ReferralCodeField.verdict(valid: true, capped: false) == .valid)
        #expect(ReferralCodeField.verdict(valid: false, capped: false) == .invalid)
        #expect(ReferralCodeField.verdict(valid: true, capped: true) == .capped)
    }

    @Test func signUpCarriesATypedCode() {
        for verdict in [ReferralCodeVerdict.valid, .unchecked, .checking, .checkFailed] {
            #expect(ReferralCodeField.createCode(input: " ab12cd ", verdict: verdict) == "AB12CD")
        }
        #expect(ReferralCodeField.createCode(input: "AB12CD", verdict: .invalid) == nil)
        #expect(ReferralCodeField.createCode(input: "AB12CD", verdict: .capped) == nil)
        #expect(ReferralCodeField.createCode(input: "  ", verdict: .valid) == nil)
    }

    @Test func checkingAsksWithTheNormalizedCode() async {
        let recorder = Recorder()
        let entry = ReferralCodeEntry(checkDelay: Self.held, validate: { code in
            await MainActor.run { recorder.asked.append(code) }
            return Self.result(valid: true)
        })
        entry.code = " ab12cd "
        await entry.checkNow()
        #expect(recorder.asked == ["AB12CD"])
        #expect(entry.verdict == .valid)
        #expect(entry.isApplied)
        #expect(entry.createCode == "AB12CD")
    }

    @Test func continueRightAfterTypingCarriesTheCode() {
        let entry = ReferralCodeEntry(checkDelay: Self.held, validate: { _ in Self.result(valid: true) })
        entry.code = "AB12CD"
        #expect(entry.verdict == .unchecked)
        #expect(entry.createCode == "AB12CD")
    }

    @Test func aCheckThatFailsStillCarriesTheCode() async {
        let entry = ReferralCodeEntry(checkDelay: Self.held, validate: { _ in throw CheckError() })
        entry.code = "AB12CD"
        await entry.checkNow()
        #expect(entry.verdict == .checkFailed)
        #expect(entry.validationState == .invalid)
        #expect(entry.createCode == "AB12CD")
    }

    @Test func aRejectedCodeIsNotCarried() async {
        let invalid = ReferralCodeEntry(checkDelay: Self.held, validate: { _ in Self.result(valid: false) })
        invalid.code = "AB12CD"
        await invalid.checkNow()
        #expect(invalid.verdict == .invalid)
        #expect(invalid.createCode == nil)

        let capped = ReferralCodeEntry(checkDelay: Self.held, validate: { _ in Self.result(valid: true, capped: true) })
        capped.code = "AB12CD"
        await capped.checkNow()
        #expect(capped.verdict == .capped)
        #expect(capped.createCode == nil)
    }

    @Test func anAnswerForChangedTextIsDropped() async {
        let recorder = Recorder()
        let entry = ReferralCodeEntry(checkDelay: Self.held, validate: { _ in
            // the user types another code while the check is out
            await MainActor.run { recorder.entry?.code = "ZZ99ZZ" }
            return Self.result(valid: true)
        })
        recorder.entry = entry
        entry.code = "AB12CD"
        await entry.checkNow()
        #expect(entry.verdict == .unchecked)
        #expect(!entry.isApplied)
        #expect(entry.createCode == "ZZ99ZZ")
    }

    @Test func anEmptyFieldIsNotChecked() async {
        let recorder = Recorder()
        let entry = ReferralCodeEntry(checkDelay: .zero, validate: { code in
            await MainActor.run { recorder.asked.append(code) }
            return Self.result(valid: true)
        })
        entry.code = "   "
        await entry.checkNow()
        #expect(recorder.asked.isEmpty)
        #expect(entry.createCode == nil)
    }

    @Test func typingChecksTheCodeAfterThePause() async {
        let recorder = Recorder()
        let entry = ReferralCodeEntry(checkDelay: .milliseconds(10), validate: { code in
            await MainActor.run { recorder.asked.append(code) }
            return Self.result(valid: true)
        })
        entry.code = "ab12cd"
        // nothing is asked before the pause
        #expect(recorder.asked.isEmpty)
        // the check the edit scheduled: it waits out the pause, then asks
        await entry.pendingCheck?.value
        #expect(recorder.asked == ["AB12CD"])
        #expect(entry.verdict == .valid)
    }

    @Test func noReferralNetworkOffersTheCodeEntry() {
        #expect(ReferralNetworkAction.of(networkName: nil) == .addCode)
        #expect(ReferralNetworkAction.of(networkName: "") == .addCode)
        #expect(ReferralNetworkAction.of(networkName: "parent_network") == .update(networkName: "parent_network"))
    }
}
