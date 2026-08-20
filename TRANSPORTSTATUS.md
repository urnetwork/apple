# TRANSPORTSTATUS — Apple transport-status UI

Status: intended behavior and review contract, 2026-08-20.

This document defines the Apple UI changes that expose the SDK's effective
Auto transport capability. It is written as a normative handoff for a second
agent reviewing the implementation in the current worktree.

## Outcome

The transport settings sheet must distinguish the user's saved policy from
what Auto can currently admit under platform constraints:

- With enough transport memory, Apple presents the same Auto behavior as every
  other platform: H1 is strictly preferred, followed by direct H3, whodis, and
  whodis pump. No degradation warning is shown.
- When the SDK says the configured Auto policy cannot fit, the sheet says Auto
  is degraded and identifies each enabled Auto transport that is currently
  ineligible.
- A constrained Auto transport remains enabled in the user's policy. The UI
  explains the runtime constraint; it does not silently rewrite settings.
- Status applies only to Auto. If the user explicitly selects H3, H1, whodis,
  or whodis pump, that explicit mode remains selectable and is sent unchanged
  to the SDK. In particular, low-memory Auto eligibility must never make an
  explicit H3 selection appear unavailable or convert it to H1.

The client transport sheet and provider transport sheet follow the same rules,
using their respective settings and status streams.

## SDK contract

The SDK exposes a `TransportStatus` alongside each persisted
`TransportSettings`:

- `autoDegraded`: whether at least one mode enabled by the current Auto policy
  cannot be structurally admitted.
- `autoEligibleModes`: the modes from that Auto policy that the platform can
  structurally admit.
- `autoConstraint`: the reason for degradation. The currently defined value is
  `memory` (`TransportConstraintMemory`).

Apple consumes the status through the gomobile bindings:

- `getTransportStatus()` and `addTransportStatusChangeListener(...)` for the
  client policy.
- `getProviderTransportStatus()` and
  `addProviderTransportStatusChangeListener(...)` for the provider policy.

The status has deliberately narrow semantics:

- It describes stable, structural Auto eligibility under the platform
  transport budget.
- It is not the active transport, a connectivity/health result, an indication
  that a connection is queued, or a report of temporary candidate contention.
- It is evaluated against the configured Auto mode set. For example, a
  low-memory device may report the default H3 + H1 policy as degraded with only
  H1 eligible, while an H3-only Auto policy may fit and report H3 as eligible.
- It continues to describe the retained Auto policy even while an explicit
  mode is selected. Therefore the UI must gate all status presentation on the
  selected mode actually being Auto.

The app must not reproduce memory thresholds, carrier reservation sizes, or
H1/H3 precedence. Those rules belong to the SDK. The UI renders the reported
status only.

## Settings-sheet presentation

The changes are confined to `TransportSettingsView` and are shared by iOS,
iPadOS, and macOS.

### Degraded banner

When all of the following are true, insert a warning section immediately above
the `Enabled under Auto` section:

1. The selected mode is Auto.
2. A non-nil status is available for the sheet's `TransportSettingsKind`.
3. `autoDegraded` is true.
4. The status and the settings being decorated are a paired applied snapshot;
   see **Draft versus applied status** below.

For the `memory` constraint, use this copy:

> Auto is degraded because system memory limits prevent some enabled transports from running.

Use an amber/orange `exclamationmark.triangle.fill` icon and the existing
secondary-body typography. If a future SDK returns an unknown non-empty
constraint, retain the degraded indication but use generic system-constraint
copy rather than incorrectly calling it a memory limit.

Do not show a success banner in the healthy case. Do not show the degraded
banner for any explicit mode, even if the retained Auto policy's status has
`autoDegraded == true`.

### Per-transport indicator

In the `Enabled under Auto` section, show a trailing amber warning triangle for
a transport exactly when:

```text
showAutoStatus
AND transport is enabled in the Auto policy
AND transport is absent from autoEligibleModes
```

The indicator belongs next to the transport label, before the toggle. Give it
the accessibility label:

> Unavailable due to system constraints

The same meaning must be announced by VoiceOver when the row is focused; do
not rely on orange color alone.

Important interaction rules:

- Do not turn the toggle off, disable it, dim the row, or remove the transport
  from the policy. A status constraint is not a settings-editing restriction.
- Continue to disable only the final enabled Auto toggle, as required by the
  existing SDK rule that Auto cannot have an empty mode set.
- Do not put Auto-eligibility warnings on the top-level explicit-mode rows.
- Never show warnings for P2P or `queued`; neither is an Auto-selectable
  platform transport.
- Preserve the SDK's existing transport order, names, colors, descriptions,
  and preference-tier explanation.

### Expected examples

