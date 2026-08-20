# TRANSPORTSTATS — transport distribution bar + transport settings editor

Status (2026-08-18): iOS/macOS DONE (builds + unit tests). Android DONE
(compiles + unit tests; not run on device). Linux DONE source-verified (all
sources compile against the refreshed headers with the local gtkmm toolchain,
geometry tests pass; final GUI link needs the rebuilt SDK .so staged — see
below). Windows DONE source-only (no MSVC on this Mac; needs an on-Windows
build with the rebuilt SDK zip). Web (mmm/ur.io) DONE read-only (lint/build/
tests + Playwright harness against SDK-shaped fixtures). This document is the
design record and the port checklist.

## Goal

Give the user a sense of the proportion of transfer handled by each transport
type in the stats window, and let them configure the transport policy from the
same place.

1. Under the client packet stats time series (the "Remote" transfer chart in the
   connect drawer's Client statistics card) show a stacked bar where each
   transport with traffic in the stats window is a segment sized to its share
   of the window's remote traffic. Segments stack to exactly 100% and the bar
   is the full width of the drawer card so it lines up with the transfer plot.
2. Each transport has a brand color.
3. An enabled transport with no traffic in the window is NOT drawn as a
   zero-width segment; it is listed in an "unused" footer under the bar.
4. Tapping the bar component opens the transport settings editor: a single
   transport, or Auto with a per-transport enable under Auto. The user does not
   reorder the Auto preference; the SDK default order is preserved.
5. Naming: the `dns` transport is "whodis", the `dnspump` transport is
   "whodis pump".
6. Bar widths tween with the app's general 1s tween, and the widths add up to
   100% at every frame of the tween.
7. Transport settings persist to local state and restore correctly.

## SDK surface used / added

### Already in the SDK (uncommitted work in `/Users/brien/urnetwork/sdk`)

- `transport_settings.go`: `TransportSettings{Mode, AutoModePriorities}`,
  `TransportModePriority{Mode, Priority}`, modes `auto|h3|h1|dns|dnspump`,
  transport types `h3|h1|dns|dnspump|p2p|unknown` (the mode and type strings
  are identical for the selectable carriers), `DefaultTransportSettings()`
  (auto: h3=1, h1=1, dns=2, dnspump=3), `DefaultProviderTransportSettings()`,
  `normalizeTransportSettings` (an EMPTY auto policy resolves to the full
  default — so the editor must never send an empty auto set), hosted devices
  pinned to H1 with the setters no-oped.
- `Device.Set/GetTransportSettings`, `Set/GetProviderTransportSettings`; wired
  through `DeviceLocal` (make-before-break migration of live windows),
  `DeviceRemote` (rpc + offline pending state, applied on Sync before the
  destination), and `LocalState.Set/GetTransportSettings` +
  `Set/GetProviderTransportSettings` (`.transport_settings` /
  `.provider_transport_settings` JSON files). `DeviceLocal` persists on every
  change and restores at creation.
- `PacketStats.TransportStats *TransportPacketStatsList`: the cumulative
  REMOTE egress/ingress counters partitioned by carrier (every type present,
  including `unknown` = admitted, not yet written to a physical route; the
  attribution MOVES to the real carrier on the first route write). Local and
  blocked traffic never enter a carrier and are absent from the breakdown.
  Crosses the rpc (`PacketStatsRpc.TransportStats`).

### Added for this feature (this session)

Principle: the math lives in the SDK view model so it is tested once in Go
and reused by every platform; apps only draw.

`sdk/contract_view_controller.go` (the app-side throughput series view
controller; `//go:build !ios_extension`):

- `TransportShare{TransportType, Egress/IngressByteCount, Egress/IngressPacketCount,
  Share, Boundary, Percent, Used, Enabled}` + `TransportShareList`, and
  `TransportDistribution{Shares, ByteCount, Active}`.
- `ContractViewController.GetTransportDistribution()` and
  `GetProviderTransportDistribution()`: the remote traffic inside the
  throughput window (same window as the points, evaluated as of now)
  partitioned per transport in the stable order (h3, h1, dns, dnspump, p2p,
  unknown), every type present, READY TO RENDER:
  - `Share` = byte fraction of the window total (both directions), 0 while
    idle; `Boundary` = running sum in stable order = the right edge of the
    segment (the last transport's boundary is exactly 1 when active, 0 when
    not) — drawing every segment from its neighbours' boundaries tiles 100%
    at every tween frame; `Percent` = whole percents by largest remainder over
    the used transports (ties by stable order) so they sum to exactly 100 (a
    used sliver can be 0 → apps label it "<1%"); `Used` = carried traffic;
    `Enabled` = the device's client/provider `TransportSettings` enable it
    (`TransportSettings.EnabledTransportTypes`); p2p/unknown are never enabled
    but are always drawn when used. `Active` = any traffic in the window.
  - Computed from per-point per-transport SIGNED deltas kept on an unexported
    `ThroughputPoint.transportDeltas` field, summed over the in-window points
    and clamped at zero per transport at the end. Signed because the `unknown`
    bucket legitimately DECREASES when an admitted packet is attributed to its
    carrier at a later sample than the one that admitted it; clamping per point
    would double count the moved bytes as unknown. Summed over the window the
    real carriers are exact and unknown reconciles to (approximately) zero.
  - A reset of the aggregate accumulators (the case the route deltas clamp for)
    zeroes the per-transport deltas of that direction for the point, so a reset
    can never leave a phantom negative total. Points without a carrier
    breakdown contribute nothing. The provider mirror carries the deltas.
  - The enabled flags are cached from the device's transport settings change
    listeners (`AddTransportSettingsChangeListener` /
    `AddProviderTransportSettingsChangeListener`, DNS-settings pattern: fired
    by DeviceLocal on change, forwarded over the rpc, re-fired with the
    extension's truth on every sync, fired locally by DeviceRemote for an
    offline queued edit), seeded once with `Get(Provider)TransportSettings()`
    at open. No per-call rpc.
- Notification tail change: `throughputSeriesNeedsNotification` is now true
  while ANY retained point is active (previously: 5 zero samples after
  activity). Rationale: as active points age out of the window the window
  distribution changes even though the newest samples are zero, so the app
  needs the ticks until the last active point has been trimmed (bounded by the
  window + 2 buffer points). `throughputSeriesNotifyWithLock` additionally
  delivers exactly one idle snapshot when a series starts or goes quiet, so a
  fresh series still publishes its first zero points (the app resolves e.g.
  `hasProviderStats` from that) and the final inactive window state lands.

`sdk/transport_settings_view.go` (`//go:build !ios_extension` — the
extension only applies a policy, never renders/edits one, and its slice has a
compiled-size budget) — shared editing rules, exported for every app:

- `SelectableTransportModes() *StringList` (h3, h1, dns, dnspump: the default
  preference order every list shows), `DefaultTransportModePriority(mode)`.
- Methods on `TransportSettings`: `Clone()`, `Equals(other)` (normalized),
  `AutoModes()` (enabled under Auto in preference order, retained while a
  single mode is selected), `IsAutoModeEnabled(mode)`,
  `SetAutoModeEnabled(mode, enabled) bool` (a newly enabled mode takes its
  default priority so the default order is preserved; re-enabling keeps a
  custom priority; disabling the LAST enabled mode is refused since an empty
  Auto policy normalizes to the full default), `EnabledTransportTypes()`
  (single mode → its carrier; Auto → the auto modes' carriers).
- By-value variants of the same rules for bindings that cross data structs as
  json (the desktop C ABI has no methods on json structs):
  `TransportSettingsAutoModes(settings)`,
  `TransportSettingsEnabledTransportTypes(settings)`,
  `TransportSettingsWithMode(settings, mode)`,
  `TransportSettingsWithAutoModeEnabled(settings, mode, enabled)` (a refused
  edit returns an equal copy), `TransportSettingsEqual(a, b)`. Never modify
  the input. Test: `TestTransportSettingsValueHelpers`.
- JS bindings: `contractViewController.getTransportDistribution()` /
  `getProviderTransportDistribution()` (`sdk/js/view_controllers.go`);
  device: `getTransportSettings()` / `getProviderTransportSettings()` /
  `set…` / `addTransportSettingsChangeListener(cb)` /
  `addProviderTransportSettingsChangeListener(cb)` /
  `getDefaultTransportSettings()` / `getSelectableTransportModes()` /
  `transportSettingsWithMode` / `transportSettingsWithAutoModeEnabled` /
  `transportSettingsEqual` (`sdk/js/device_remote.go`); a policy crosses as
  `{mode, autoModePriorities:[{mode,priority}], autoModes:[…],
  enabledTransportTypes:[…]}`.
- C ABI (`sdk/cgo`, regenerated 2026-08-18): `urnet_contract_view_controller_get_(provider_)transport_distribution`,
  `urnet_device_get/set_(provider_)transport_settings`,
  `urnet_device_add_(provider_)transport_settings_change_listener`
  (`urnet_transport_settings_change_cb(user_data, settings_json)`),
  `urnet_selectable_transport_modes`, `urnet_default_transport_mode_priority`,
  `urnet_transport_settings_{auto_modes,enabled_transport_types,with_mode,with_auto_mode_enabled,equal}`,
  `URNET_TRANSPORT_MODE_*` / `URNET_TRANSPORT_TYPE_*` defines.
- Tests: `TestContractViewControllerTransportDistribution` (exact carriers,
  unknown reconciliation, window bound, reset guard, missing breakdown,
  provider mirror, enabled flags), `TestNewTransportDistribution` (render
  math), `TestContractViewControllerEnabledFlagsFollowTransportSettings`
  (listener-driven enabled flags), `TestTransportSettingsEditingHelpers`
  (`transport_settings_view_test.go`),
  `TestThroughputSeriesNotificationStopsWhenRetainedPointsIdle`,
  `TestThroughputSeriesNotifyDeliversOneIdleSnapshot`.
- Size gate: `sdk/build/check_apple_size.sh` ceilings bumped 2026-08-18
  (app sdk 55 → 56 MiB, extension sdk 52 → 53 MiB; extension executable stays
  39 MiB) — the growth from the transport work is intentional.
  Measured: app sdk 54.993 MiB, extension sdk 52.070 MiB, unsigned Release
  extension 37.164 MiB. The app-facing policy helpers live outside the
  `ios_extension` binding to keep the extension slice lean. Recorded in
  `sdk/build/APPLE_EXTENSION_MEMORY_BUDGET.md`.
- The desktop cgo C-ABI (`sdk/cgo`) was regenerated alongside the listener
  work; regenerate again after the SDK surface settles.

Design decisions taken on the SDK side:

- Per-point transport samples are NOT exported (no `Transports` list on
  `ThroughputPoint`): the UI needs the window aggregate, per-point values are
  awkward to expose (signed), and it keeps the gomobile bridge cost per tick
  flat.
- The bar shows EVERY transport with traffic in the window (p2p, and unknown
  as "queued"), whether or not it is enabled — the goal is the truthful
  proportion. Only the unused footer is settings-driven.

## Apple app design

Files (all under `app/network`, a synchronized Xcode group — no pbxproj edits):

- `Shared/ViewModels/TransportSettingsStore.swift`
  - `TransportType` enum (raw values = SDK strings): PRESENTATION ONLY —
    `label` (H3, H1, whodis, whodis pump, P2P, "queued" for unknown),
    `detail`, brand `color(theme)`: H3 urGreen, H1 urLightBlue, whodis urPink,
    whodis pump urYellow, P2P urElectricBlue, queued dark neutral (theme faint,
    2026-08-20: was theme muted, which read too close to the pale H1 blue —
    same swap on all five platforms: TextFaint / kUrTextFaint / kTextFaint /
    #5a5a5a). Coral is deliberately not used so the bar cannot be confused with
    the Blocked chart next to it. `selectable` reads `SdkSelectableTransportModes()`.
  - `TransportSettings`: a render SNAPSHOT of an `SdkTransportSettings`
    (`singleTransport`, `autoTransports`, `enabledTransports`, all via the SDK
    helpers) that keeps the `sdk` object; edits go through the SDK object then
    a fresh snapshot is taken. No policy rules in Swift.
  - `TransportSettingsStore` (`@MainActor ObservableObject`): publishes
    `clientSettings` / `providerSettings` from the device's transport settings
    change listeners (initial `refresh()` read); `apply(sdk:kind:)` sets on the
    device AND mirrors into the app's `SdkLocalState`; the applied policy comes
    back through the listener (extension truth when connected, the queued
    value when not, and again on every rpc sync).
- `Shared/ViewModels/ThroughputStore.swift`: `TransportShare` /
  `TransportDistribution` mirrors of the SDK types (plus the render helpers
  `boundaries` → `AnimatableVector`, `used`, `unused`), published as
  `clientTransportDistribution` / `providerTransportDistribution` from the same
  `SdkContractViewController` tick as the points (dedup-guarded).
- `Shared/Views/Stats/TransportDistributionBar.swift`: the bar component,
  draws the SDK numbers.
  - Geometry from ONE animatable vector = the SDK boundaries rendered by a
    `ViewModifier & Animatable` Canvas, so the segments tile 100% at every
    frame of the 1s easeInOut tween, and a transport entering/leaving
    grows/shrinks between its neighbours. Hairline separators in the card
    color between visible segments, eased in with the narrower segment.
  - Empty window (`active == false`): the segments fade out over the tween
    while the last shape is held, leaving a faint track; every enabled
    transport is then in the unused footer.
  - Legend row (used shares: dot + name + SDK percent, "<1%" for a used 0,
    `numericText` roll) and unused footer row (hollow dots + names, faint,
    prefixed "unused"); rows wrap on narrow drawers (`FlowRow` layout, every
    item in a line placed on the line's shared last-text-baseline so the names
    and the "unused" label sit on one common baseline). Title
    row "Transports ›" so the nested tap target reads as its own control inside
    the tappable card. Whole component tappable → editor.
- `Shared/Views/Stats/TransportSettingsView.swift`: the editor sheet, same
  shape as `DnsSettingsView` (draft + Update button). The draft is an SDK
  policy (`clone()`), edited via `mode` / `setAutoModeEnabled`, dirty via
  `equals`. Sections: transport mode (Auto / H3 / H1 / whodis / whodis pump as
  check rows with color dot and a one-line description) and, under Auto, an
  enable toggle per carrier in the SDK order with a footer explaining the fixed
  order and the parallel same-tier behavior; the last enabled carrier's toggle
  is shown disabled (the SDK refuses the edit anyway). "Restore default
  transports" when not on the default. Parameterized by
  `TransportSettingsKind` (client / provider).
- `Main/Connect/ConnectStatsSections.swift`: the bar sits directly under the
  Remote chart in the Client statistics card (12pt gap, then the Blocked
  chart); `ConnectStatsSheet.transportSettings` case; `ConnectStatsSheets`
  presents `TransportSettingsView(kind: .client)`.
- `Main/Account/Wallets/WalletsView.swift` `ProviderStatsSection`: the same bar
  under the provider Local chart with the provider distribution, opening the
  editor for `.provider` (a local `.sheet`).
- `NetworkApp.swift`: `TransportSettingsStore` created, setup/reset with the
  other device stores (setup gets `deviceManager.asyncLocalState?.getLocalState()`),
  injected into the environment on both platforms.
- `Shared/ViewModels/DeviceManager.swift` `initDevice`: seeds the device remote
  with the app-mirrored client/provider transport settings when present.
- `Shared/Resources/Localizable.xcstrings`: en entries added by hand (xcodebuild
  does not extract) in Xcode's key order.
- `networkTests/TransportStatsTests.swift`: the mirror layer (SDK object →
  snapshot, animatable vector, render helpers, SDK editing helpers reachable
  from Swift).

### Persistence / restore (item 7)

The device (extension-side `DeviceLocal`) persists the policy in ITS local
state on every change and restores it at creation — a policy set while the
tunnel runs survives extension restarts with no app involvement. The app and
the extension do not share storage on Apple (each uses its own Documents
directory), and `DeviceRemote` only holds pending/last-known state in memory,
so on their own an edit made while the tunnel is down would be lost on app
relaunch and the offline reads would show the default. Hence:

- `TransportSettingsStore.apply` mirrors every edit into the app's
  `SdkLocalState` (`setTransportSettings` / `setProviderTransportSettings`).
- `DeviceManager.initDevice` seeds `device.setTransportSettings(...)` from the
  mirror when one exists (nil = never edited → the extension's persisted or
  default policy stands). The seed queues on the remote and is applied on the
  next Sync (before the destination, so a new window starts on the requested
  modes), then persisted extension-side. Offline reads return the seeded
  policy, so the bar footer and the editor are right before the tunnel runs.
- On rpc connect the store re-reads so the extension's normalized truth wins.

## Port checklist (Android, web, Windows, Linux)

- SDK bindings are current as of 2026-08-18: Android AAR rebuilt
  (`make build_android`), wasm js device + vc bindings written (the web's
  `sync-sdk.mjs` rebuilds the wasm on build), C ABI regenerated
  (`make -C sdk/cgo generate`) and cross-built for linux/amd64 + windows/amd64.
- Read `getTransportDistribution()` (and the provider one) on the same
  throughput tick as the points; draw the SDK `boundary` per share as one
  animated vector over 1s; segments for `used`, footer for `enabled && !used`;
  fade + hold when `!active`; legend from `percent` with "<1%" for a used 0.
- Presentation only in the app: names "whodis"/"whodis pump"/"queued", the
  same brand colors, list order = `SelectableTransportModes()`.
- Editor: mode rows + Auto toggles driven by the SDK helpers
  (`Clone/Equals/AutoModes/IsAutoModeEnabled/SetAutoModeEnabled`); Update
  applies via `setTransportSettings` (`setProviderTransportSettings` for the
  provider surface).
- Persistence: platforms where the app and the device share one local state
  (Android's device runs in-process? verify per platform) may not need the
  app-side mirror; where a remote device is used, mirror + seed like Apple.

## Port status / verification ledger (2026-08-18)

- **Android** (`/Users/brien/urnetwork/android`): bar `ui/stats/TransportDistributionBar.kt`,
  editor `TransportSettingsScreen.kt` + `TransportSettingsViewModel.kt`, distribution in
  `ThroughputViewModel.kt`, placed in `ConnectStatsSections.kt` (client) and
  `ProviderStatsSection.kt` (provider), route `Route.TransportSettings(provider)`.
  In-process DeviceLocal → no app-side persistence mirror (device persists itself).
  Verified: `:app:compileGithubDebugKotlin -x buildSdk` + 5 geometry unit tests.
  AAR rebuilt (`make build_android`). Not run on a device.
- **Linux** (`/Users/brien/urnetwork/linux`): `app/src/TransportBar.*`,
  `TransportSheet.*`, `TransportPresentation.*`, `TransportBarGeometry.hpp` (+4 tests),
  wiring in `SdkHost.*` / `ConnectDrawer.*` / `ConnectPage.*`; GUI↔root-daemon mirror+seed
  (separate local state). Vendored headers refreshed from sdk/cgo. All sources compile
  locally (gtkmm 4.22), tests 102/102; GUI link blocked only on the stale vendored `.so`.
  To finish: stage `sdk/cgo/build/URnetworkSdkLinux.zip` (rebuilt 2026-08-18, amd64+arm64,
  repacked) via `app/scripts/fetch-deps.sh`, then an on-Linux meson build. No provider stats surface
  on Linux → no provider bar (provider plumbing is wired and ready).
- **Windows** (`/Users/brien/urnetwork/windows`): `app/src/App/TransportBar.*`,
  `TransportSettingsSheet` in `StatsSheets.*`, feeds/listeners/mirror+seed in `SdkHost.*`
  (DeviceRemote to the service, separate storage → Apple-style mirror), row in
  `MainWindow.xaml` under the Remote chart, `UrColors.h` +kUrLightBlue/+kUrYellow.
  Source-only: needs `make -C sdk/cgo build_windows` (amd64 DLL built 2026-08-18;
  arm64 needs aarch64-w64-mingw32-clang, not installed here, so
  `URnetworkSdkWindows.zip` was NOT repacked — repacking would pair a fresh amd64
  with the stale Aug-11 arm64) → `fetch-deps.ps1` → on-Windows build. No provider stats surface on Windows → no provider bar (sheet is
  parameterized for Provider).
- **Web** (`/Users/brien/urnetwork/mmm/ur.io`): read-only — bar + display-only
  "Transports" slide-in panel (hosted device pinned to h1; no setters exposed in
  `deviceStore.js` by design). Files: `react/src/app/connect/transports.js`,
  `TransportDistributionBar.jsx/.module.css`, `TransportSettingsPanel.jsx/.module.css`;
  wired in `ConnectStats.jsx` (client, under the Transfer plot) and
  `screens/ProviderStats.jsx` (provider); distribution read on the same throughput
  tick in `useViewControllers.js` (`useContractStats` + new `useTransportSettings`).
  CSS width transitions on cumulative left-anchored layers = one tweened boundary
  vector (tiling verified mid-tween by measurement). Verified: wasm rebuilt via
  `sync-sdk.mjs` (new exports present), lint at baseline, `npm run build` green,
  `npm run test:transport-stats` 4/4 + existing script tests, Playwright visual
  checks. Left open: web i18n ids (`site_app_transport_*`) not registered in the
  panel-keys/localizations store — English fallbacks serve (the DNS card already
  ships with unregistered ids today); no end-to-end against a live hosted device.
- **Localizations** (`/Users/brien/urnetwork/localizations`): 15 transport keys added to
  `keys/` for android+apple+linux+windows; `gen:linux` / `gen:windows` run (po/resw in
  sync), android strings.xml matches the store, apple catalog carries the keys by hand.
  CAUTION: the apple catalog has ~50 pre-existing keys (reliability/developer settings)
  that exist ONLY in the catalog, not the store — import them into `keys/` before anyone
  runs `gen:apple`, or it will drop them. The Windows transport names
  (`transport_h3/h1/dns/dnspump/p2p` ids) intentionally have no store keys yet — they are
  non-translatable product names using in-code English fallbacks; add
  `translatable: false` keys if wanted.

### Legend baseline pass (2026-08-20)

Invariant: within a legend/footer line, all names (and the "unused" label) sit
on one common text baseline.

- **Apple**: the real bug — `FlowRow` placed each item centered at the running
  row height, so the first item of every line rode half a line high. Rewritten
  as a two-pass layout that aligns every item on the line's shared
  last-text-baseline (`TransportDistributionBar.swift`). Verified: app builds,
  `TransportStatsTests` 7/7 on the sim.
- **Android**: `itemVerticalAlignment = Alignment.Bottom` on both FlowRows
  (Compose has no cross-item baseline in FlowRow; bottom ≡ baseline for the
  uniform 11sp labels and stays closest if heights ever diverge). Verified:
  `:app:compileGithubDebugKotlin` against a fresh AAR.
- **Linux**: `WrapRow` now bottom-aligns items in a row (was center — already
  two-pass, no first-item bug); chip labels `set_valign(END)` because the
  `ur-mono-11` percent face has different metrics from the caption face, so
  per-chip centering skewed their baselines. Verified: TU compiles (ninja).
- **Windows**: cross-item alignment was already exact (every inline is an
  `InlineUIContainer` bottom-anchored on the RichTextBlock line baseline);
  within chips the Consolas percent vs Segoe name were center-skewed →
  `VerticalAlignment::Bottom` on the chip labels. Source-only (no local build).
- **Web**: nothing applicable — all legend text is the same 11px face, so flex
  `align-items: center` is exactly baseline-aligned; switching to
  `align-items: baseline` would REGRESS (a chip's flex baseline comes from its
  first item, the empty dot span, whose synthesized baseline is its bottom
  edge mid-text). Leave center.
