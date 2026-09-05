//
//  ContractDetailsView.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/8/26.
//

import SwiftUI
import URnetworkSdk

/**
 * Live contract details: a scrollable list with one row per peer client.
 * Each row shows every contract separately -- no pairing or aggregation --
 * as two independent stacks: send contracts (green) and receive contracts
 * (pink), newest on top. Each circle is one contract, sized relative to the
 * largest contract in its stack, with its inner disc growing as the
 * contract is used. Removed contracts slide off to the side and the stack
 * falls down into the space; new contracts drop in at the top.
 */
struct ContractDetailsView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager

    @StateObject private var store: ContractDetailsStore

    init(mode: ContractDetailsMode) {
        _store = StateObject(wrappedValue: ContractDetailsStore(mode: mode))
    }

    // Whether the list is scrolled to the very top. Reported to the store (and
    // thus the shared ContractDetailsViewController), which owns the activity
    // ordering and the scrolled-away freeze -- the view just renders store.rows in
    // the order it is given and shows the pending "N new" chip.
    @State private var isAtTop: Bool = true
    @State private var topBaseline: CGFloat? = nil

    private static let topMarkerId = "contract-details-top"

    var body: some View {

        Group {
            if store.rows.isEmpty {

                VStack(spacing: 8) {
                    Spacer()
                    Text("No open contracts")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                    Text(store.mode == .client
                         ? "Contracts appear here while connected."
                         : "Contracts appear here while providing.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textFaintColor)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else {

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {

                            // top marker, used to detect when the list is at the very top
                            Color.clear
                                .frame(height: 0)
                                .id(Self.topMarkerId)
                                .background(
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: ContractTopOffsetKey.self,
                                            value: geometry.frame(in: .named("contractList")).minY
                                        )
                                    }
                                )

                            ForEach(store.rows) { row in
                                VStack(spacing: 0) {
                                    ContractPeerRowView(row: row)
                                    Divider()
                                }
                                // new/closed client rows fade; the per-stack
                                // choreography handles contracts coming and going
                                // within a row
                                .transition(.opacity)
                            }
                        }
                        .padding(.horizontal)
                        .tabletReadableColumn()
                    }
                    .coordinateSpace(name: "contractList")
                    .onPreferenceChange(ContractTopOffsetKey.self) { minY in
                        updateIsAtTop(minY)
                    }
                    .onChange(of: store.rows.first?.id) { _ in
                        // keep the list pinned to the very top as rows merge in / re-sort
                        // at the front while at the top, so a newly prepended row stays
                        // visible. The marker-based isAtTop is stable across a prepend, so
                        // the guard holds; a no-op when scrolled away (frozen front) or
                        // when the offset-anchored ScrollView already sits at the top.
                        if isAtTop {
                            scrollProxy.scrollTo(Self.topMarkerId, anchor: .top)
                        }
                    }
                    .overlay(alignment: .top) {
                        if !isAtTop && 0 < store.pendingCount {
                            Button(action: {
                                // the view controller merges + re-sorts when it
                                // learns we're back at the top
                                store.setAtTop(true)
                                withAnimation(.spring(duration: 0.3)) {
                                    scrollProxy.scrollTo(Self.topMarkerId, anchor: .top)
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 10, weight: .semibold))
                                    // real plural rules live in Localizable.xcstrings ("%lld new")
                                    Text("\(store.pendingCount) new")
                                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                                }
                                .foregroundColor(themeManager.currentTheme.inverseTextColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(themeManager.currentTheme.accentColor)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 8)
                        }
                    }
                }

            }
        }
        .onAppear {
            if let device = deviceManager.device {
                store.setup(device)
            }
            store.setAtTop(isAtTop)
        }
        .onDisappear {
            store.reset()
        }
    }

    /**
     * At the very top the marker rests at its baseline offset. Scrolling away
     * moves it up (or unloads it, reporting nil). The at-top state is forwarded
     * to the store; the shared view controller owns the ordering and freeze.
     */
    private func updateIsAtTop(_ minY: CGFloat?) {
        guard let minY = minY else {
            if isAtTop {
                isAtTop = false
                store.setAtTop(false)
            }
            return
        }
        if topBaseline == nil {
            topBaseline = minY
        }
        let atTop = (topBaseline ?? 0) - 4 <= minY
        if atTop != isAtTop {
            isAtTop = atTop
            store.setAtTop(atTop)
        }
    }
}

private struct ContractTopOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}

