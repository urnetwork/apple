//
//  SplitRulesView.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/8/26.
//

import SwiftUI
import URnetworkSdk

/**
 * Live routing decisions with the split rules pinned on top.
 *
 * Tapping a block action opens the rule editor to add the action's
 * host values as a local exception. Tapping an action whose decision
 * came from a rule edits that rule.
 */
struct SplitRulesView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var blockActionsStore: BlockActionsStore
    @Environment(\.presentationActive) private var presentationActive

    private struct EditorTarget: Identifiable {
        let id: String
        let candidates: [String]
        let selected: Set<String>
        let ruleId: String?
        let mode: SplitRuleMode
    }

    @State private var editorTarget: EditorTarget? = nil

    /**
     * The activity rows currently shown. While the list is scrolled away
     * from the top, this stays frozen so incoming items don't shift the
     * rows under the reader. New items are merged when the list returns
     * to the very top, or through the new-items chip.
     */
    @State private var displayedActions: [BlockActionItem] = []
    @State private var isAtTop: Bool = true
    @State private var topBaseline: CGFloat? = nil

    private static let topMarkerId = "split-rules-top"

    private var pendingCount: Int {
        let displayedIds = Set(displayedActions.map { $0.id })
        // live items are newest first, so the new items are the prefix
        return blockActionsStore.blockActions.prefix { !displayedIds.contains($0.id) }.count
    }

    var body: some View {

        // compute once per render rather than twice inside the chip overlay
        let pending = pendingCount

        ScrollViewReader { scrollProxy in

        List {

            /**
             * top marker, used to detect when the list is at the very top
             */
            Color.clear
                .frame(height: 0)
                .id(Self.topMarkerId)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: SplitRulesTopOffsetKey.self,
                            value: geometry.frame(in: .named("splitRulesList")).minY
                        )
                    }
                )

            /**
             * Info: how rules apply
             */
            Text("Rules apply to the whole co-associated network cluster, so related traffic is caught together.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(themeManager.currentTheme.tintedBackgroundBase)
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            /**
             * Pinned split rules
             */
            Section(
                header: sectionHeader("Rules")
            ) {

                if blockActionsStore.splitRules.isEmpty {
                    Text("Tap traffic below to route it locally or hold it to one provider.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textFaintColor)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(blockActionsStore.splitRules) { rule in
                        SplitRuleRowView(rule: rule)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editorTarget = EditorTarget(
                                    id: rule.id,
                                    candidates: rule.hosts,
                                    selected: Set(rule.hosts),
                                    ruleId: rule.id,
                                    mode: rule.mode
                                )
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    blockActionsStore.removeRule(id: rule.id)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                            .listRowBackground(Color.clear)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            if index < blockActionsStore.splitRules.count {
                                blockActionsStore.removeRule(id: blockActionsStore.splitRules[index].id)
                            }
                        }
                    }
                }

            }

            /**
             * Live block actions
             */
            Section(
                header: HStack {
                    sectionHeader("Activity")
                    Spacer()
                    if 0 < blockActionsStore.allowedCount || 0 < blockActionsStore.blockedCount {
                        Text("\(blockActionsStore.allowedCount) allowed · \(blockActionsStore.blockedCount) blocked")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(themeManager.currentTheme.textFaintColor)
                            .textCase(nil)
                    }
                }
            ) {

                if displayedActions.isEmpty {
                    Text("Routing activity appears here while connected.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textFaintColor)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(displayedActions) { action in
                        BlockActionRowView(action: action)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                openEditor(action)
                            }
                            .listRowBackground(Color.clear)
                    }
                }

            }

        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .coordinateSpace(name: "splitRulesList")
        .onPreferenceChange(SplitRulesTopOffsetKey.self) { minY in
            updateIsAtTop(minY)
        }
        .onChange(of: blockActionsStore.blockActions.first?.id) { _ in
            // keep the list pinned to the very top as new rows prepend while at the
            // top (a general principle for the app's lists). The marker-based isAtTop
            // is stable across a prepend, so the guard holds; a no-op when scrolled
            // away (displayedActions stays frozen and the "N new" chip catches up).
            if isAtTop {
                scrollProxy.scrollTo(Self.topMarkerId, anchor: .top)
            }
        }
        .overlay(alignment: .top) {
            if !isAtTop && 0 < pending {
                Button(action: {
                    displayedActions = blockActionsStore.blockActions
                    withAnimation(.spring(duration: 0.3)) {
                        scrollProxy.scrollTo(Self.topMarkerId, anchor: .top)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .semibold))
                        // real plural rules live in Localizable.xcstrings ("%lld new")
                        Text("\(pending) new")
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
        .background(themeManager.currentTheme.backgroundColor)
        .onAppear {
            displayedActions = blockActionsStore.blockActions
            // a sheet is only ever mounted while the app is presenting it, so
            // "not suspended" is the right starting state; the transitions
            // below carry it from there
            blockActionsStore.setExitAttributionActive(true)
        }
        .onChange(of: presentationActive) { active in
            blockActionsStore.setExitAttributionSuspended(!active)
        }
        .onDisappear {
            blockActionsStore.setExitAttributionActive(false)
            blockActionsStore.setExitAttributionSuspended(false)
        }
        .onChange(of: blockActionsStore.blockActions) { blockActions in
            if isAtTop {
                displayedActions = blockActions
            } else {
                // the frozen list still tracks attribution (and byte counts)
                // for the rows already on screen: an attribution-only rebuild
                // reuses the row ids, so it would otherwise never reach the
                // reader -- no "N new" chip counts it, and watching a row grow
                // a second exit chip is the whole point. Membership and order
                // stay frozen, so nothing shifts under the reader.
                let liveById = Dictionary(
                    blockActions.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                displayedActions = displayedActions.map { liveById[$0.id] ?? $0 }
            }
        }
        .sheet(item: $editorTarget) { target in
            SplitRuleEditorView(
                candidates: target.candidates,
                initialSelection: target.selected,
                ruleId: target.ruleId,
                initialMode: target.mode
            )
            .environmentObject(themeManager)
            .environmentObject(blockActionsStore)
            #if os(macOS)
            .frame(minWidth: 400, minHeight: 380)
            #endif
        }
    }

    /**
     * At the very top the marker rests at its baseline offset. Scrolling
     * away moves it up (or unloads it, reporting nil).
     */
    private func updateIsAtTop(_ minY: CGFloat?) {
        guard let minY = minY else {
            if isAtTop {
                isAtTop = false
            }
            return
        }
        if topBaseline == nil {
            topBaseline = minY
        }
        let atTop = (topBaseline ?? 0) - 4 <= minY
        if atTop != isAtTop {
            isAtTop = atTop
            if atTop {
                displayedActions = blockActionsStore.blockActions
            }
        }
    }

    private func openEditor(_ action: BlockActionItem) {
        if let rule = blockActionsStore.splitRule(overrideId: action.overrideId) {
            // edit the rule that decided this action
            let candidates = orderedUnion(rule.hosts, action.hostValues)
            editorTarget = EditorTarget(
                id: action.id,
                candidates: candidates,
                selected: Set(rule.hosts),
                ruleId: rule.id,
                mode: rule.mode
            )
        } else {
            // create a rule from the action's host values, all initially UNSELECTED:
            // the common case is picking one or a few server names, so pre-selecting
            // everything just makes the user uncheck the rest
            editorTarget = EditorTarget(
                id: action.id,
                candidates: action.hostValues,
                selected: [],
                ruleId: nil,
                mode: .excluded
            )
        }
    }

    private func orderedUnion(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for value in a + b {
            if seen.insert(value).inserted {
                values.append(value)
            }
        }
        return values
    }

    private func sectionHeader(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .textCase(nil)
    }
}

private struct SplitRulesTopOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}

// A split rule (override) row: all of the rule's host base names and exact ips as
// green chips (the whole rule is "active"), with the mode state chip trailing.
struct SplitRuleRowView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let rule: SplitRuleItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {

            ChipFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(rule.hostBaseNames, id: \.self) { name in
                    RuleChip(text: name, style: .matched)
                }
                ForEach(rule.ipValues, id: \.self) { ip in
                    RuleChip(text: ip, style: .matched)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // an excluded cluster routes locally: the same Local language as
            // the activity rows. a pinned cluster is in the tunnel like any
            // other, just held to one exit
            switch rule.mode {
            case .excluded:
                StateChip(text: "Local", color: .urGreen, highlighted: true)
            case .pinned:
                StateChip(text: "Pinned", color: .urElectricBlue, highlighted: true)
            case .included:
                StateChip(text: "Included", color: .urElectricBlue, highlighted: true)
            }

        }
        .padding(.vertical, 4)
    }
}

