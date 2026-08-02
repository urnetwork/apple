//
//  PresentationLifecycleTests.swift
//  networkTests
//

import Testing
@testable import URnetwork

struct PresentationLifecycleTests {

    @Test func inactiveStateDoesNotOwnPresentationWork() {
        let state = PresentationLifecycleState()

        #expect(!state.isActive)
    }

    @Test func activeTransitionResumesExactlyOnce() {
        var state = PresentationLifecycleState()

        #expect(state.update(isActive: true) == .resume)
        #expect(state.update(isActive: true) == nil)
        #expect(state.isActive)
    }

    @Test func inactiveTransitionSuspendsExactlyOnce() {
        var state = PresentationLifecycleState()
        _ = state.update(isActive: true)

        #expect(state.update(isActive: false) == .suspend)
        #expect(state.update(isActive: false) == nil)
        #expect(!state.isActive)
    }

    @Test func foregroundResumeRestartsPresentationWork() {
        var state = PresentationLifecycleState()

        #expect(state.update(isActive: true) == .resume)
        #expect(state.update(isActive: false) == .suspend)
        #expect(state.update(isActive: true) == .resume)
    }

    @Test func hiddenWindowDoesNotResumeWhenApplicationBecomesActive() {
        var state = PresentationLifecycleState()

        #expect(
            state.update(
                sceneActive: true,
                presentationVisible: false
            ) == nil
        )
        #expect(!state.isActive)
    }

    @Test func visibleWindowDoesNotResumeWhileApplicationIsInactive() {
        var state = PresentationLifecycleState()

        #expect(
            state.update(
                sceneActive: false,
                presentationVisible: true
            ) == nil
        )
        #expect(!state.isActive)
    }

    @Test func visibleWindowResumesWhenApplicationIsActive() {
        var state = PresentationLifecycleState()

        #expect(
            state.update(
                sceneActive: true,
                presentationVisible: true
            ) == .resume
        )
        #expect(state.isActive)
    }

    @Test func hidingWindowSuspendsExactlyOnce() {
        var state = PresentationLifecycleState()
        _ = state.update(
            sceneActive: true,
            presentationVisible: true
        )

        #expect(
            state.update(
                sceneActive: true,
                presentationVisible: false
            ) == .suspend
        )
        #expect(
            state.update(
                sceneActive: true,
                presentationVisible: false
            ) == nil
        )
        #expect(!state.isActive)
    }

    @Test func applicationActivationWhileHiddenDoesNotUndoSuspension() {
        var state = PresentationLifecycleState()
        _ = state.update(
            sceneActive: true,
            presentationVisible: true
        )
        _ = state.update(
            sceneActive: true,
            presentationVisible: false
        )

        #expect(
            state.update(
                sceneActive: false,
                presentationVisible: false
            ) == nil
        )
        #expect(
            state.update(
                sceneActive: true,
                presentationVisible: false
            ) == nil
        )
        #expect(!state.isActive)
    }

    @Test func presentationWorkDoesNotRunWhilePresentationIsInactive() {
        #expect(
            !PresentationWorkState.shouldRun(
                presentationActive: false,
                workReady: true
            )
        )
    }

    @Test func presentationWorkDoesNotRunBeforeItIsReady() {
        #expect(
            !PresentationWorkState.shouldRun(
                presentationActive: true,
                workReady: false
            )
        )
    }

    @Test func readyPresentationWorkRunsOnlyWhilePresentationIsActive() {
        #expect(
            PresentationWorkState.shouldRun(
                presentationActive: true,
                workReady: true
            )
        )
    }

    @Test func performanceProfileIntentPersistsWithoutLiveDevice() {
        let plan = PerformanceProfilePropagationPlan(hasLiveDevice: false)

        #expect(plan.persist)
        #expect(!plan.applyLive)
    }

    @Test func performanceProfileIntentAlsoAppliesToLiveDevice() {
        let plan = PerformanceProfilePropagationPlan(hasLiveDevice: true)

        #expect(plan.persist)
        #expect(plan.applyLive)
    }

    @Test func deviceStateLoadDoesNotWriteSettingBack() {
        #expect(
            !DeviceSettingWritePolicy.shouldPropagate(
                isLoadingFromDevice: true
            )
        )
    }

    @Test func userSettingChangePropagatesOutsideDeviceStateLoad() {
        #expect(
            DeviceSettingWritePolicy.shouldPropagate(
                isLoadingFromDevice: false
            )
        )
    }
}
