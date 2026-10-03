import XCTest
import URnetworkSdk
@testable import URnetwork

// After a rate limit the screens kept Resend / Send enabled, so the user could
// only collect more refusals. They now disable it until the server's retry time
// and count the minutes down. The clock is injected; nothing waits.
final class SendCooldownTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    func testCooldownCountsDown() {
        let cooldown = SendCooldown.after(.rateLimited(minutes: 5), retryAfterSeconds: 300, now: start)!

        XCTAssertEqual(cooldown.notice(at: start), .rateLimited(minutes: 5))
        XCTAssertEqual(cooldown.notice(at: start.addingTimeInterval(61)), .rateLimited(minutes: 4))
        XCTAssertEqual(cooldown.notice(at: start.addingTimeInterval(299)), .rateLimited(minutes: 1))
        XCTAssertTrue(cooldown.isActive(at: start.addingTimeInterval(299)))
        XCTAssertNil(cooldown.notice(at: start.addingTimeInterval(300)))
        XCTAssertFalse(cooldown.isActive(at: start.addingTimeInterval(300)))
    }

    func testOnlyRateLimitHasCooldown() {
        XCTAssertNil(SendCooldown.after(.sent, now: start))
        XCTAssertNil(SendCooldown.after(.sendFailed, now: start))
        XCTAssertNil(SendCooldown.after(.serverMessage("no"), now: start))
        // without the server's seconds, the (rounded up) minutes
        XCTAssertEqual(SendCooldown.after(.rateLimited(minutes: 2), now: start)?.until, start.addingTimeInterval(120))
    }

    @MainActor
    func testVerifyScreenOpenedRateLimitedDisablesResendUntilRetry() {
        let clock = Clock(start)
        let viewModel = CreateNetworkVerifyView.ViewModel(api: nil, userAuth: "a@example.com", sendNotice: .rateLimited(minutes: 5), now: { clock.now })

        XCTAssertFalse(viewModel.resetBtnEnabled)
        XCTAssertEqual(viewModel.resendErrorMessage, VerifySendNotice.rateLimited(minutes: 5).errorMessage)

        clock.now = start.addingTimeInterval(241)
        viewModel.tick()
        XCTAssertFalse(viewModel.resetBtnEnabled)
        XCTAssertEqual(viewModel.resendErrorMessage, VerifySendNotice.rateLimited(minutes: 1).errorMessage)

        clock.now = start.addingTimeInterval(300)
        viewModel.tick()
        XCTAssertTrue(viewModel.resetBtnEnabled)
        XCTAssertNil(viewModel.resendErrorMessage)
    }

    @MainActor
    func testRateLimitedResendDisablesResendUntilRetry() {
        let clock = Clock(start)
        let viewModel = CreateNetworkVerifyView.ViewModel(api: nil, userAuth: "a@example.com", sendNotice: .sent, now: { clock.now })

        viewModel.applyResendNotice(.rateLimited(minutes: 3), retryAfterSeconds: 150)
        XCTAssertFalse(viewModel.resetBtnEnabled)
        XCTAssertEqual(viewModel.resendErrorMessage, VerifySendNotice.rateLimited(minutes: 3).errorMessage)

        clock.now = start.addingTimeInterval(149)
        viewModel.tick()
        XCTAssertFalse(viewModel.resetBtnEnabled)
        XCTAssertEqual(viewModel.resendErrorMessage, VerifySendNotice.rateLimited(minutes: 1).errorMessage)

        clock.now = start.addingTimeInterval(150)
        viewModel.tick()
        XCTAssertTrue(viewModel.resetBtnEnabled)

        // any other failure leaves Resend enabled so the user can retry
        viewModel.applyResendNotice(.sendFailed, retryAfterSeconds: 0)
        XCTAssertTrue(viewModel.resetBtnEnabled)
    }

    @MainActor
    func testRateLimitedResetDisablesSendUntilRetry() {
        let clock = Clock(start)
        let viewModel = ResetPasswordView.ViewModel(api: SdkApi(), now: { clock.now })

        viewModel.applyNotice(.rateLimited(minutes: 5), retryAfterSeconds: 300)
        XCTAssertFalse(viewModel.sendEnabled)
        XCTAssertEqual(viewModel.errorMessage, VerifySendNotice.rateLimited(minutes: 5).resetErrorMessage)

        clock.now = start.addingTimeInterval(299)
        viewModel.tick()
        XCTAssertFalse(viewModel.sendEnabled)
        XCTAssertEqual(viewModel.errorMessage, VerifySendNotice.rateLimited(minutes: 1).resetErrorMessage)

        clock.now = start.addingTimeInterval(300)
        viewModel.tick()
        XCTAssertTrue(viewModel.sendEnabled)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testRateLimitedProfileResetDisablesUpdatePasswordUntilRetry() {
        let clock = Clock(start)
        let viewModel = ProfileView.ViewModel(api: SdkApi(), now: { clock.now })

        viewModel.applyPasswordResetNotice(.rateLimited(minutes: 5), retryAfterSeconds: 300)
        XCTAssertFalse(viewModel.passwordResetEnabled)

        clock.now = start.addingTimeInterval(300)
        viewModel.tick()
        XCTAssertTrue(viewModel.passwordResetEnabled)
        XCTAssertNil(viewModel.sendPasswordResetLinkError)
    }
}
