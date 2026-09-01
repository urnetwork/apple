//
//  DeveloperView.swift
//  URnetwork
//
//  Created by Claude on 8/4/26.
//

import SwiftUI
import URnetworkSdk

/**
 * Developer tools for diagnosing connection problems.
 *
 * Its own screen rather than a section at the bottom of Settings: these
 * controls act on the live connection while something is going wrong, and the
 * set is expected to grow. Every control takes effect on the next packet, so
 * a fix can be switched off and back on *during* a freeze without
 * reconnecting and destroying the thing being observed.
 *
 * The timing controls are values rather than switches because the right value
 * is not knowable in advance -- how long to wait before giving up on an exit
 * trades recovery speed against dropping a slow-but-alive one, and that
 * balance differs per connection. Each edits as a number in the unit the
 * detail names (milliseconds or a count), with 0 restoring the behaviour that
 * shipped before the fix it controls so any of them can still be A/B'd.
 */
struct DeveloperView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var reliabilityStore: ReliabilityStore
    @EnvironmentObject var deviceManager: DeviceManager
    @Environment(\.presentationActive) private var presentationActive

    /**
     * non-optional convenience over the published snapshot. Only ever read
     * inside the `reliabilityStore.connected` branch, where the snapshot is
     * non-nil by definition -- the fallback is a compile-time convenience,
     * never a set of defaults presented as if they were in force.
     */
    private var settings: ReliabilitySettings {
        reliabilityStore.settings ?? ReliabilitySettings()
    }

    // the export outlives this screen, so its in-flight guard and its result
    // are held outside the view -- see DiagnosticExportState
    @ObservedObject private var exportState = DiagnosticExportState.shared
    @State private var showLogPicker = false
    @State private var selectedLogNames: Set<String> = []

    // read what was recorded at startup; do NOT call configure() here, which
    // would re-point glog every time this view is constructed
    private var sharedRootUnavailableReason: String? {
        DiagnosticsLogLocation.sharedRootUnavailableReason
    }

    var body: some View {
        Form {

            introSection
            diagnosticsSection

            if reliabilityStore.connected {
                measurementsSection
                detectionSection
                placementSection
                recoverySection
                probingSection
                observabilitySection
                exitsSection
                actionsSection
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(themeManager.currentTheme.backgroundColor)
        // the 5s poll is an rpc into the packet tunnel extension: it runs only
        // while this screen is both on screen AND the app is presenting
        // (backgrounded app / hidden macOS window stops it), the same
        // three-part lifecycle the rest of the app uses
        .onAppear {
            reliabilityStore.setActive(presentationActive)
        }
        .task {
            // the inventory (and with it the total size and any unavailable
            // source) has to be on screen BEFORE the user commits to an
            // export, so it is read here rather than when the picker opens
            await exportState.refreshInventory(
                sharedRootUnavailableReason: sharedRootUnavailableReason)
        }
        .onChange(of: presentationActive) { active in
            reliabilityStore.setActive(active)
        }
        .onDisappear {
            reliabilityStore.setActive(false)
        }
    }

    // MARK: - Sections

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tools for diagnosing connection freezes. These act on the live connection.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)

                if !reliabilityStore.connected {
                    // the diagnostics section below works while disconnected
                    // -- exporting the logs of a connection that will not come
                    // up is exactly when it is wanted -- so this must not tell
                    // the user the whole screen is dead
                    Text("Connect to use the live connection tools. Diagnostics below work either way.")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /** Diagnostics: everything the client knows, as one file the user can send. */
    private var diagnosticsSection: some View {
        Section {
            if let inventoryLabel = exportState.inventoryLabel {
                Text(inventoryLabel)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            ForEach(exportState.unavailableSources, id: \.self) { note in
                Text(note)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            actionRow("Export all logs (raw)", isEnabled: !exportState.isExporting) {
                exportBundle(redacted: false)
            }
            actionRow("Export redacted logs", isEnabled: !exportState.isExporting) {
                exportBundle(redacted: true)
            }
            // disabled while an export runs like the other three rows: its
            // handler re-reads the on-disk inventory, and that read is exactly
            // the work the running export is already doing
            actionRow("Choose logs…", isEnabled: !exportState.isExporting) {
                showLogPicker.toggle()
                Task {
                    await exportState.refreshInventory(
                        sharedRootUnavailableReason: sharedRootUnavailableReason)
                    // a checked file that has since rotated away would be
                    // dropped by the SDK filter without a word, so the picker
                    // would promise files the bundle does not contain
                    selectedLogNames.formIntersection(
                        Set(exportState.inventory.map { $0.name }))
                }
            }
            if showLogPicker {
                // identified by source+name, not name alone: glog names embed
                // the program and pid so a collision across processes is
                // unlikely, but nothing enforces it, and a duplicate id is a
                // SwiftUI diffing hazard
                ForEach(exportState.inventory, id: \.pickerRowId) { info in
                    Button {
                        if selectedLogNames.contains(info.name) {
                            selectedLogNames.remove(info.name)
                        } else {
                            selectedLogNames.insert(info.name)
                        }
                    } label: {
                        HStack {
                            Text(DiagnosticExportService.rowLabel(
                                source: info.source,
                                severity: info.severity,
                                byteCount: info.byteCount,
                                modifiedMillis: info.modifiedMillis))
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(
                                    selectedLogNames.contains(info.name)
                                        ? themeManager.currentTheme.accentColor
                                        : themeManager.currentTheme.textMutedColor)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text(DiagnosticExportService.selectionLabel(
                    fileCount: selectedLogNames.count,
                    byteCount: DiagnosticExportService.totalByteCount(
                        of: exportState.inventory.filter { selectedLogNames.contains($0.name) })))
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                // Disabled (and a no-op even if somehow tapped) with nothing
                // checked, or while an export is already running: an empty
                // selection means "no filter" to the SDK, which would
                // otherwise export every log file unredacted -- the opposite
                // of what this row's label promises.
                actionRow(
                    "Export selected",
                    isEnabled: !exportState.isExporting
                        && DiagnosticExportService.canExportSelection(selectedLogNames)
                ) {
                    guard DiagnosticExportService.canExportSelection(selectedLogNames) else { return }
                    exportBundle(redacted: false, selected: Array(selectedLogNames))
                }
            }
            if exportState.isExporting {
                Text("Exporting…")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            if let exportedBundle = exportState.bundle {
                ShareLink(item: exportedBundle) {
                    Text("Share \(exportedBundle.lastPathComponent)")
                        .font(themeManager.currentTheme.bodyFont)
                }
            }
            if let exportSummary = exportState.summary {
                Text(exportSummary)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            if let exportError = exportState.errorMessage {
                Text(exportError)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
        } header: {
            sectionHeader("Diagnostics")
        }
    }

    /**
     * The work itself, its in-flight guard and its result all live in
     * DiagnosticExportState, which outlives this view. Everything the export
     * needs from the environment is read here, on the main actor, before the
     * hop -- reading `deviceManager.device` off the main actor would itself be
     * unsafe.
     */
    private func exportBundle(redacted: Bool, selected: [String] = []) {
        let device = deviceManager.device
        let reason = sharedRootUnavailableReason

        Task {
            await exportState.export(
                redacted: redacted,
                selected: selected,
                device: device,
                sharedRootUnavailableReason: reason
            )
        }
    }

    /**
     * Measurements come first because they are what the rest of this screen
     * is for. Reliability changes have been judged on how long a freeze felt,
     * which is why fixes that were correct in isolation changed nothing in
     * use. A candidate that does not move blast radius or recovery time did
     * not work, however good the reasoning behind it was.
     */
    private var measurementsSection: some View {
        Section {
            let metrics = reliabilityStore.metrics ?? ReliabilityMetrics()

            Group {
                metricRow(
                    "Flows opened",
                    "Total since reset, so runs of different lengths compare",
                    value: "\(metrics.flowsOpened)"
                )
                // dial failures are independent of exit-loss events -- a
                // re-raced flow is one that did NOT cost an exit removal -- so
                // these stay always-shown beside flows opened rather than
                // behind the exit-loss guard below
                metricRow(
                    "Provider connect failures",
                    "Times a provider reported it could not open the upstream connection",
                    value: "\(metrics.dialFailuresIntercepted)"
                )
                metricRow(
                    "Moved to another exit",
                    "How many of those failures were quietly moved instead of hanging",
                    value: "\(metrics.flowsReraced)"
                )
                // provider-qualification proof-of-life: sent climbs within
                // seconds of connecting when the sweep is working. Always
                // shown -- a zero is itself the measurement when comparing
                // probe on vs off
                metricRow(
                    "Probes",
                    "Qualification probes this session",
                    value: "\(metrics.probesSent) sent / \(metrics.probesAnswered) answered"
                )
                metricRow(
                    "Busy probes",
                    "Liveness pings fired at stalled exits; acquitted ones answered and were kept, the removals the probe prevented",
                    value: "\(metrics.busyProbesSent) sent / \(metrics.busyProbesAcquitted) acquitted"
                )
                metricRow(
                    "Verdicts held",
                    "Convictions withheld because the phone's own uplink, not the provider, was silent (uplink / transport)",
                    value: "\(metrics.verdictsHeldUplinkStale) / \(metrics.verdictsHeldTransportDown)"
                )
                if 0 < metrics.removalsDeferred {
                    metricRow(
                        "Removals deferred",
                        "Removals the storm breaker held back after a correlated burst",
                        value: "\(metrics.removalsDeferred)"
                    )
                }
                // host suspends the pause detector caught -- rare and
                // device-specific, so shown only once it has fired
                if 0 < metrics.schedulerPausesDetected {
                    metricRow(
                        "Suspends caught",
                        "Host suspends the detector caught, each one a batch of verdicts held instead of executed on a just-resumed phone",
                        value: "\(metrics.schedulerPausesDetected)"
                    )
                }
                if 0 < metrics.flowsRebound {
                    metricRow(
                        "QUIC flows rebound",
                        "Flows moved to a warm exit inside a removal; accepted means the server took the path change without a re-dial",
                        value: "\(metrics.flowsRebound) (\(metrics.rebindsAccepted) accepted / \(metrics.rebindsRedialed) re-dialed)"
                    )
                }
            }

            // the loss numbers are meaningless until something has actually
            // failed, and showing zeros reads as "nothing is wrong" rather
            // than "nothing has been measured yet"
            Group {
                if metrics.exitLossEvents == 0 {
                    Text("No provider failures yet.")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                } else {
                    metricRow(
                        "Blast radius",
                        "Connections lost per provider failure. Lower is better",
                        value: "\(formatBlastRadius(metrics.meanFlowsLostPerExitLoss)) per failure"
                    )
                    metricRow(
                        "Worst single failure",
                        "The one the user actually feels",
                        value: "\(metrics.maxFlowsLostInOneEvent) connections"
                    )
                    metricRow(
                        "Recovery time",
                        "From an exit dying to that site answering again",
                        value: "avg \(formatDurationMillis(metrics.recoveryMeanMillis)), worst \(formatDurationMillis(metrics.recoveryMaxMillis))"
                    )
                    // read together with recovery time: a change that abandons
                    // flows instead of recovering them makes the average look
                    // better while this climbs
                    metricRow(
                        "Never came back",
                        "Sites abandoned rather than recovered",
                        value: "\(metrics.recoveryMissed) of \(metrics.flowsLostToExit)"
                    )
                }
            }

            actionRow("Reset measurements") {
                reliabilityStore.resetMetrics()
            }
        } header: {
            sectionHeader("Measurements")
        } footer: {
            footerText("What a provider failure costs. Reset, run a test, read back.")
        }
    }

    /** Detection: how an exit is judged to be failing, and how fast. */
    private var detectionSection: some View {
        Section {
            millisRow(
                "Drop stalled exits fast",
                "How long an exit may stop delivering before it is dropped, in ms. Off waits 30s",
                millis: settings.sendStallTimeoutMillis
            ) { $0.sendStallTimeoutMillis = $1 }
            toggleRow(
                "Probe stalled exits before dropping",
                "When an exit stalls, ping it once before convicting. A congested but alive exit answers and keeps its flows; a dead one is still dropped. Off convicts on the stall bar",
                value: settings.busyProbe
            ) { $0.busyProbe = $1 }
            millisRow(
                "Busy probe wait",
                "How long the stall probe waits for an answer before convicting, in ms. Off derives half the stall bar",
                millis: settings.busyProbeBudgetMillis
            ) { $0.busyProbeBudgetMillis = $1 }
            millisRow(
                "Suspend detector",
                "How much timer overshoot reads as the phone being suspended rather than an exit stalling, in ms, so a resumed phone does not convict every exit at once. Off disables it",
                millis: settings.schedulerPauseToleranceMillis
            ) { $0.schedulerPauseToleranceMillis = $1 }
            millisRow(
                "Suspend recovery window",
                "How long verdicts stay held after a detected suspend, in ms, giving transports time to re-register. Off uses the built-in 5s",
                millis: settings.schedulerPauseRecoveryTimeoutMillis
            ) { $0.schedulerPauseRecoveryTimeoutMillis = $1 }
            millisRow(
                "Cut dead connects early",
                "Drop an exit that has established nothing sooner when two sibling exits are receiving, in ms. Off waits the full 30s connect bar",
                millis: settings.blackholeConnectComparativeTimeoutMillis
            ) { $0.blackholeConnectComparativeTimeoutMillis = $1 }
            millisRow(
                "Keep quiet providers longer",
                "How long a provider still acknowledging traffic may return nothing before it is dropped, in ms. Off keeps them until they stop acknowledging",
                millis: settings.blackholeReceiveTimeoutMillis
            ) { $0.blackholeReceiveTimeoutMillis = $1 }
            toggleRow(
                "Demote before removing",
                "Ambiguous verdicts bench an exit instead of tearing down its flows; removal needs sustained evidence or an empty exit",
                value: settings.softVerdictDemote
            ) { $0.softVerdictDemote = $1 }
        } header: {
            sectionHeader("Detection")
        }
    }

    /** Placement: which exit a flow lands on, and how the pool is shaped. */
    private var placementSection: some View {
        Section {
            Group {
                toggleRow(
                    "Live tier demotion",
                    "Failing dials and survived verdicts push a provider down the ranking within a second; promotion back needs clean minutes and a proven connect",
                    value: settings.effectiveTierSelection
                ) { $0.effectiveTierSelection = $1 }
                countRow(
                    "Max connections per exit",
                    "Losing an exit kills every connection on it. Lower spreads the damage; a site may then use more than one exit IP",
                    count: settings.maxFlowsPerExit,
                    zeroLabel: "Unlimited"
                ) { $0.maxFlowsPerExit = $1 }
                toggleRow(
                    "Sticky site affinity",
                    "A site's new connections stay on the exit its earlier ones already use, even past the flow cap, so a busy site keeps one egress IP. The cap still limits which exits collect new sites. Off restores the strict cap",
                    value: settings.affinityStickyPastCap
                ) { $0.affinityStickyPastCap = $1 }
                toggleRow(
                    "Follow benched exits",
                    "A quarantined exit keeps its own sites' new connections through the early bench, when the verdict is least proven, so a bench does not split the site's egress IP. New sites still avoid it. Off scatters them",
                    value: settings.quarantineGroupFollow
                ) { $0.quarantineGroupFollow = $1 }
                millisRow(
                    "Follow window",
                    "How long into a bench a site's new connections keep following their exit, in ms — early benches are usually false alarms; one that lasts is trending toward removal and stops collecting flows. Off scatters immediately",
                    millis: settings.groupFollowWindowMillis
                ) { $0.groupFollowWindowMillis = $1 }
                countRow(
                    "Removal storm limit",
                    "How many verdict removals are allowed per window before the rest are deferred; a burst is more likely one local cause than many failures. Off removes without limit",
                    count: settings.removalBudgetCount,
                    zeroLabel: "Off"
                ) { $0.removalBudgetCount = $1 }
                millisRow(
                    "Removal storm window",
                    "The window the removal limit is counted over, in ms. Off (like a limit of 0) turns the breaker off",
                    millis: settings.removalBudgetWindowMillis
                ) { $0.removalBudgetWindowMillis = $1 }
            }
            Group {
                toggleRow(
                    "Keep a spare exit warm",
                    "Size each window one exit beyond its target so a replacement is already connected. Off waits until a loss to backfill",
                    value: settings.standingReserve
                ) { $0.standingReserve = $1 }
                countRow(
                    "Load corroboration",
                    "Extra silent destinations required per this many flows before a busy exit can be benched on soft evidence: a 24-flow exit at 8 needs 3 silent sites, not 2. Off keeps the flat minimum",
                    count: settings.blackholeLoadCorroboration,
                    zeroLabel: "Off"
                ) { $0.blackholeLoadCorroboration = $1 }
                countRow(
                    "Corroborate silent exits",
                    "How many distinct destinations must be silent before an exit is convicted on no-receive, so one dead site cannot remove a working exit. Off lets a single destination convict",
                    count: settings.minBlackholeDestinations,
                    zeroLabel: "Off"
                ) { $0.minBlackholeDestinations = $1 }
                toggleRow(
                    "Group IPs by site",
                    "Keeps a site on one exit when its hostname is not visible",
                    value: settings.clusterAffinityFallback
                ) { $0.clusterAffinityFallback = $1 }
                toggleRow(
                    "Converge late-named flows",
                    "Moves later connections onto the exit the first one already uses",
                    value: settings.serverNameAffinityBridge
                ) { $0.serverNameAffinityBridge = $1 }
            }
        } header: {
            sectionHeader("Placement")
        }
    }

    /**
     * Recovery: getting a flow moving again after its exit fails or the
     * phone's own network changes underneath it.
     */
    private var recoverySection: some View {
        Section {
            toggleRow(
                "Rebind QUIC on exit loss",
                "Re-pin established QUIC flows to a live exit inside the removal instead of tearing them down",
                value: settings.quicRebindOnExitLoss
            ) { $0.quicRebindOnExitLoss = $1 }
            toggleRow(
                "Retry refused connects elsewhere",
                "When a provider can't reach a site, move the connection to another exit instead of letting it hang",
                value: settings.dialFailureRerace
            ) { $0.dialFailureRerace = $1 }
            toggleRow(
                "Signal UDP teardown",
                "Tells DNS and QUIC the path is gone instead of going silent",
                value: settings.udpTeardownSignal
            ) { $0.udpTeardownSignal = $1 }
            millisRow(
                "Release stuck retransmits",
                "How long retransmits are held before one is released, in ms. Off waits 30s",
                millis: settings.tcpCollapseMaxHoldMillis
            ) { $0.tcpCollapseMaxHoldMillis = $1 }
            millisRow(
                "Longer TCP idle timeout",
                "How long a TCP connection may sit idle, in ms. Off uses the UDP bound",
                millis: settings.tcpSequenceIdleTimeoutMillis
            ) { $0.tcpSequenceIdleTimeoutMillis = $1 }
            millisRow(
                "UDP idle timeout",
                "How long a non-TCP flow may sit idle before it is reaped, in ms",
                millis: settings.sequenceIdleTimeoutMillis
            ) { $0.sequenceIdleTimeoutMillis = $1 }
            millisRow(
                "Uplink silence gate",
                "How long the whole tunnel may be silent before provider verdicts are held as inadmissible, in ms. 0 convicts as before",
                millis: settings.uplinkStalenessGateMillis
            ) { $0.uplinkStalenessGateMillis = $1 }
            millisRow(
                "Fast first-exit poll",
                "How often a connecting flow re-checks an empty window, in ms, so the first request leaves right after the first exit lands. Off waits the 2s retry pace",
                millis: settings.formationPollTimeoutMillis
            ) { $0.formationPollTimeoutMillis = $1 }
        } header: {
            sectionHeader("Recovery")
        }
    }

    /** Probing: proving an exit can actually reach real destinations. */
    private var probingSection: some View {
        Section {
            toggleRow(
                "Probe providers",
                "Qualify exits by dialing real sites through them. An answer proves the exit; silence never counts against it",
                value: settings.providerProbe
            ) { $0.providerProbe = $1 }
            millisRow(
                "Probe wait",
                "How long a qualification probe waits for an answer, in ms. Off uses the built-in 4s. It only bounds waiting for proof, it never convicts",
                millis: settings.probeTimeoutMillis
            ) { $0.probeTimeoutMillis = $1 }
            countRow(
                "Probe hosts per pass",
                "How many health sites one qualification pass dials through an exit. 0 probes the entire embedded list; a smaller number rotates through it in blocks",
                count: settings.probeSampleHostCount,
                zeroLabel: "All"
            ) { $0.probeSampleHostCount = $1 }
            countRow(
                "Probe silence streak",
                "How many consecutive probe passes an exit may answer with total silence before it is warned out of new-flow placement — the compensation for providers that leave the network mid-session. Placement only: removal stays traffic-based, and any sign of life clears the streak",
                count: settings.probeSilenceWarnStreak,
                zeroLabel: "Off"
            ) { $0.probeSilenceWarnStreak = $1 }
            countRow(
                "Candidates evaluated per slot",
                "How many providers a window expansion pings and ranks per slot it needs, keeping the best. 1 evaluates exactly what it needs",
                count: settings.evaluationPoolMultiple,
                // 0 is not a behaviour: connect clamps this to max(1, …), so
                // the row says what a 0 actually does rather than showing it
                zeroLabel: "1 (min)"
            ) { $0.evaluationPoolMultiple = $1 }
            actionRow("Probe all exits now") {
                reliabilityStore.probeAllExits()
            }
        } header: {
            sectionHeader("Probing")
        }
    }

    /** Observability: what the session writes to the log for later forensics. */
    private var observabilitySection: some View {
        Section {
            millisRow(
                "State heartbeat",
                "How often one line summarizing live state is written to the log for later forensics, in ms. Off silences it; shorter spots a transition, longer keeps more buffer",
                millis: settings.heartbeatIntervalMillis
            ) { $0.heartbeatIntervalMillis = $1 }
            actionRow("Reset to shipped defaults") {
                reliabilityStore.resetSettings()
            }
        } header: {
            sectionHeader("Observability")
        }
    }

    /**
     * Exit readout. A site split across exits shows up as flows spread over
     * several rows instead of collected on one.
     */
    private var exitsSection: some View {
        Section {
            if reliabilityStore.exits.isEmpty {
                Text("No exits. Connect first.")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            } else {
                ForEach(reliabilityStore.exits) { exit in
                    exitRow(exit)
                }
            }
        } header: {
            sectionHeader("Exits")
        }
    }

    private var actionsSection: some View {
        Section {
            actionRow("Refresh") {
                reliabilityStore.refresh()
            }
            // fires the same process-wide network-change path a real
            // wifi-to-cellular migration triggers, so the uplink-gate storm
            // drill is one tap instead of physically moving between networks
            actionRow("Simulate network change") {
                reliabilityStore.simulateNetworkChange()
            }
            if let lastAction = reliabilityStore.lastAction {
                Text(lastAction)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
        } footer: {
            // every action returns void over the bridge and no-ops when the
            // extension has no multi client, so the log above records what was
            // asked for. The counters and exit rows are where it is confirmed
            footerText("Actions are requests: confirm them in the measurements and exit rows, which refresh underneath.")
        }
    }

    // MARK: - Rows

    private func rowLabel(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
            Text(detail)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
        }
    }

    private func sectionHeader(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .textCase(nil)
    }

    private func footerText(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textFaintColor)
    }

    /**
     * A tappable action, rendered as accent-colored text like the android
     * screen's actions rather than a bordered button.
     */
    private func actionRow(
        _ title: LocalizedStringKey, isEnabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(
                        isEnabled
                            ? themeManager.currentTheme.accentColor
                            : themeManager.currentTheme.textMutedColor)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    /** A read-only counter row: label and detail with a value in place of a control. */
    private func metricRow(
        _ title: LocalizedStringKey,
        _ detail: LocalizedStringKey,
        value: String
    ) -> some View {
        HStack(alignment: .top) {
            rowLabel(title, detail)
            Spacer()
            Text(value)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
        }
    }

    /**
     * A bool knob. The write goes through the store's read-modify-write of
     * the full settings struct against a fresh device read -- the binding's
     * displayed value is never what gets written back.
     */
    private func toggleRow(
        _ title: LocalizedStringKey,
        _ detail: LocalizedStringKey,
        value: Bool,
        set: @escaping (SdkReliabilitySettings, Bool) -> Void
    ) -> some View {
        UrSwitchToggle(
            isOn: Binding(
                get: { value },
                set: { newValue in
                    reliabilityStore.updateSettings { settings in
                        set(settings, newValue)
                    }
                }
            ),
            isEnabled: reliabilityStore.connected
        ) {
            rowLabel(title, detail)
        }
    }

    /** A duration knob, edited in whole milliseconds. */
    private func millisRow(
        _ title: LocalizedStringKey,
        _ detail: LocalizedStringKey,
        millis: Int64,
        set: @escaping (SdkReliabilitySettings, Int64) -> Void
    ) -> some View {
        DeveloperNumberRow(
            title: title,
            detail: detail,
            value: millis,
            display: { formatDurationMillis($0) },
            enabled: reliabilityStore.connected
        ) { newValue in
            reliabilityStore.updateSettings { settings in
                set(settings, newValue)
            }
        }
    }

    /** A count knob. What 0 means differs per knob, so its label is caller-supplied. */
    private func countRow(
        _ title: LocalizedStringKey,
        _ detail: LocalizedStringKey,
        count: Int32,
        zeroLabel: String,
        set: @escaping (SdkReliabilitySettings, Int32) -> Void
    ) -> some View {
        DeveloperNumberRow(
            title: title,
            detail: detail,
            value: Int64(count),
            display: { $0 <= 0 ? zeroLabel : "\($0)" },
            enabled: reliabilityStore.connected
        ) { newValue in
            reliabilityStore.updateSettings { settings in
                set(settings, Int32(clamping: newValue))
            }
        }
    }

    private func exitRow(_ exit: ReliabilityExit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(exit.label)
                    .font(.system(size: 14).monospaced())
                    .foregroundColor(themeManager.currentTheme.textColor)
                Spacer()
                Text("\(exit.flowCount) flows")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }

            Text(exit.stateLine)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)

            // shown only when the exit has reported upstream dials it could
            // not open in the recent window -- the out-of-capacity signal the
            // re-race acts on
            if 0 < exit.dialFailureCount {
                Text("\(exit.dialFailureCount) failed dials")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }

            // migrate is the only per-exit action: probing is a full sweep
            // (see the Probing section), matching the android screen
            Button("Migrate") {
                reliabilityStore.migrateExit(exit)
            }
            // borderless so the button hit-tests on its own instead of the
            // whole form row swallowing the tap
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

/**
 * A numeric setting edited as a text field, with the formatted effective
 * value beside it. The committed value goes through the store's
 * read-modify-write, and the field re-seeds from the device's effective value
 * on every refresh unless it is being edited.
 */
private struct DeveloperNumberRow: View {

    @EnvironmentObject var themeManager: ThemeManager

    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let value: Int64
    let display: (Int64) -> String
    let enabled: Bool
    let commit: (Int64) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)

                Spacer()

                Text(display(value))
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.accentColor)

                TextField("0", text: $text)
                    .font(.system(size: 13).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    // numbersAndPunctuation, NOT numberPad: the number pad has
                    // no return key, which leaves onSubmit dead and a tap on
                    // some other field the only way to commit. Non-numeric
                    // input is rejected by commitText
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.done)
                    #endif
                    .focused($focused)
                    .onSubmit {
                        endEditing()
                    }
                    .disabled(!enabled)

                // the second commit affordance: a form row gives the keyboard
                // nowhere to go, so editing must be endable from the row itself
                if focused {
                    Button("Set") {
                        endEditing()
                    }
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .buttonStyle(.borderless)
                }
            }

            Text(detail)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
        }
        .onAppear {
            text = "\(value)"
        }
        .onChange(of: value) { newValue in
            // never fight the typist: the effective value re-seeds the field
            // only while it is not being edited, so a poll landing mid-edit
            // cannot overwrite what is being typed
            if !focused {
                text = "\(newValue)"
            }
        }
        .onChange(of: focused) { isFocused in
            if !isFocused {
                commitText()
            }
        }
    }

    /**
     * Ends editing through the focus change, so `commitText` runs exactly
     * once no matter which affordance was used.
     */
    private func endEditing() {
        focused = false
        #if canImport(UIKit)
        hideKeyboard()
        #endif
    }

    private func commitText() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let newValue = Int64(trimmed), 0 <= newValue else {
            // not a value; restore the effective one
            text = "\(value)"
            return
        }
        if newValue != value {
            commit(newValue)
        }
    }
}

/** 0 reads as "Off"; sub-second as ms; otherwise seconds or minutes. */
private func formatDurationMillis(_ millis: Int64) -> String {
    if millis <= 0 {
        return "Off"
    }
    if millis < 1000 {
        return "\(millis)ms"
    }
    if millis < 60_000 {
        let seconds = Double(millis) / 1000.0
        if seconds == seconds.rounded(.down) {
            return "\(Int64(seconds))s"
        }
        return "\(seconds)s"
    }
    return "\(millis / 60_000)m"
}

/**
 * Blast radius is a ratio, not a count -- 4.0 connections per failure is a
 * different claim from 4 -- so it keeps one decimal rather than rounding to
 * an integer that would hide a change between, say, 4.0 and 4.4.
 */
private func formatBlastRadius(_ value: Double) -> String {
    String(format: "%.1f", value)
}