// A block-action row. Chips, in order: the exact hosts/ips an override matched
// (green), then the remaining hosts collapsed to base names (white outline), then a
// single "X IPs" pill for the remaining ips. The block/route state chips trail.
struct BlockActionRowView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let action: BlockActionItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {

            VStack(alignment: .leading, spacing: 6) {

                ChipFlowLayout(spacing: 6, lineSpacing: 6) {
                    // green: the exact hosts and ips that matched an override
                    ForEach(action.matchedHosts, id: \.self) { name in
                        RuleChip(text: name, style: .matched)
                    }
                    ForEach(action.matchedIps, id: \.self) { ip in
                        RuleChip(text: ip, style: .matched)
                    }
                    // white: the rest of the hosts as collapsed base names
                    ForEach(action.hostBaseNames, id: \.self) { name in
                        RuleChip(text: name, style: .normal)
                    }
                    // white: a single count pill for the rest of the ips
                    if 0 < action.ipCount {
                        IPsPill(count: action.ipCount)
                    }
                }

                HStack(spacing: 6) {
                    Text(relativeTime(action.time))
                    if 0 < action.byteCount {
                        Text(formatByteCountCompact(action.byteCount))
                    }
                    // which exit(s) carry this cluster right now. One chip is
                    // the healthy shape; two chips on one row is the site
                    // split across egress IPs, live
                    ForEach(action.exitShortIds, id: \.self) { exitId in
                        ExitChip(
                            exitShortId: exitId,
                            split: 1 < action.exitShortIds.count
                        )
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(themeManager.currentTheme.textFaintColor)

            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                StateChip(
                    text: action.block ? "Blocked" : "Allowed",
                    color: action.block ? .urCoral : themeManager.currentTheme.textMutedColor,
                    highlighted: action.hasBlockOverride
                )

                StateChip(
                    text: action.local ? "Local" : "Remote",
                    color: action.local ? .urGreen : themeManager.currentTheme.textMutedColor,
                    highlighted: action.hasRouteOverride
                )
            }

        }
        .padding(.vertical, 4)
    }

