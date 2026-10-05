//
//  ReferralShareTests.swift
//  networkTests
//
//  Support inbox 1698: the share text had been the code alone since 2026-07,
//  so a friend on Android had no link that opens the app (or Play, with the
//  install referrer) with the code applied. The invitation now carries the
//  code's ur.io/c link after the message, which still names the code.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

struct ReferralShareTests {

    private let message = "Join me on URnetwork! Get the app and enter referral code AB12CD when you sign up."

    @Test func theLinkFollowsTheMessageOnItsOwnLine() {
        #expect(
            ReferralShare.text(message: message, link: "https://ur.io/c?bonus=AB12CD")
                == "\(message)\nhttps://ur.io/c?bonus=AB12CD"
        )
    }

    @Test func withoutALinkTheMessageStandsAlone() {
        #expect(ReferralShare.text(message: message, link: nil) == message)
        #expect(ReferralShare.text(message: message, link: "") == message)
    }

    @Test func theLinkTargetIsTheBonusCode() {
        #expect(ReferralShare.linkTarget(code: "AB12CD") == "bonus=AB12CD")
        #expect(ReferralShare.linkTarget(code: "9f1c-22ab") == "bonus=9f1c-22ab")
        // a code can never add a parameter to the link
        #expect(ReferralShare.linkTarget(code: "A&auth_code=x") == "bonus=A%26auth_code%3Dx")
    }

    @Test func theSdkBuildsTheUrIoConnectLink() {
        // the official space, as DeviceManager configures it
        let key = SdkNewNetworkSpaceKey("ur.io", "main")
        let values = SdkNetworkSpaceValues()
        values.linkHostName = "ur.io"
        let link = SdkConnectLinkUrl(key, values, ReferralShare.linkTarget(code: "AB12CD"))
        #expect(link == "https://ur.io/c?bonus=AB12CD")
    }

    @Test func noNetworkSpaceSharesTheMessageAlone() {
        let text = ReferralShare.text(code: "AB12CD", networkSpace: nil)
        #expect(text.contains("AB12CD"))
        #expect(!text.contains("https://"))
    }
}