struct ContractPeerRowView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager

    let row: ContractPeerRow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // the full client id, tappable to copy
            Text(row.clientId)
                .font(.system(size: 13, weight: .medium).monospaced())
                .foregroundColor(themeManager.currentTheme.textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    copyClientId()
                }

            // the two stacks are top-anchored: their headers align at the top of
            // the row and the piles grow downward, so the tops always touch the
            // top of the row. four columns, mirrored around the center: send
            // stats | send circles | receive circles | receive stats
            HStack(alignment: .top, spacing: 20) {
                ContractStackView(
                    entries: row.send,
                    byteCount: row.sendByteCount,
                    title: "Send",
                    color: .urGreen,
                    pointsRight: true,
                    removalEdge: .leading,
                    mirrored: true
                )
                .frame(maxWidth: .infinity, alignment: .trailing)

                ContractStackView(
                    entries: row.receive,
                    byteCount: row.receiveByteCount,
                    title: "Receive",
                    color: .urPink,
                    pointsRight: false,
                    removalEdge: .trailing,
                    mirrored: false
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
        .padding(.vertical, 16)
        .contextMenu {
            Button {
                copyClientId()
            } label: {
                Label("Copy client ID", systemImage: "doc.on.doc")
            }
        }
    }

    private func copyClientId() {
        #if os(iOS)
        UIPasteboard.general.string = row.clientId
        #elseif os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(row.clientId, forType: .string)
        #endif
        snackbarManager.showSnackbar(message: String(localized: "Client ID copied"))
    }
}

// one contract as presented in a stack: the live entry plus whether it is in
// its slide-off phase (still holding its slot, animating out to the side)
private struct DisplayedContract: Identifiable, Equatable {
    var entry: ContractEntry
    var leaving: Bool = false
    var id: String { entry.id }
}

/**
 * One direction's stack of contracts, newest on top, with the direction
 * header (title, arrow, summed bit rate) above and the scale anchor ("max
 * N") below.
 *
 * Membership changes are choreographed in two phases, tetris style:
 *   1. a removed contract slides off to `removalEdge`, still holding its
 *      slot open;
 *   2. once clear, one settle transaction drops the leavers, admits new
 *      contracts at the top, and the stack falls down into the open space.
 * Value updates (used bytes, bit rate) apply live in any phase. The truth is
 * mirrored into state so the phase completions read the live intent rather
 * than a stale capture (same pattern the old ContractRing used).
 */
