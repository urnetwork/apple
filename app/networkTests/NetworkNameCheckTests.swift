//
//  NetworkNameCheckTests.swift
//  networkTests
//
//  The create network form marked a name whose availability check errored
//  as invalid, so Create stayed disabled until the name was edited, with no
//  retry and no timeout. A failed check is not a verdict on the name: it now
//  allows Create (network create checks the name again on the server), is
//  retried three times, and a check that never answers fails after 15 s.
//  Mirrors android NetworkNameCheckTest.kt. The clock and the online check
//  are fakes; nothing waits.
//

import Foundation
import Testing
import SwiftUI
import URnetworkSdk
@testable import URnetwork

/// a manual clock: scheduled actions run only when the test advances it
private final class FakeScheduler {
    private final class Scheduled {
        let due: TimeInterval
        let action: () -> Void
        var cancelled = false

        init(due: TimeInterval, action: @escaping () -> Void) {
            self.due = due
            self.action = action
        }
    }

    private(set) var now: TimeInterval = 0
    private var scheduled: [Scheduled] = []

    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
        let s = Scheduled(due: now + delay, action: action)
        scheduled.append(s)
        return { s.cancelled = true }
    }

    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let next = scheduled
            .filter({ !$0.cancelled && $0.due <= end })
            .min(by: { $0.due < $1.due }) {
            scheduled.removeAll { $0 === next }
            now = next.due
            next.action()
        }
        now = end
    }
}

/// an availability api whose answers the test delivers by hand
private final class FakeCheck {
    private(set) var pending: [(networkName: String, onResult: (Bool?) -> Void)] = []
    private(set) var checkCount = 0

    func check(_ networkName: String, _ onResult: @escaping (Bool?) -> Void) {
        pending.append((networkName, onResult))
        checkCount += 1
    }

    func answer(_ available: Bool?) {
        guard !pending.isEmpty else {
            Issue.record("no check is waiting for an answer")
            return
        }
        let (_, onResult) = pending.removeFirst()
        onResult(available)
    }
}

struct NetworkNameCheckTests {

    private let scheduler: FakeScheduler
    private let api: FakeCheck
    private let nameCheck: NetworkNameCheck

    init() {
        let scheduler = FakeScheduler()
        let api = FakeCheck()
        self.scheduler = scheduler
        self.api = api
        nameCheck = NetworkNameCheck(check: api.check, schedule: scheduler.schedule)
    }

    /// edits the name and lets the debounce pass, so the online check is sent
    private func validateNow(_ networkName: String) {
        nameCheck.validate(networkName)
        scheduler.advance(NetworkNameCheck.debounceDelay)
    }

    @Test func aFailedCheckIsNotShownAsAnUnavailableName() {
        validateNow("mynetwork")
        api.answer(nil)

        #expect(nameCheck.state == .failed)
    }

    @Test func aFailedCheckAllowsCreate() {
        validateNow("mynetwork")
        api.answer(nil)

        #expect(nameCheck.state.allowsCreate)
    }

    @Test func aTakenNameBlocksCreateAndIsNotRetried() {
        validateNow("mynetwork")
        api.answer(false)
        scheduler.advance(10 * NetworkNameCheck.retryDelay)

        #expect(nameCheck.state == .unavailable)
        #expect(!nameCheck.state.allowsCreate)
        #expect(api.pending.isEmpty)
        #expect(api.checkCount == 1)
    }

    @Test func anAvailableNameAllowsCreate() {
        validateNow("mynetwork")
        api.answer(true)
        scheduler.advance(10 * NetworkNameCheck.retryDelay)

        #expect(nameCheck.state == .available)
        #expect(nameCheck.state.allowsCreate)
        #expect(api.checkCount == 1)
    }

    @Test func aFailedCheckIsRetriedAndTheAnswerIsApplied() {
        validateNow("mynetwork")
        api.answer(nil)
        #expect(api.pending.isEmpty)

        scheduler.advance(NetworkNameCheck.retryDelay)
        #expect(api.pending.map { $0.networkName } == ["mynetwork"])
        // Create stays usable while the retry runs
        #expect(nameCheck.state == .failed)

        api.answer(true)
        #expect(nameCheck.state == .available)
    }