    private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private func relativeTime(_ date: Date) -> String {
        // the formatter localizes for every locale; under 5s reads as "now"
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 5 {
            return Self.relativeTimeFormatter.localizedString(fromTimeInterval: 0)
        }
        return Self.relativeTimeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// A host/ip chip: a rounded outline box. `.matched` reads green (an override hit
// it); `.normal` reads as a subtle white outline (item 1's "white outline box").
struct RuleChip: View {

    enum Style {
        case matched
        case normal
    }

    @EnvironmentObject var themeManager: ThemeManager

    let text: String
    let style: Style

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundColor(style == .matched ? Color.urGreen : themeManager.currentTheme.textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        style == .matched ? Color.urGreen : themeManager.currentTheme.textColor.opacity(0.3),
                        lineWidth: 1
                    )
            )
    }
}

// The single "X IPs" pill for the unmatched ips (item 2): a count, never the ips.
struct IPsPill: View {

    @EnvironmentObject var themeManager: ThemeManager

    let count: Int

    var body: some View {
        // plural rules live in Localizable.xcstrings ("%lld IPs")
        Text("\(count) IPs")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(
                Capsule()
                    .stroke(themeManager.currentTheme.textColor.opacity(0.3), lineWidth: 1)
            )
    }
}

// The exit currently carrying a cluster's flows, as a tinted "via <short client
// id>" capsule. One chip on a row is the normal healthy shape; when a row splits
// across exits, every chip flips to coral so the split-egress observation --
// the exact event the site affinity work exists to prevent -- is unmissable.
struct ExitChip: View {

    @EnvironmentObject var themeManager: ThemeManager

    let exitShortId: String
    let split: Bool

    var body: some View {
        let color = split ? Color.urCoral : themeManager.currentTheme.accentColor
        Text("via \(exitShortId)")
            .font(.system(size: 10, weight: .medium).monospaced())
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
    }
}