| Selected policy | Runtime status | Expected presentation |
| --- | --- | --- |
| Default Auto; all configured modes eligible | Healthy | No banner and no row indicators. |
| Default Auto; only H1 eligible due to memory | Degraded, eligible `{H1}` | Memory banner; warning indicators on enabled H3, whodis, and whodis pump; no indicator on H1. |
| Auto with only H3 enabled and eligible | Healthy, eligible `{H3}` | No banner or indicator, even if the default multi-mode Auto policy would not fit. |
| Explicit H3; retained Auto policy is degraded | Degraded Auto status | No Auto banner or row indicators. H3 remains selected and Update sends explicit H3. |
| Auto; H3 is disabled in settings and absent from eligible modes | Any | No indicator on H3 because it is not enabled under Auto. |
| Status unavailable | Unknown | No banner or row indicators. Unknown must not be presented as either healthy or constrained. |

## Draft versus applied status

The SDK status returned by `DeviceRemote` is paired with the last applied
transport settings. The sheet, however, edits a draft and applies it only when
the user taps `Update`. Mixing the old status with a changed draft can produce
false warnings. A concrete counterexample is changing low-memory default Auto
to H3-only Auto: the old status may list only H1, while the SDK can admit H3
when H1 is no longer part of that draft.

Until the SDK exposes an eligibility preview for arbitrary draft settings, the
Apple UI must follow this rule:

- Render status decorations only while the normalized draft equals the latest
  applied settings paired with the status.
- Once a draft edit makes them differ, hide the banner and per-row eligibility
  indicators rather than guessing.
- If the user edits back to the applied policy, the decorations may reappear.
- `Update` continues to apply the policy and dismiss the sheet. The settings +
  status listener then supplies a new paired snapshot for the next render.

This rule also protects against a remote settings update arriving while the
sheet is open. Status must never be interpreted against an unrelated draft.

## Store and listener data flow

`TransportSettingsStore` remains the single app-level owner of transport
settings UI state. Extend it with independent client and provider runtime
status values.

Required flow:

1. Convert `SdkTransportStatus` into a small immutable Swift snapshot. Convert
   `autoEligibleModes` to `Set<TransportType>` so membership is explicit and
   duplicate entries cannot affect rendering. Preserve `autoConstraint`.
2. On `setup`, retain both SDK status subscriptions and marshal their callbacks
   onto the main actor before publishing state.
3. Seed both values using the corresponding status getters after listeners are
   installed, so there is no startup gap.
4. On `reset`, close and clear both subscriptions and clear both published
   status values. Status from a previous device must never bleed into a new
   session.
5. Route `.client` only to client status and `.provider` only to provider
   status.
6. Treat a nil getter/listener value as unknown and keep the UI free of warning
   claims. Do not synthesize eligibility from local settings.

Status is runtime state owned by the packet-tunnel extension. It must not be
persisted into the app's `LocalState`; only transport settings are persisted.
The existing RPC path deliberately sends status paired with its settings
snapshot and should remain the source of truth.

## Explicit-mode invariant

The status UI must not alter transport selection behavior:

- Selecting an explicit mode sets `SdkTransportSettings.mode` to that exact
  mode and uses the existing `TransportSettingsStore.apply` path.
- Auto status does not disable explicit H3 on iOS.
- No Apple-side memory check substitutes H1 for explicit H3.
- No UI message should imply that H1 is being used when the saved selection is
  explicit H3.

Runtime enforcement belongs to Connect/SDK, but the reviewer should verify the
Apple draft, restore-default, dirty-state, and Update paths preserve this
invariant.

## Accessibility and localization

- Add localization catalog entries for the memory banner, the generic fallback
  banner if implemented, and the per-row accessibility label.
- Include translator comments that explain Auto, transport eligibility, and
  that the per-row text is a system-constraint warning.
- Keep product carrier names (`H3`, `H1`, `whodis`, and `whodis pump`) under
  their existing localization policy.
- Verify Dynamic Type does not clip the banner, label, warning icon, or toggle
  on narrow iPhones.
- Verify VoiceOver announces both the enabled state and the system-constraint
  warning for an affected row.
- A localization change should add the required keys without reformatting
  unrelated catalog entries. Large mechanical catalog churn is outside this
  change and should be removed before landing.

## Expected implementation surface

The review should normally find changes in:

- `app/network/Shared/ViewModels/TransportSettingsStore.swift`
  - runtime status snapshot;
  - client/provider published values;
  - getter seeding, listeners, and reset cleanup.
- `app/network/Shared/Views/Stats/TransportSettingsView.swift`
  - degraded banner;
  - constrained-row indicator;
  - Auto-only and applied-snapshot gating.
- `app/network/Shared/Resources/Localizable.xcstrings`
  - the new user-facing and accessibility strings only.
- `app/networkTests/TransportStatsTests.swift`
  - deterministic status-presentation tests.

No status decoration is required on `TransportDistributionBar`: that component
reports which transports carried traffic in its statistics window, which is a
different concept from structural Auto eligibility. No `NetworkApp` wiring
change should be necessary if the existing `TransportSettingsStore`
environment object remains shared by both sheets.

The Apple SDK framework used by the app must contain the new
`SdkTransportStatus` getters and listener protocols. A source change that
compiles only against a developer's stale/generated local binding is not
complete.