    @Test func retriesStopAfterThree() {
        validateNow("mynetwork")
        api.answer(nil)
        for _ in 0..<NetworkNameCheck.maxRetryCount {
            scheduler.advance(NetworkNameCheck.retryDelay)
            #expect(api.pending.count == 1)
            api.answer(nil)
        }
        scheduler.advance(10 * NetworkNameCheck.retryDelay)

        #expect(NetworkNameCheck.maxRetryCount == 3)
        #expect(api.pending.isEmpty)
        #expect(api.checkCount == 1 + 3)
        #expect(nameCheck.state == .failed)
        #expect(nameCheck.state.allowsCreate)
    }

    @Test func aCheckThatNeverAnswersFailsAfterTheTimeout() {
        validateNow("mynetwork")
        scheduler.advance(NetworkNameCheck.checkTimeout - 1)
        #expect(nameCheck.state == .checking)
        #expect(!nameCheck.state.allowsCreate)

        scheduler.advance(1)
        #expect(NetworkNameCheck.checkTimeout == 15)
        #expect(nameCheck.state == .failed)
        #expect(nameCheck.state.allowsCreate)

        // the answer that finally arrives for the timed out check is ignored
        api.answer(true)
        #expect(nameCheck.state == .failed)
    }

    /// The worst case: every check hangs. Each one times out, three retries
    /// follow, and then the checks stop with Create usable.
    @Test func hungChecksTimeOutAndRetriesRunOut() {
        validateNow("mynetwork")
        scheduler.advance(NetworkNameCheck.checkTimeout)
        for _ in 0..<NetworkNameCheck.maxRetryCount {
            scheduler.advance(NetworkNameCheck.retryDelay + NetworkNameCheck.checkTimeout)
        }
        scheduler.advance(10 * (NetworkNameCheck.retryDelay + NetworkNameCheck.checkTimeout))

        #expect(api.checkCount == 1 + 3)
        #expect(nameCheck.state == .failed)
        #expect(nameCheck.state.allowsCreate)
    }

    @Test func anEditCancelsThePendingRetryAndAStaleAnswerIsIgnored() {
        validateNow("mynetwork")
        api.answer(nil)
        validateNow("othernetwork")
        // the answer for the edited name is still outstanding
        scheduler.advance(NetworkNameCheck.retryDelay)
        #expect(api.pending.map { $0.networkName } == ["othernetwork"])

        validateNow("thirdnetwork")
        api.answer(true) // the stale answer for "othernetwork"
        #expect(nameCheck.state == .checking)
        api.answer(false)
        #expect(nameCheck.state == .unavailable)
    }

    @Test func anEditStartsTheRetriesOver() {
        validateNow("mynetwork")
        api.answer(nil)
        for _ in 0..<NetworkNameCheck.maxRetryCount {
            scheduler.advance(NetworkNameCheck.retryDelay)
            api.answer(nil)
        }

        validateNow("othernetwork")
        api.answer(nil)
        scheduler.advance(NetworkNameCheck.retryDelay)
        #expect(api.pending.map { $0.networkName } == ["othernetwork"])
    }

    @Test func theNameIsCheckedOnceTheEditsPause() {
        nameCheck.validate("mynetwork")
        // the old answer no longer applies to the edited name
        #expect(nameCheck.state == .checking)
        #expect(!nameCheck.state.allowsCreate)
        scheduler.advance(NetworkNameCheck.debounceDelay / 2)
        nameCheck.validate("mynetwork2")
        scheduler.advance(NetworkNameCheck.debounceDelay / 2)
        #expect(api.pending.isEmpty)

        scheduler.advance(NetworkNameCheck.debounceDelay / 2)
        #expect(api.pending.map { $0.networkName } == ["mynetwork2"])
    }

    @Test func shortNamesAreJudgedWithoutAnOnlineCheck() {
        validateNow("abcde")
        #expect(nameCheck.state == .tooShort)
        validateNow("")
        #expect(nameCheck.state == .empty)
        #expect(api.checkCount == 0)
        #expect(!nameCheck.state.allowsCreate)
    }

    @Test func anErroredResultIsFailedNotUnavailable() {
        #expect(NetworkNameCheck.resultState(nil) == .failed)
        #expect(NetworkNameCheck.resultState(false) == .unavailable)
        #expect(NetworkNameCheck.resultState(true) == .available)
    }
}

/// The create form driven by the name check, through the view model the
/// screen uses: a failed check leaves Create enabled with a neutral line
/// under the field, and the server's refusal at create is what the user
/// sees for a taken name the check could not catch.
@MainActor
struct CreateNetworkNameCheckTests {

