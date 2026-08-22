//
//  TransportStatsTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The transport math (shares, boundaries, percents, used/enabled, the Auto
 * editing rules) is the SDK's and is tested there. These tests cover the app's
 * mirror layer: the snapshot types derived from the SDK objects, the
 * animation vector, and the render helpers the bar reads.
 */
struct TransportStatsTests {

    // MARK: distribution mirror

    @Test func distributionMirrorsTheSdkInStableOrder() {
        let sdk = SdkTransportDistribution()
        let shares = SdkTransportShareList()
        for (i, type) in ["h3", "h1", "dns", "dnspump", "p2p", "unknown"].enumerated() {
            let share = SdkTransportShare()
            share.transportType = type
            share.share = i == 0 ? 0.75 : (i == 1 ? 0.25 : 0)
            share.boundary = i == 0 ? 0.75 : 1
            share.percent = i == 0 ? 75 : (i == 1 ? 25 : 0)
            share.used = i < 2
            share.enabled = i < 3
            share.egressByteCount = i < 2 ? 100 : 0
            shares?.add(share)
        }
        sdk.shares = shares
        sdk.byteCount = 200
        sdk.active = true

        let distribution = TransportDistribution(sdk)
        #expect(distribution.active)
        #expect(distribution.byteCount == 200)
        #expect(distribution.shares.map { $0.transportType } == TransportType.allCases)
        #expect(distribution.boundaries.values == [0.75, 1, 1, 1, 1, 1])
        #expect(distribution.used.map { $0.transportType } == [.h3, .h1])
        // enabled but idle: the unused footer, stable order
        #expect(distribution.unused.map { $0.transportType } == [.dns])
        #expect(distribution.shares[0].percent == 75)
    }

    @Test func nilDistributionIsEmpty() {
        let distribution = TransportDistribution(nil)
        #expect(distribution == .empty)
        #expect(!distribution.active)
        #expect(distribution.boundaries.values.isEmpty)
        #expect(distribution.used.isEmpty)
        #expect(distribution.unused.isEmpty)
    }

    @Test func unknownSdkVocabularyIsDropped() {
        let sdk = SdkTransportDistribution()
        let shares = SdkTransportShareList()
        let known = SdkTransportShare()
        known.transportType = "h1"
        known.used = true
        shares?.add(known)
        let future = SdkTransportShare()
        future.transportType = "warp9"
        shares?.add(future)
        sdk.shares = shares
        sdk.active = true
        let distribution = TransportDistribution(sdk)
        #expect(distribution.shares.map { $0.transportType } == [.h1])
    }

    // MARK: animatable vector

    @Test func animatableVectorCombinesElementwiseWithZeroPadding() {
        let a = AnimatableVector(values: [0.5, 1.0])
        let b = AnimatableVector(values: [0.25])
        #expect((a + b).values == [0.75, 1.0])
        #expect((a - b).values == [0.25, 1.0])
        var scaled = a
        scaled.scale(by: 2)
        #expect(scaled.values == [1.0, 2.0])
        #expect(AnimatableVector.zero.values.isEmpty)
    }

    // MARK: settings snapshot

    @Test func settingsSnapshotFollowsTheSdkPolicy() {
        let sdk = SdkDefaultTransportSettings()!
        var settings = TransportSettings(sdk)
        #expect(settings.isAuto)
        #expect(settings.singleTransport == nil)
        #expect(settings.autoTransports == [.h1, .h3, .dns, .dnsPump])
        #expect(settings.enabledTransports == [.h1, .h3, .dns, .dnsPump])

        // a single mode enables its carrier only; the auto policy is retained
        sdk.mode = SdkTransportModeDns
        settings = TransportSettings(sdk)
        #expect(!settings.isAuto)
        #expect(settings.singleTransport == .dns)
        #expect(settings.enabledTransports == [.dns])
        #expect(settings.autoTransports == [.h1, .h3, .dns, .dnsPump])

        // edits go through the sdk helpers and are visible in a fresh snapshot
        sdk.mode = SdkTransportModeAuto
        #expect(sdk.setAutoModeEnabled(SdkTransportModeH3, enabled: false))
        #expect(sdk.setAutoModeEnabled(SdkTransportModeDns, enabled: false))
        #expect(sdk.setAutoModeEnabled(SdkTransportModeDnsPump, enabled: false))
        // the last one refuses
        #expect(!sdk.setAutoModeEnabled(SdkTransportModeH1, enabled: false))
        settings = TransportSettings(sdk)
        #expect(settings.autoTransports == [.h1])
        #expect(settings.isAutoEnabled(.h1))
        #expect(!settings.isAutoEnabled(.h3))
    }

    @Test func selectableTransportsAreTheSdkDefaultOrder() {
        #expect(TransportType.selectable == [.h1, .h3, .dns, .dnsPump])
        #expect(TransportType.h3.isSelectable)
        #expect(!TransportType.p2p.isSelectable)
        #expect(!TransportType.unknown.isSelectable)
    }

    @Test func snapshotEqualityIgnoresTheSdkReference() {
        let a = TransportSettings(SdkDefaultTransportSettings()!)
        let b = TransportSettings(SdkDefaultTransportSettings()!)
        #expect(a == b)
        #expect(a.sdk !== b.sdk)
    }

    // MARK: runtime status presentation