## Deterministic test matrix

Prefer extracting the display predicates into a pure, internal helper so the
following cases do not require a live tunnel or memory pressure:

1. Auto + healthy + every mode eligible: banner false; no constrained rows.
2. Auto + degraded + eligible H1 only: banner true; H3/DNS/DNS-pump constrained;
   H1 unconstrained.
3. An Auto-disabled mode absent from eligibility: unconstrained in the UI.
4. Explicit H3 + degraded retained-Auto status: banner false; no constrained
   rows; applied mode remains H3.
5. Nil status: banner false; no constrained rows.
6. Client and provider status snapshots do not cross-contaminate their sheets.
7. Dirty draft different from the paired applied policy: banner false; no
   constrained rows. Returning the draft to the applied policy restores them.
8. Unknown `autoConstraint` uses generic copy and does not crash or silently
   report a memory-specific reason.
9. Unknown SDK mode strings are ignored safely while the authoritative
   `autoDegraded` banner remains renderable.
10. Store reset clears status and closes subscriptions.

Run at minimum the focused Apple unit tests plus iOS and macOS compilation of
the shared settings view. Manually inspect one compact-width Dynamic Type view
and one VoiceOver traversal because icon/toggle composition is not fully
covered by model tests.

## Reviewer checklist

The second-agent review should explicitly answer:

- Is status sourced from the SDK, without Apple-side budget calculations?
- Are client and provider status kept separate and listener lifetimes bounded?
- Are warnings shown only for Auto and only for enabled-but-ineligible modes?
- Is nil status treated as unknown rather than degraded or healthy?
- Can a dirty draft ever be decorated using status computed for different
  settings?
- Does explicit H3 remain enabled, selected, and applied unchanged on iOS?
- Are constrained Auto toggles still editable?
- Can VoiceOver discover the reason for each warning without relying on color?
- Are tests deterministic and independent of the host machine's memory?
- Is the localization diff limited to the intended keys?

## Implementation notes (fix pass, 2026-08-20)

Decisions made while bringing the five implementations up to this contract:

- **Draft-versus-applied gate**: every editor computes its decorations through
  one pure predicate — Apple `TransportStatusPresentation.compute` (in
  `TransportSettingsStore.swift`), Android
  `TransportStatusPresentation` (generic over the transport key so the JVM
  matrix needs no native sdk classes), Linux/Windows the header-only
  `TransportStatusDecorations` (`TransportStatusPresentation.hpp` / `.h`).
  Pairing: on Apple/Android the store/view-model records the applied policy
  current at each status arrival (`statusPolicy(kind)`; the device fires the
  paired settings event first, and an offline queued edit intentionally goes
  stale-hidden until the next synced pair). On Linux/Windows the status is
  fetched once at sheet open, paired with `original_`, and the gate is
  `transportSettingsEqual(draft, original)`. The web panel is read-only (no
  draft), so the gate does not apply there.
- **`autoConstraint`**: `memory` selects the memory banner; any other value
  (including empty-while-degraded) selects the generic copy
  "Auto is degraded because system constraints prevent some enabled
  transports from running." — store key `transport_auto_degraded`
  (web `site_app_transport_auto_degraded`).
- **Warning color**: amber `#F5C242` on every platform (`Color.urAmber`,
  Android theme `Amber`, `.ur-amber` GTK class, `colors::kUrAmber`, web
  `#f5c242`) — the earlier yellow collided with the whodis pump brand color.
- **Accessibility**: the per-row reason is announced, not only colored/tipped —
  `accessibilityLabel` (Apple), `contentDescription` (Android),
  `Gtk::Accessible::Property::LABEL` (Linux),
  `AutomationProperties::SetName` (Windows), `aria-label` (web).
- **Strings** live in the localizations store
  (`transport_auto_degraded_memory`, `transport_auto_degraded`,
  `transport_unavailable_system_constraints`); android/windows/linux outputs
  regenerated, the Apple catalog diff reduced to exactly the three entries.
- **Test matrix**: implemented over the pure predicates — Apple
  `TransportStatsTests` (16 green on the sim), Android
  `TransportStatusPresentationTest` (8 green on the JVM), Linux
  `TransportStatusPresentationTest.cpp` (8 green under meson), web
  `transport-stats.test.mjs` (6 suites green). The store-reset and
  client/provider-separation cases are covered by the store accessors' shape
  plus review; they need a live device to drive further.
- **Artifacts**: linux vendored headers refreshed from the 2026-08-20
  `URnetworkSdkLinux.zip` (all status TUs compile; `SdkHost.cpp` needs the
  Linux-only `SOCK_CLOEXEC` shimmed on macOS — pre-existing); web `sdk.wasm`
  rebuilt and `sync-sdk.mjs` now guards the status bindings; the Windows
  `URnetworkSdkWindows.zip` still needs the on-VM rebuild before the app
  compiles (unchanged blocker).