// A flow layout that places chips left-to-right and wraps to a new line when the
// next chip would overflow the available width.
struct ChipFlowLayout: Layout {

    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + lineSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct StateChip: View {

    @EnvironmentObject var themeManager: ThemeManager

    let text: LocalizedStringKey
    let color: Color
    let highlighted: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(highlighted ? themeManager.currentTheme.inverseTextColor : color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(highlighted ? color : color.opacity(0.14))
            .clipShape(Capsule())
    }
}

/**
 * Create or edit a split rule: select the host values and what the rule does
 * with them -- route locally (excluded), pin to one provider, or route
 * through the tunnel (included); see `SplitRuleMode`
 */
struct SplitRuleEditorView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var blockActionsStore: BlockActionsStore
    @Environment(\.dismiss) private var dismiss

    let candidates: [String]
    let ruleId: String?

    @State private var selection: Set<String>
    @State private var mode: SplitRuleMode

    init(candidates: [String], initialSelection: Set<String>, ruleId: String?, initialMode: SplitRuleMode) {
        self.candidates = candidates
        self.ruleId = ruleId
        _selection = State(initialValue: initialSelection)
        _mode = State(initialValue: initialMode)
    }

    private var isEditing: Bool {
        ruleId != nil
    }

    var body: some View {

        VStack(alignment: .leading, spacing: 0) {

            HStack {
                Text(isEditing ? "Edit split rule" : "New split rule")
                    .font(themeManager.currentTheme.toolbarTitleFont)
                    .foregroundColor(themeManager.currentTheme.textColor)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                .buttonStyle(.plain)
            }
            .padding()

            // what the rule does with the selected hosts, one exclusive choice
            VStack(spacing: 0) {
                modeRow(
                    .excluded,
                    title: "Route locally",
                    description: "Selected hosts bypass the tunnel."
                )
                // a site pin is exit STABILITY, not consolidation: the hosts
                // keep their ordinary grouping and simply hold a benched exit
                // longer before being re-raced off it (see SplitRuleMode)
                modeRow(
                    .pinned,
                    title: "Keep on one provider",
                    description: "Selected hosts hold their provider longer instead of being moved at the first sign of trouble, so the site changes IP addresses less often mid-session."
                )
                modeRow(
                    .included,
                    title: "Route through VPN",
                    description: "The default: selected hosts use the tunnel with no pin."
                )
            }
            .padding(.horizontal)

            List {
                ForEach(candidates, id: \.self) { host in
                    HStack {
                        Text(host)
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)

                        Spacer()

                        Image(systemName: selection.contains(host) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(
                                selection.contains(host)
                                    ? .urGreen
                                    : themeManager.currentTheme.textFaintColor
                            )
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selection.contains(host) {
                            selection.remove(host)
                        } else {
                            selection.insert(host)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            VStack(spacing: 12) {

                UrButton(
                    text: isEditing ? "Update" : "Create",
                    action: {
                        let hosts = candidates.filter { selection.contains($0) }
                        if let ruleId = ruleId {
                            blockActionsStore.updateRule(id: ruleId, hosts: hosts, mode: mode)
                        } else {
                            blockActionsStore.createRule(hosts: hosts, mode: mode)
                        }
                        dismiss()
                    },
                    enabled: isEditing || !selection.isEmpty
                )

                if let ruleId = ruleId {
                    Button(action: {
                        blockActionsStore.removeRule(id: ruleId)
                        dismiss()
                    }) {
                        Text("Remove rule")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.dangerColor)
                    }
                    .buttonStyle(.plain)
                }

            }
            .padding()

        }
        .background(themeManager.currentTheme.backgroundColor)
    }

    /**
     * one exclusive mode choice: a radio-style circle with the mode title
     * and what it does
     */
    private func modeRow(
        _ rowMode: SplitRuleMode,
        title: LocalizedStringKey,
        description: LocalizedStringKey
    ) -> some View {
        let selected = mode == rowMode
        return HStack(alignment: .top, spacing: 10) {

            Image(systemName: selected ? "circle.inset.filled" : "circle")
                .foregroundColor(
                    selected
                        ? .urGreen
                        : themeManager.currentTheme.textFaintColor
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                Text(description)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            mode = rowMode
        }
    }
}