    private func status(
        degraded: Bool,
        eligible: [String],
        constraint: String = SdkTransportConstraintMemory
    ) -> TransportRuntimeStatus {
        let sdk = SdkTransportStatus()
        sdk.autoDegraded = degraded
        let modes = SdkStringList()
        for mode in eligible {
            modes?.add(mode)
        }
        sdk.autoEligibleModes = modes
        sdk.autoConstraint = degraded ? constraint : ""
        return TransportRuntimeStatus(sdk)
    }

    private var defaultAuto: TransportSettings {
        TransportSettings(SdkDefaultTransportSettings()!)
    }

    @Test func healthyStatusShowsNoDecorations() {
        let applied = defaultAuto
        let presentation = TransportStatusPresentation.compute(
            draft: applied,
            statusPolicy: applied,
            status: status(degraded: false, eligible: TransportType.selectable.map { $0.rawValue })
        )
        #expect(presentation == .hidden)
    }

    @Test func degradedStatusMarksEnabledIneligibleTransports() {
        let applied = defaultAuto
        let presentation = TransportStatusPresentation.compute(
            draft: applied,
            statusPolicy: applied,
            status: status(degraded: true, eligible: [SdkTransportModeH1])
        )
        #expect(presentation.showBanner)
        #expect(presentation.memoryConstraint)
        #expect(presentation.constrainedTransports == [.h3, .dns, .dnsPump])
    }

    @Test func autoDisabledTransportIsNeverConstrained() {
        // h3 disabled in the policy and absent from the eligible modes: no
        // indicator on h3, only on the enabled-but-ineligible carriers
        let sdk = SdkDefaultTransportSettings()!
        #expect(sdk.setAutoModeEnabled(SdkTransportModeH3, enabled: false))
        let applied = TransportSettings(sdk)
        let presentation = TransportStatusPresentation.compute(
            draft: applied,
            statusPolicy: applied,
            status: status(degraded: true, eligible: [SdkTransportModeH1])
        )
        #expect(presentation.showBanner)
        #expect(presentation.constrainedTransports == [.dns, .dnsPump])
    }

    @Test func explicitModeHidesAutoStatus() {
        let sdk = SdkDefaultTransportSettings()!
        sdk.mode = SdkTransportModeH3
        let applied = TransportSettings(sdk)
        let presentation = TransportStatusPresentation.compute(
            draft: applied,
            statusPolicy: applied,
            status: status(degraded: true, eligible: [SdkTransportModeH1])
        )
        #expect(presentation == .hidden)
    }

    @Test func unknownStatusShowsNoDecorations() {
        let applied = defaultAuto
        let presentation = TransportStatusPresentation.compute(
            draft: applied,
            statusPolicy: applied,
            status: nil
        )
        #expect(presentation == .hidden)
    }

    @Test func dirtyDraftHidesStatusUntilItMatchesTheAppliedPolicy() {
        let applied = defaultAuto
        let degraded = status(degraded: true, eligible: [SdkTransportModeH1])

        // an edit away from the applied policy hides the decorations
        let draftSdk = applied.sdk.clone() ?? applied.sdk
        #expect(draftSdk.setAutoModeEnabled(SdkTransportModeDnsPump, enabled: false))
        let edited = TransportStatusPresentation.compute(
            draft: TransportSettings(draftSdk),
            statusPolicy: applied,
            status: degraded
        )
        #expect(edited == .hidden)

        // editing back to the applied policy restores them
        #expect(draftSdk.setAutoModeEnabled(SdkTransportModeDnsPump, enabled: true))
        let restored = TransportStatusPresentation.compute(
            draft: TransportSettings(draftSdk),
            statusPolicy: applied,
            status: degraded
        )
        #expect(restored.showBanner)

        // a stale pairing (settings moved without a status) also hides them
        let unpaired = TransportStatusPresentation.compute(
            draft: TransportSettings(draftSdk),
            statusPolicy: nil,
            status: degraded
        )
        #expect(unpaired == .hidden)
    }

    @Test func unknownConstraintUsesGenericCopy() {
        let applied = defaultAuto
        let presentation = TransportStatusPresentation.compute(
            draft: applied,
            statusPolicy: applied,
            status: status(degraded: true, eligible: [SdkTransportModeH1], constraint: "quantum")
        )
        #expect(presentation.showBanner)
        #expect(!presentation.memoryConstraint)
    }

    @Test func unknownEligibleVocabularyKeepsTheBannerRenderable() {
        // the authoritative degraded flag renders the banner even when the
        // eligible list carries only vocabulary this app does not know
        let applied = defaultAuto
        let presentation = TransportStatusPresentation.compute(
            draft: applied,
            statusPolicy: applied,
            status: status(degraded: true, eligible: ["warp9"])
        )
        #expect(presentation.showBanner)
        #expect(presentation.constrainedTransports == [.h3, .h1, .dns, .dnsPump])
    }

    @Test func storeStartsAndResetsWithUnknownStatus() async {
        await MainActor.run {
            let store = TransportSettingsStore()
            #expect(store.status(.client) == nil)
            #expect(store.statusPolicy(.client) == nil)
            store.reset()
            #expect(store.status(.client) == nil)
            #expect(store.status(.provider) == nil)
            #expect(store.statusPolicy(.client) == nil)
            #expect(store.statusPolicy(.provider) == nil)
        }
    }
}