    private final class RefusingUrApiService: MockUrApiService {
        let reason: String
        private(set) var createCount = 0

        init(reason: String) {
            self.reason = reason
        }

        override func createNetwork(_ args: SdkNetworkCreateArgs) async throws -> LoginNetworkResult {
            createCount += 1
            throw NetworkCreateError.refused(message: reason)
        }
    }

    private let scheduler = FakeScheduler()
    private let api = FakeCheck()

    private func viewModel(_ urApiService: UrApiServiceProtocol = MockUrApiService()) -> CreateNetworkView.ViewModel {
        let viewModel = CreateNetworkView.ViewModel(
            api: SdkApi(),
            urApiService: urApiService,
            authType: .apple,
            checkNetworkName: api.check,
            schedule: scheduler.schedule
        )
        viewModel.termsAgreed = true
        return viewModel
    }

    @Test func aFailedCheckLeavesCreateEnabled() {
        let viewModel = viewModel()
        viewModel.networkName = "mynetwork"
        scheduler.advance(NetworkNameCheck.debounceDelay)
        api.answer(nil)

        #expect(viewModel.formIsValid)
        #expect(viewModel.networkNameValidationState == .notChecked)
        #expect(viewModel.networkNameSupportingText == CreateNetworkView.ViewModel.networkNameCheckFailed)
    }

    @Test func aTakenNameKeepsCreateDisabled() {
        let viewModel = viewModel()
        viewModel.networkName = "mynetwork"
        scheduler.advance(NetworkNameCheck.debounceDelay)
        api.answer(false)

        #expect(!viewModel.formIsValid)
        #expect(viewModel.networkNameValidationState == .invalid)
        #expect(viewModel.networkNameSupportingText == CreateNetworkView.ViewModel.networkNameUnavailable)
    }

    @Test func anAvailableNameEnablesCreate() {
        let viewModel = viewModel()
        viewModel.networkName = "mynetwork"
        scheduler.advance(NetworkNameCheck.debounceDelay)
        api.answer(true)

        #expect(viewModel.formIsValid)
        #expect(viewModel.networkNameValidationState == .valid)
        #expect(viewModel.networkNameSupportingText == CreateNetworkView.ViewModel.networkNameAvailable)
    }

    @Test func aCreateOfATakenNameShowsTheServersReason() async {
        let urApiService = RefusingUrApiService(reason: "Network name not available")
        let viewModel = viewModel(urApiService)
        viewModel.networkName = "mynetwork"
        scheduler.advance(NetworkNameCheck.debounceDelay)
        api.answer(nil)

        let result = await viewModel.createNetwork(userAuth: nil, authJwt: "jwt", authType: "apple", walletAuth: nil)

        #expect(urApiService.createCount == 1)
        guard case .failure(let error) = result else {
            Issue.record("a refused create was not a failure")
            return
        }
        #expect(createNetworkFailureMessage(error) == "Network name not available")
        #expect(!viewModel.isCreatingNetwork)
    }

    @Test func aRefusalCarriesTheServersReasonAndOtherErrorsAreGeneric() {
        let refused = SdkNetworkCreateResult()
        let resultError = SdkNetworkCreateResultError()
        resultError.message = "Network name not available"
        refused.error = resultError
        #expect(UrApiService.createNetworkRefusal(refused) == .refused(message: "Network name not available"))
        #expect(UrApiService.createNetworkRefusal(SdkNetworkCreateResult()) == nil)

        let generic = "There was an error creating your network. Please try again."
        #expect(createNetworkFailureMessage(NetworkCreateError.refused(message: " ")) == generic)
        #expect(createNetworkFailureMessage(NSError(domain: "UrApiService", code: -1)) == generic)
    }

    @Test func theFailedCheckLineIsLocalized() throws {
        // …/apple/app/networkTests/NetworkNameCheckTests.swift -> …/apple/app
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])

        let entry = try #require(strings["Couldn't check availability. You can still continue."] as? [String: Any])
        #expect(entry["extractionState"] as? String != "stale")
        let localizations = try #require(entry["localizations"] as? [String: Any])
        for locale in ["ar", "de", "es", "fr", "ja", "ru", "zh-Hans", "zh-HK"] {
            #expect(localizations[locale] != nil, "\(locale) translation missing")
        }

        // the old line read as a verdict on the name
        let old = try #require(strings["There was an error checking the network name"] as? [String: Any])
        #expect(old["extractionState"] as? String == "stale")
    }
}