private struct ContractStackView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let entries: [ContractEntry]
    let byteCount: Int64
    let title: LocalizedStringKey
    let color: Color
    let pointsRight: Bool
    let removalEdge: Edge
    // a mirrored stack (the send side) puts its stats column on the outside and
    // its circle column against the row center
    let mirrored: Bool

    private static let slideDuration: Double = 0.4
    private static let settleDuration: Double = 0.5

    // the live truth, mirrored into state for the async phase completions
    @State private var truth: [ContractEntry]
    // what is on screen: truth plus leavers still sliding off
    @State private var displayed: [DisplayedContract]
    // a slide-off phase is in flight; membership changes queue behind it
    @State private var settling: Bool = false

    init(
        entries: [ContractEntry],
        byteCount: Int64,
        title: LocalizedStringKey,
        color: Color,
        pointsRight: Bool,
        removalEdge: Edge,
        mirrored: Bool
    ) {
        self.entries = entries
        self.byteCount = byteCount
        self.title = title
        self.color = color
        self.pointsRight = pointsRight
        self.removalEdge = removalEdge
        self.mirrored = mirrored
        // a fresh view (first show, or re-created by the lazy list) starts at
        // the current truth with no choreography
        _truth = State(initialValue: entries)
        _displayed = State(initialValue: entries.map { DisplayedContract(entry: $0) })
    }

    // scale reference: the largest contract on screen, leavers included so the
    // survivors rescale in the settle transaction rather than mid-slide
    private var stackMax: Int64 {
        displayed.map { $0.entry.totalByteCount }.max() ?? 0
    }
    
    var body: some View {
        // header and max label align to the circle column (the row-center edge
        // of a mirrored stack); blocks span the full width
        VStack(alignment: mirrored ? .trailing : .leading, spacing: 12) {

            // direction header: the cumulative run total (bytes moved since the
            // peer last went idle) sits against the row center, above the circle
            // column it measures. The mirrored (send) side reads
            // title-arrow-total; the receive side reads total-arrow-title, so each
            // side's number lands over its own circles.
            HStack(spacing: 5) {
                if mirrored {
                    headerTitle
                    headerArrow
                    headerTotal
                } else {
                    headerTotal
                    headerArrow
                    headerTitle
                }
            }

            // the pile, newest first
            VStack(spacing: 4) {
                ForEach(displayed) { d in
                    ContractBlock(
                        entry: d.entry,
                        stackMax: stackMax,
                        color: color,
                        leaving: d.leaving,
                        removalEdge: removalEdge,
                        mirrored: mirrored
                    )
                    .transition(.asymmetric(
                        // a new contract drops in at the top as the stack shifts
                        insertion: .move(edge: .top).combined(with: .opacity),
                        // a leaver already slid offscreen in phase 1; at the
                        // settle it just vanishes and the stack falls
                        removal: .identity
                    ))
                }
            }

            // the scale anchor: all circles are sized relative to this
            Text("max \(formatByteCountCompact(stackMax))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(themeManager.currentTheme.textFaintColor)
                .opacity(displayed.isEmpty ? 0 : 1)

        }
        .onChange(of: entries) { newEntries in
            truth = newEntries
            sync()
        }
    }

    // header pieces, ordered by side so the rate always lands against the row
    // center (over the circle column): see the header HStack above
    private var headerTitle: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(themeManager.currentTheme.textMutedColor)
    }

    private var headerArrow: some View {
        Image(systemName: pointsRight ? "arrow.right" : "arrow.left")
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(color)
    }

    private var headerTotal: some View {
        Text(0 < byteCount ? formatByteCountCompact(byteCount) : " ")
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundColor(color)
            .opacity(0 < byteCount ? 1 : 0)
    }

    /**
     * Reconcile the screen with the truth. Values always track live; membership
     * changes run the two-phase tetris choreography, one phase at a time.
     */
    private func sync() {
        let truthById = Dictionary(truth.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // 1. blocks still in the truth track its values (the inner disc grows
        //    smoothly); a leaver keeps its final snapshot
        withAnimation(.easeOut(duration: 0.5)) {
            for i in displayed.indices {
                if let live = truthById[displayed[i].entry.id], displayed[i].entry != live {
                    displayed[i].entry = live
                }
            }
        }

        // 2. membership, one choreographed phase at a time
        guard !settling else {
            return
        }

        let displayedIds = Set(displayed.map { $0.id })
        let hasDepartures = displayed.contains { truthById[$0.entry.id] == nil }
        let hasArrivals = truth.contains { !displayedIds.contains($0.id) }

        if hasDepartures {
            settling = true
            // phase 1: leavers slide off sideways, holding their slot open
            withAnimation(.easeInOut(duration: Self.slideDuration)) {
                for i in displayed.indices {
                    if truthById[displayed[i].entry.id] == nil {
                        displayed[i].leaving = true
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideDuration) {
                // phase 2: one settle transaction -- drop the leavers, admit
                // arrivals at the top, fall down, rescale to the new max
                withAnimation(.spring(response: Self.settleDuration, dampingFraction: 0.85)) {
                    displayed = truth.map { DisplayedContract(entry: $0) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDuration) {
                    settling = false
                    // fold in whatever landed mid-phase
                    sync()
                }
            }
        } else if hasArrivals {
            // arrivals only: drop in at the top as the stack shifts down
            withAnimation(.spring(response: Self.settleDuration, dampingFraction: 0.85)) {
                displayed = truth.map { DisplayedContract(entry: $0) }
            }
        }
    }
}

/**
 * One contract in a stack: a fixed-size block with the contract circle
 * centered in it, and the used/total counts beside. The outer ring is sized
 * by the contract total relative to the stack max (area-proportional); the
 * inner disc is the used fraction of this contract. A contract actively
 * moving bytes brightens its ring.
 *
 * A mirrored block (the send side) lays out stats-then-circle so the circle
 * column sits against the row center; an unmirrored block is circle-then-
 * stats. Together the two stacks read as four columns.
 */
private struct ContractBlock: View {

    @EnvironmentObject var themeManager: ThemeManager

    let entry: ContractEntry
    let stackMax: Int64
    let color: Color
    let leaving: Bool
    let removalEdge: Edge
    let mirrored: Bool

    // the fixed block each contract occupies; circles center in it, so the
    // stack falls in uniform increments
    static let circleSlot: CGFloat = 56
    private static let minDiameter: CGFloat = 16

    private var diameter: CGFloat {
        guard 0 < stackMax, 0 < entry.totalByteCount else {
            return Self.minDiameter
        }
        // area-proportional to the stack max
        let d = Self.circleSlot * sqrt(Double(entry.totalByteCount) / Double(stackMax))
        return max(Self.minDiameter, min(Self.circleSlot, d))
    }

    // slide fully clear of the row
    private var offscreenOffset: CGFloat {
        let distance = Self.circleSlot * 4
        return removalEdge == .leading ? -distance : distance
    }

    var body: some View {

        // area-proportional inner disc, with a minimum visible size
        let fraction = 0 < entry.totalByteCount
            ? min(1, Double(entry.usedByteCount) / Double(entry.totalByteCount))
            : 0
        let innerSize = 0 < fraction ? max(4, diameter * sqrt(fraction)) : 0
        let active = entry.isActive

        HStack(spacing: 10) {

            if mirrored {
                Spacer(minLength: 0)
                stats
                circle(innerSize: innerSize, active: active, hasStream: entry.hasStream)
            } else {
                circle(innerSize: innerSize, active: active, hasStream: entry.hasStream)
                stats
                Spacer(minLength: 0)
            }

        }
        .frame(height: Self.circleSlot)
        .offset(x: leaving ? offscreenOffset : 0)
        .opacity(leaving ? 0 : 1)
    }

    // a stream contract gets a second concentric ring this far (radially) outside the
    // outer ring, so streams read as a double ring vs a single for direct. Applied to
    // the diameter doubled: a 4px radial gap is an 8px diameter delta.
    private static let streamRingGap: CGFloat = 4

    private func circle(innerSize: CGFloat, active: Bool, hasStream: Bool) -> some View {
        let ringColor = color.opacity(active ? 1 : 0.55)
        let ringWidth: CGFloat = active ? 1.5 : 1
        return ZStack {
            // stream contracts: a second, outer concentric ring (kept outside the
            // used disc so it stays visible even when the contract is full)
            if hasStream {
                Circle()
                    .stroke(ringColor, lineWidth: ringWidth)
                    .frame(width: diameter + 2 * Self.streamRingGap, height: diameter + 2 * Self.streamRingGap)
            }

            // the outer ring is the contract total; active contracts brighten
            Circle()
                .stroke(ringColor, lineWidth: ringWidth)
                .frame(width: diameter, height: diameter)

            // the inner disc is the used fraction
            Circle()
                .fill(color.opacity(0.3))
                .overlay(
                    Circle().stroke(color.opacity(0.6), lineWidth: 0.5)
                )
                .frame(width: innerSize, height: innerSize)
        }
        .frame(width: Self.circleSlot, height: Self.circleSlot)
    }

    private var stats: some View {
        VStack(alignment: mirrored ? .trailing : .leading, spacing: 2) {
            Text(formatByteCountCompact(entry.usedByteCount))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(themeManager.currentTheme.textColor)
            Text("of \(formatByteCountCompact(entry.totalByteCount))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(themeManager.currentTheme.textMutedColor)
        }
    }
}

#Preview {

    var rowA = ContractPeerRow(clientId: "0199a2b4c6d8e0f2a4b6c8d0e2f4a6b8")
    rowA.send = [
        ContractEntry(id: "c1", usedByteCount: 12 * 1024 * 1024, totalByteCount: 32 * 1024 * 1024, bitRate: 1_200_000, hasStream: true),
        ContractEntry(id: "c2", usedByteCount: 512 * 1024, totalByteCount: 8 * 1024 * 1024, bitRate: 0),
        ContractEntry(id: "c3", usedByteCount: 30 * 1024 * 1024, totalByteCount: 32 * 1024 * 1024, bitRate: 0),
    ]
    rowA.receive = [
        ContractEntry(id: "c4", usedByteCount: 3 * 1024 * 1024, totalByteCount: 32 * 1024 * 1024, bitRate: 240_000, hasStream: true),
        ContractEntry(id: "c5", usedByteCount: 0, totalByteCount: 1024 * 1024, bitRate: 0),
    ]
    rowA.sendByteCount = 12 * 1024 * 1024
    rowA.receiveByteCount = 3 * 1024 * 1024

    var rowB = ContractPeerRow(clientId: "44f1a2b4c6d8e0f2a4b6c8d0e2f4a6b8")
    rowB.send = [
        ContractEntry(id: "c6", usedByteCount: 30 * 1024 * 1024, totalByteCount: 32 * 1024 * 1024, bitRate: 0),
    ]

    return ScrollView {
        VStack(spacing: 0) {
            ContractPeerRowView(row: rowA)
            Divider()
            ContractPeerRowView(row: rowB)
        }
        .padding(.horizontal)
    }
    .environmentObject(ThemeManager.shared)
    .background(ThemeManager.shared.currentTheme.backgroundColor)
}
