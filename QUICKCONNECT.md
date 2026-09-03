# Quick connect control and Home Screen widgets (iOS, macOS)

Status, 2026-09-01: designed and implemented on `main` (uncommitted). The iOS
simulator build and the macOS build of the whole project pass. The App ID
`network.ur.widgets` is registered; signed development builds install and
run on an iPhone 16 Pro Max (iOS 26.6), where the control, the dashboard and
the globe have been exercised by hand and two rendering issues were fixed
(section 8). The contracts widget is built but not yet exercised on the
phone.

Four native surfaces ship from one new widget extension target,
`URnetworkWidgets` (`app/widgets/`, bundle id `network.ur.widgets`):

| surface | where | since |
| --- | --- | --- |
| **Quick connect control** — a toggle with the UR connector mark | Control Center, Lock Screen bottom slots, Action button; macOS 26 Control Center and menu bar; mirrored to Apple Watch | iOS 18, macOS 26 |
| **Dashboard widget** — transfer balance bar, connected location, quick connect, client and provider throughput | Home Screen (medium, large), macOS desktop and Notification Center | iOS 17, macOS 14 |
| **Provider globe widget** — the provider details globe with the connected providers and their list | Home Screen (small, medium, large), macOS | iOS 17, macOS 14 |
| **Contracts widget** — the top client contracts as a flowing grid of per-peer send/receive stacks | Home Screen (small, medium, large), macOS | iOS 17, macOS 14 |

The three share one intent (`ToggleTunnelIntent`), one state source
(`NEVPNStatus`, read live), one snapshot pipeline (App Group files written by
the tunnel extension and the app) and one integration contract with the app's
reconciler (the shared tunnel intent, section 3). The July draft in
`app/control/` (which foregrounded the app on every toggle) is replaced.

## 1. What the research settled

### 1.1 Apple's Controls framework (iOS 18+)

- A control is a `ControlWidget` in the widget extension: a configuration
  (`StaticControlConfiguration(kind:provider:)`), a `ControlValueProvider`
  (`previewValue` for the gallery, `currentValue()` fetched asynchronously
  "when the actual control needs to be rendered"), and a template. Toggles
  have two states and take a `SetValueIntent<Bool>`; buttons are for
  fire-and-forget actions. [C1][C2][C3]
- **Refresh has exactly three triggers**: the assigned intent's `perform()`
  returning ("the system queries for the state of a control when `perform()`
  returns; finish all actions and save all state data before it returns"),
  `ControlCenter.shared.reloadControls(ofKind:)`, and a `controls` APNs push
  through a `ControlPushHandler`. Nothing re-queries a control when Control
  Center opens or the device unlocks. [C3][C4]
- **The intent runs in the widget extension's process** unless it sets
  `openAppWhenRun` (deprecated in iOS 26 for `supportedModes`) or conforms to
  `ForegroundContinuableIntent` / `LiveActivityIntent` / `AudioPlaybackIntent`,
  in which case it runs in the app's process. Controls whose actions foreground
  the iPhone app are not mirrored to Apple Watch (watchOS 26). [C5][C6][C10]
- **Only symbol images render**: SF Symbols or custom symbols from a
  `.symbolset`. Asset-catalog bitmaps stopped rendering in iOS 18 beta 4 and
  were never restored; DTS also notes that `imageScale`/`resizable` do nothing
  because "the system manages the scaling and presentation of control
  visuals". [C3][C7][C8]
- What renders where: Control Center shows the symbol at every size and adds
  the title and value text at the larger sizes; the Lock Screen slot shows
  only the symbol; the Action button shows the symbol and the value in the
  Dynamic Island, with `controlWidgetActionHint` as the "Hold to …" text. The
  tint colors the symbol and value text when the toggle is on. [C9][C10]
- HIG: provide a symbol for both the on and off states, choose a tint that
  works with the brand, use verbs for Action button hints, require
  authentication for actions that affect security, and update on
  interaction, completion, or push. [C9][C11]
- The template's content closure uses `ControlWidgetTemplateBuilder`, which
  has **no `if`/`else`** — a control cannot swap between a toggle and a button
  by state (compiler: "closure containing control flow statement cannot be
  used with result builder"). The template can be `.disabled(_:)`, which is
  how Apple's own VPN control greys out with nothing configured.
- Intents get 30 s in the background. `authenticationPolicy` defaults to
  `alwaysAllowed` (works on a locked phone); `requiresAuthentication` asks for
  Face ID / Touch ID first. [C5][C12]

### 1.2 Driving the packet tunnel from the widget process

- `NETunnelProviderManager` needs `com.apple.developer.networking.networkextension`
  (`packet-tunnel-provider`) in **every process that loads the
  configuration**; the Personal VPN entitlement (`vpn.api`, which the July
  draft used) gates the built-in IKEv2/IPsec transports only — Quinn (DTS):
  "don't add the Personal VPN capability". The widget extension's App ID must
  have the Network Extensions capability like the app and the tunnel. Missing
  it fails with `NEConfigurationErrorDomain Code=10 "permission denied"`.
  [N1][N2][N3]
- Apple never documented that a same-app extension can see the app's
  configuration (DTS said the opposite in 2016–2021), but it works today:
  sing-box for Apple (June 2024), Mozilla VPN 2.37 (May 2026), NetBird
  0.3.1 (July 2026) and Nym VPN all call `loadAllFromPreferences`,
  `startVPNTunnel` and `stopVPNTunnel` from their widget extension. NetBird
  found that the first load in a fresh widget process can return empty and
  retries once after 300 ms. [P1][P2][P3][P4]
- The tunnel's lifecycle is the system's, "unrelated to the lifecycle of its
  container app" (Quinn), so the widget process being suspended right after
  `perform()` does not cancel the start. [N4]
- **On-demand must be disabled before a stop** or the system restarts the
  tunnel at once (sing-box's March 2026 fix, Mullvad, WireGuard all do this);
  the provider process cannot modify its own configuration. [N5][N6]
- `ControlCenter.shared.reloadControls` / `WidgetCenter.reloadTimelines`
  from the tunnel process is not blocked and sing-box, Mozilla and NetBird do
  it, but DTS called it "an edge case that no one considered" and NetBird
  hedges that reloads from the NE can be suppressed when the app is closed.
  Every shipping app therefore combines provider-side reloads with app-side
  reloads on `NEVPNStatusDidChange` and a value provider that reads the live
  status. [N7][P1][P2][P3]
- The system's own iOS 18.1 "VPN" control toggles whatever configuration is
  enabled in Settings > VPN, cannot be added to the Lock Screen or the Action
  button, has no branding or status text, and users report it connects
  unreliably with several VPN profiles. That gap is why every VPN app ships
  its own. [N8][N9]

### 1.3 What this app already does

- The packet tunnel extension **boots fully standalone** from
  `providerConfiguration` (`by_jwt`, `instance_id`, `network_space`, the RPC
  PEMs and host:port) and prefers the freshest JWT from the shared Keychain,
  rotating it itself (`extension/PacketTunnelProvider.swift`,
  `SharedTunnelJwtStore`). `startTunnel(options:)` ignores its options. A
  Settings toggle, an on-demand rule, or a `startVPNTunnel()` from any
  process therefore produces a working tunnel with no app involvement — the
  July draft's premise ("a correct connect needs fresh credentials from the
  live SDK device") was wrong.
- The extension connects to the location in **its own** SDK local state,
  seeded by the app over the device RPC. The app and the extension do not
  share storage (each has its own Documents directory).
- The app derives "should the tunnel run" from SDK state
  (`VPNDesiredState.shouldRun = provideEnabled || connectEnabled || !routeLocal`),
  where `connectEnabled` follows the app's saved connect location; it pushes
  that location to the device at launch (`DeviceManager.initDevice`) and
  reconciles on foreground, on status changes, and from a 15-minute
  background refresh task. A tunnel stopped from outside the app used to be
  restarted by the next reconcile, and a tunnel started from outside after an
  in-app disconnect used to be idled (location nil) by the app's launch push.
- The Android app's Quick Settings tile (`QuickConnectTileService.kt`,
  July 2026) connects silently in-process, opens the app only when logged out
  or when VPN consent is missing, shows "Connected"/"Disconnected" under the
  app name, and switches between the filled and outlined connector icons.

### 1.4 Home Screen widgets

- WidgetKit budgets 40–70 reloads a day per widget instance, wants timeline
  entries at least ~5 minutes apart, and does not count reloads made while
  the app is in the foreground or reloads caused by an in-widget intent.
  Reloads requested from another process (the tunnel) are best-effort. A
  live meter is impossible; an "as of N min ago" dashboard is the honest
  form, and `Text(date, style: .relative)` ticks on screen without reloads.
  [W1][W2][W3]
- Interactive widgets (iOS 17): `Toggle(isOn:intent:)` runs its `AppIntent`
  in the widget process, flips optimistically, and the timeline is reloaded
  after `perform()` without touching the budget. [W4]
- Widgets are static snapshots: `Canvas`/`Path` drawing is fine, animations
  are not. The widget process has a ~30 MB limit. `containerBackground(for:
  .widget)` is required; iOS 18 accented mode and iOS 26 clear/tinted glass
  render content as a template, so series must differ by opacity, not hue.
  [W5][W6][W7]
- A Live Activity is the sanctioned surface for per-second session
  throughput (ExpressVPN "Network Insights" does this) but can only be
  started by the app or a push, and ends after 8 hours — a follow-up, not a
  substitute. [W8]
- One widget extension target can be multiplatform (`SUPPORTED_PLATFORMS =
  iphoneos iphonesimulator macosx`), as Apple's Backyard Birds sample is. [W9]

## 2. The control

`app/widgets/Control/QuickConnectControl.swift`,
`ToggleTunnelIntent.swift`, `TunnelControlSupport.swift`.

- **Template**: `ControlWidgetToggle("URnetwork", isOn:action:)` with the
  value label "Connected" / "Disconnected" and the solid UR connector mark
  (`ur.symbols.connector.fill`) as the symbol in both states: the system
  renders it white when off and in the tint when on, and the tint is the
  app's accent pink (`#ED8FFF`) — decided on the phone 2026-09-01, replacing
  the earlier filled/outlined pair with a green tint. (The outlined symbol,
  `ur.symbols.connector`, stays in the catalog; the Android tile still
  switches icons.) Symbol-only surfaces (small Control Center tile, Lock
  Screen slot, Action button) show just the mark; larger tiles add the title
  and the value. `controlWidgetActionHint` is the verb the press will
  perform ("Connect" / "Disconnect" → "Hold to Connect"). Gallery name
  "URnetwork", description "Connect or disconnect the URnetwork VPN."
- **Symbols**: the repo had no custom SF Symbols, and controls render nothing
  else, so `widgets/Assets.xcassets/gen_connector_symbols.py` rebuilds the
  connector mark analytically (a 128-unit square whose corners are five
  quarter-circle arcs of radius 8, alternating convex/concave) and emits two
  Template v6 symbol SVGs (SF Symbols 6 / Xcode 16 -- CI pins Xcode 16.4 and
  its actool rejects a newer template outright) with the interpolation
  sources Ultralight-S, Regular-S, Black-S and Regular-M. The outline
  variant is a true filled ring
  (lines inset by w, convex arcs shrunk to 8−w, concave arcs grown to 8+w),
  because symbols must be path-based, not stroked. `actool` validates both.
- **State** (`ControlValueProvider.currentValue`): the app's configuration is
  found by `providerBundleIdentifier == "network.ur.extension"` (not
  `.first`, which breaks with several VPN apps installed), with NetBird's
  one-shot retry; `connected`, `connecting` and `reasserting` count as on so
  the toggle does not snap back while the extension is still coming up.
- **Action** (`ToggleTunnelIntent: SetValueIntent`), in the widget process:
  1. record the intent in the shared store (section 3), then
  2. **on**: the same automatic-recovery policy the app installs before a
     connect (`isEnabled = true`, `NEOnDemandRuleConnect(.any)`,
     `isOnDemandEnabled = true`, `disconnectOnSleep = false`), save, load,
     `startVPNTunnel(options: ["network.ur.start-source": …])`;
     **off**: `isEnabled = false`, `isOnDemandEnabled = false`, rules nil,
     save, `stopVPNTunnel()` — the app's own stop path, so the profile is left
     as an in-app disconnect leaves it;
  3. wait up to 8 s (polling every 250 ms) for the status to leave
     `connecting`/`disconnecting`, so the value the system reads when
     `perform()` returns is already right.
  `isDiscoverable = false` (the app's ConnectIntent/DisconnectIntent remain
  the Shortcuts pair); `authenticationPolicy = .alwaysAllowed`, so the
  toggle works on a locked Lock Screen with no Face ID / passcode, following
  Apple's own VPN control (decided 2026-09-01; the app's Shortcuts intents
  keep `requiresAuthentication` because they launch the app).
- **Not signed in / never connected**: no configuration exists, so nothing
  can be started from here and the template builder cannot show an "open
  the app" button instead. The toggle renders **disabled** with the value
  "Not signed in", like the system VPN control with no VPN — and
  `perform()` is a no-op. The Home Screen widgets (which may branch) show an
  "Open" button (`OpenURnetworkIntent`, `openAppWhenRun`) in that state.
- **Re-rendering**: (a) the intent itself: the system re-reads the surface
  that ran it after `perform()`, and the intent asks WidgetKit to re-render
  the other surfaces too (`WidgetRefresh.reloadAll()` from the widget
  process — on the phone, the widgets otherwise showed the state before the
  toggle when the tunnel's own reload request was dropped), (b) the app on
  every `NEVPNStatusDidChange` (`VPNManager.vpnStatusDidChange` →
  `WidgetRefresh.reloadAll()`), (c) the tunnel extension when it finishes
  starting and when it stops (`WidgetSnapshotWriter.tunnelStarted/
  tunnelStopped`), (d) logout. A `controls` push (`ControlPushHandler`) is
  not needed for a single device and is left as a follow-up.
- **Where it appears**: Control Center, Lock Screen, Action button (iOS 18);
  Apple Watch (watchOS 26 mirrors iPhone controls whose intents do not
  foreground the app); macOS 26 Control Center and menu bar (the widget
  target builds for macOS; controls are gated `@available(iOS 18.0, macOS 26.0)`).

## 3. Integration with the app: the shared tunnel intent

The app's reconciler must neither undo a Control Center disconnect on the
next foreground nor idle a Control Center connect at launch. The mechanism
is one small shared record, `TunnelIntentStore` in the App Group
(`network/Shared/Widgets/TunnelIntentStore.swift`, compiled into all three
targets): `{connect: Bool, changedAt, source}`, last writer wins.

Writers:
- the app on every in-app connect/disconnect (`ConnectViewModel.connect*`,
  `disconnect` → `TunnelIntentAdoption.recordAppIntent`), which also marks
  the decision applied;
- the control and the widget toggle (`TunnelControlSupport.setTunnel`);
- the tunnel extension for stops made outside the app — Settings > VPN, the
  system VPN control, another VPN taking over
  (`PacketTunnelProvider.recordSharedIntentForStop`: reasons `userInitiated`,
  `configurationDisabled`, `providerDisabled`, `superceded`). The app's own
  stops and restarts-in-place arrive with the same reasons, so the app marks
  them first (`TunnelIntentStore.markAppInitiatedStop`, in
  `VPNManager.stopVpnTunnel` and `prepareTunnelManagerForConfiguration`) and
  the extension consumes the mark instead of recording.

Readers:
- `DeviceManager.initDevice` (before the saved location is pushed to the
  device) and `VPNManager.refreshDesiredStateFromDevice` (foreground,
  background refresh, every status change) call
  `TunnelIntentAdoption.adoptPending`: a newer non-app intent wins over the
  app's saved state — disconnect clears the connect location; connect fills
  it with the running tunnel's location when reachable, else the last
  selected location (`DefaultLocation`, what the connect screen shows while
  disconnected), else best available. Applied intents are remembered in
  app-private defaults so an old intent is never re-applied.
- The tunnel extension, when it starts with no saved location and the
  newest intent is a non-app connect (a quick connect after an in-app
  disconnect), connects to the same choice
  (`WidgetSnapshotWriter.connectLocationForSharedIntent`). Otherwise a
  location-less start stays a local/provide-only tunnel as before.

Net effect: a Control Center or Settings disconnect stays disconnected when
the app opens; a Control Center connect is adopted by the app (the existing
running-tunnel adoption path) with the app's saved location brought into
agreement; the app's own restarts are not mistaken for user decisions.

## 4. The dashboard widget

`app/widgets/Dashboard/`. Families medium and large. The medium is
exactly the large one's top section — location with the connected mark and
provider count, the quick connect button, the balance bar — centered
vertically, with no footer; the large adds the two charts and the footer.
Dark brand background (`#101010`, the app is dark-only), system font, 16 pt
system margins.

- **Header**: the solid connector mark, white when off and the app's
  connected green (`#87FB67`) when the tunnel is up, the connected location
  name ("Best available provider" when so; "Disconnected"; "Not signed in"),
  "N providers · providing" underneath, and on the right the quick connect
  as a `Toggle(isOn:intent:)` in `.button` style — the same
  `ToggleTunnelIntent`, constructed with the target state — a white mark on
  a gray capsule when off and on a pink capsule when on (pink is reserved
  for the quick connect button and the control). The
  button style is the only toggle style WidgetKit can archive: a `.switch`
  toggle renders as the red "unsupported view" marker on the phone. The
  mark inside the button is constant so the capsule's tint alone carries the
  optimistic flip; the header's mark and title show the last rendered state
  until the timeline reloads.
- **Balance bar**: the app's `UsageBar` segments (used `#0039DE`, pending
  `#FF6C58`, available faint) with the same 1.5 % minimum-width clamp, and
  "available / daily start" in the app's `formatBalanceBytes` units.
- **Charts** (large): "Client" (this device's remote-route bytes, green) and
  "Provider" (bytes relayed for others: the provider counters' local + block
  routes, light blue — the same pairing as the app's provider charts) as
  mirrored area charts (sent up, received down) with the app's
  Catmull-Rom smoothing, one bucket per minute over the last hour, and the
  peak rate top-right. "Not providing" replaces the peak when providing is
  off.
- **Footer**: "Updated 3 min ago", ticking live via `Text(date, style:
  .relative)`; "Connect once to see your traffic here" before any data.
- **Timeline** (`SnapshotTimelineProvider`): four entries five minutes apart
  re-rendering the same snapshot (so the axis and the relative time move),
  `.after(now + 20 min)` while the tunnel is up and `.after(now + 60 min)`
  while down; the gallery gets sample data. The on/off question is answered
  by `NEVPNStatus`, never by the snapshot, so a toggle from Control Center
  reads correctly before the tunnel has written anything.

## 5. The provider globe widget

`app/widgets/Globe/`. Families small (globe + count badge), medium (globe
left, list right, four rows), large (globe over a six-row list).

- The globe is a static port of the app's `ProviderGlobeView`: the same
  600×600 virtual space, orthographic projection and horizon clipping from
  `Shared/Utilities/GlobeGeometry.swift`, the same Natural Earth 110m land
  (`WorldTopology.swift` + `world-110m.json`, decoded once per widget
  process) and d3 graticule, black sphere, white land, country-colored dots
  (the SDK palette, baked into the snapshot). It turns to face the spherical
  centroid of the plottable providers, or the Atlantic when there are none;
  dots have a legible floor radius at widget sizes and a hairline separator.
- Rows: country-colored dot, "City, Country" (falling back through region
  and country, "Location unknown" otherwise), and the app's compact
  connected duration ("3h 24m", the same localized formats as
  `providerConnectedDurationLabel`), formatted for each timeline entry so it
  advances every five minutes. The place fills the row and is the only thing
  that truncates; the duration keeps its natural width, flush right. A
  relative-time `Text` was tried first and rejected on the phone: it
  reserves the width of its widest possible value, which staggered the right
  edge, and once given layout priority it left the place no room at all.
  Empty states mirror the app's ("No providers connected", "Provider details
  are unavailable until connected").
- **Updating as providers join and leave**: the tunnel extension rewrites
  the snapshot on every `connectedProviderLocationsChanged` and asks for a
  globe reload with a 2-minute floor (`WidgetReloadThrottle`), plus urgent
  reloads on location change and connect/disconnect. Typical windows hold
  1–6 providers rotating roughly every 10 minutes per slot, so this stays
  within the daily budget in steady state; during churn WidgetKit will
  defer some reloads rather than drop the data, which the next reload picks
  up. Row order is the app's: west to east about the providers' centroid,
  unplottable last. The ordering moved out of the SDK's provider-locations
  view controller (excluded from the extension build) into the untagged
  `sdk/provider_locations_order.go`, exported as
  `OrderConnectedProviderLocations`, so the extension orders the snapshot
  with the same code the provider details view uses.

## 5b. The contracts widget

`app/widgets/Contracts/ContractsWidget.swift`. Families small, medium,
large. The app's contract details view as a flowing grid: one compact card
per peer, and cards laid out left to right, wrapping, until the widget is
full. "Top N" is whatever fits.

- **A card is a peer, never a pair of contracts.** The stacks design rule
  holds: a peer's send and receive contracts are many-to-many, so each
  contract is its own circle, and the card shows the two stacks side by
  side — send (green, `arrow.right`) then receive (pink, `arrow.left`),
  newest first, up to six circles each. Circle area follows the contract's
  total against the stack's largest (floor 8 pt in a 18 pt slot; 6 in 14 for
  the small family), the inner disc is the used fraction, active contracts
  draw a brighter ring, stream contracts a second outer ring — the app's
  `ContractBlock` geometry at widget scale. A stack with nothing open shows
  a dashed placeholder ring so the two directions always read as a pair of
  columns. The header line is the first eight characters of the peer's
  client id and its total bit rate.
- **Flow** (`ContractFlowLayout: Layout`): cards keep their intrinsic width
  (more circles, wider card), are placed left to right, wrap at the widget's
  edge, and any card that would start below the bottom edge is parked out of
  bounds. Card order is the snapshot's relevance order, so the widget always
  shows the most relevant peers that fit. The widget header shows the summed
  rate while bytes move, otherwise the peer count.
- **Data**: the tunnel extension groups this device's open client contracts
  by peer (`ContractTracker` in `WidgetSnapshotWriter.swift`): egress
  contracts send to their destination, ingress contracts receive from their
  source; order within a stack is newest first by first sighting; a peer's
  byte counts accumulate across its contracts for as long as it has any
  open; last activity is the last positive bit rate. Peers sort active
  first, then most recently active, then most bytes, capped at twelve. This
  mirrors the SDK's `ContractDetailsViewController` aggregator, which the
  extension's SDK slice excludes (`!ios_extension`); moving that aggregator
  into an untagged file and exposing `Device.GetContractPeerRows` would let
  the extension use the SDK's own grouping — a follow-up.
- **Cadence**: contract change events arrive per contract about once a
  second while bytes move; they coalesce into a re-read of both lists at most
  every 2 s. Peers or contracts appearing and closing request a widget
  reload with a 3-minute floor; rates and byte counts ride the 60 s snapshot
  write and the 15-minute routine reload. Empty states: "No contracts",
  "Connect to see your contracts", "Open URnetwork to set up".

## 6. The snapshot pipeline

`network/Shared/Widgets/WidgetSnapshots.swift` (structs, atomic JSON files
under `<App Group>/Widgets/`), `WidgetRefresh.swift` (reload helpers and the
throttle), `extension/WidgetSnapshotWriter.swift` (the writer).

| datum | source of truth | writer | cadence |
| --- | --- | --- | --- |
| on/off | `NEVPNStatus` | read live by the widget process | on render |
| connected location | tunnel `DeviceLocal` | extension, `connectLocationChanged` | on change |
| providers (+ lat/lon, color) | tunnel window monitor | extension, `connectedProviderLocationsChanged` | on change |
| throughput buckets | tunnel cumulative `PacketStats` / provider `PacketStats` | extension, folded per listener tick into 60 × 1-minute buckets, file rewritten every 60 s | 60 s |
| balance | `SdkApi.subscriptionBalance` | app on every fetch (`SubscriptionBalanceViewModel`), extension every 30 min while up | on change |
| client contracts by peer | tunnel egress / ingress `ContractDetails` lists | extension, `ContractTracker` on contract change events (coalesced to 2 s) | on change |

The bucket ring is persisted in the snapshot and resumed by the next tunnel
session, so a restart does not flatten the chart. Reload policy in the
extension: connect/disconnect/location change → immediate reload of every
surface; provider change → globe, 2-minute floor; routine → 15-minute floor
when a write changed something. Logout clears both files and reloads
(`VPNManager.clearTunnelLocalStateAndRemoveAllVpnProfiles`).

The extension needed the SDK's country palette for the dots; `GetColorHex`
and its table lived in a `!ios_extension` file, so they moved to
`sdk/color_hex.go` (untagged) and both xcframeworks were rebuilt
(`make -C sdk/build build_apple`, 2026-09-01). The app's SDK surface is
unchanged.

## 7. Setup and signing

Done in the project: the `URnetworkWidgets` target (synchronized folder
`app/widgets/`, plus explicit references to the shared `network/` files it
compiles and the two resources it bundles), embedded by the app's
"Embed Foundation Extensions" phase, deployment targets iOS 17.0 / macOS
14.0, automatic signing with the existing team, entitlements
`widgets/widgets.entitlements` (`group.network.ur` + `networkextension:
packet-tunnel-provider`) and `widgets-macOS.entitlements` (team-prefixed
group). The tunnel extension gained the three shared `Widgets/` files.

Still to do, once, by the account holder:
1. Developer portal: register the App ID `network.ur.widgets` with the
   **Network Extensions** and **App Groups** (`group.network.ur`)
   capabilities, same team as the app. With automatic signing Xcode does
   this on the first device build if the account may; otherwise the build
   fails with "Provisioning profile doesn't support the Network Extensions
   capability" until it is done by hand.
2. Build to a device, add the control from Control Center's edit screen (or
   assign it to the Action button in Settings), add the widgets from the
   widget gallery.
3. Settings > Developer > **WidgetKit Developer Mode** while testing: it
   lifts the reload and control budgets.
4. Localization: the new strings are in the store
   (`localizations/keys/widget_*.yaml`, English only, plus `apple` added to
   `disconnected`, `open_urnetwork`, `site_app_providers`, `balance`,
   `app_name`). The widget bundles the app's generated catalog, so they take
   effect after `npm run gen:apple` and translation; until then they fall
   back to English. `npm run check` already reported 23 drifted generated
   files before this change, so regenerate deliberately, not blindly.

## 8. Verification

Verified here: `xcodebuild` of scheme URnetwork for the iOS simulator
(arm64) and for macOS, both green, no warnings in the new code; the built
`URnetworkWidgets.appex` carries both symbols in `Assets.car`,
`world-110m.json`, every `.lproj` of the shared catalog and the App Intents
metadata; `actool` accepts both symbol templates; the SDK builds with and
without the `ios_extension` tag and the extension slice now exports
`SdkGetColorHex`.

Verified on the phone (iPhone 16 Pro Max, iOS 26.6, development signing):
the widget extension signs with a team profile for `network.ur.widgets`
carrying the packet-tunnel-provider entitlement and the App Group (the app
and tunnel profiles carry the group too); the app installs and launches; the
control and both first widgets render and toggle. Three issues found and
fixed there: the dashboard showed the pre-toggle state after a Control
Center toggle (the intent now reloads every surface itself); a switch-style
toggle rendered as WidgetKit's unsupported-view marker (button style
restored, constant mark); the globe rows' durations were staggered
(relative-time text aligned trailing with layout priority).

Still to exercise:
- Control: toggle on with the app force-quit → tunnel up, toggle reads
  Connected within ~8 s; toggle off → down, and it **stays** down after
  opening the app; Lock Screen slot and Action button, including on a locked
  phone with no authentication prompt; "Not signed in" (disabled) after
  logout; Apple Watch mirror; macOS 26 Control Center.
- Contracts widget: cards appear while traffic flows, the flow fills each
  family, circles follow used/total, the 3-minute reload floor on peers
  coming and going.
- App interplay: quick connect after an in-app disconnect connects to the
  last selected location and the app adopts it on open; Settings > VPN off
  stays off after opening the app; changing location in-app (restart in
  place) is not recorded as a disconnect; the 15-minute background refresh
  does not restart a tunnel stopped from the control.
- Widgets: gallery previews; the in-widget toggle; balance after the app
  fetches; charts fill over an hour; provider globe follows joins/leaves
  (watch the reload cadence in the widget's timeline); "Open" state when
  logged out; iOS 18 tinted and iOS 26 clear rendering; macOS widgets.
- Reload reliability from the tunnel process with the app dead (the known
  soft spot; if reloads are dropped, the 20-minute timeline policy is the
  backstop, and a `controls`/`widgets` push is the escalation).

## 9. Follow-ups and open decisions

- **Siri / Shortcuts**: `ConnectIntent`/`DisconnectIntent` still run the SDK
  in the app; they could take the same silent `TunnelControlSupport` path
  when a configuration exists.
- **Live throughput**: a Live Activity started by the app on connect (and
  updated by push) is the way to show per-second traffic on the Lock Screen
  and in the Dynamic Island.
- **Configurable control**: a second, `AppIntentControlConfiguration`
  control with a location parameter ("Connect to Tokyo"), once the location
  list is reachable without the SDK (a snapshot of favorites).
- **Push refresh**: `ControlPushHandler` / `WidgetPushHandler` if the server
  learns about remote session changes (logout elsewhere, balance top-ups).
- **iOS 26 minimum**: replace `openAppWhenRun` with `supportedModes` and
  consider `.foreground(.dynamic)` + `continueInForeground` to let the
  control offer to open the app when not signed in.
- **Brand fonts** in the widgets (the catalog fonts would need bundling).
- **Parity**: done on Android on 2026-09-02 (`android/QUICKCONNECT.md`): the
  same snapshot contract feeds three Jetpack Glance widgets, plus launcher
  shortcuts and the polished Quick Settings tile.

## Sources

Controls: [C1] developer.apple.com/documentation/swiftui/controlwidget ·
[C2] …/widgetkit/controlwidgettoggle, …/controlwidgetbutton ·
[C3] …/widgetkit/creating-controls-to-perform-actions-across-the-system ·
[C4] …/widgetkit/updating-controls-locally-and-remotely, …/controlcenter ·
[C5] …/widgetkit/adding-interactivity-to-widgets-and-live-activities ·
[C6] …/appintents/appintent/openappwhenrun, …/supportedmodes ·
[C7] developer.apple.com/forums/thread/762146, /762618 ·
[C8] developer.apple.com/forums/thread/815524 ·
[C9] developer.apple.com/design/human-interface-guidelines/controls ·
[C10] WWDC24 10157 "Extend your app's controls across the system"; WWDC25 278,
334 (macOS 26, watchOS 26) · [C11] …/design/human-interface-guidelines/action-button ·
[C12] …/appintents/intentauthenticationpolicy, …/longrunningintent.

Network Extension: [N1] …/documentation/networkextension/netunnelprovidermanager ·
[N2] …/bundleresources/entitlements/com.apple.developer.networking.vpn.api ·
[N3] developer.apple.com/forums/thread/807080, /814047, /47984 ·
[N4] developer.apple.com/forums/thread/706111 ·
[N5] github.com/SagerNet/sing-box-for-apple/commit/efa60888;
github.com/mullvad/mullvadvpn-app (StopTunnelOperation.swift) ·
[N6] developer.apple.com/forums/thread/731233, /688076 ·
[N7] developer.apple.com/forums/thread/673684, /652946, /767431 ·
[N8] macrumors.com/2024/09/23/ios-18-1-control-center-changes ·
[N9] discussions.apple.com/thread/255764809; github.com/tailscale/tailscale/issues/14293.

Prior art: [P1] github.com/SagerNet/sing-box-for-apple (WidgetExtension/ServiceToggleControl.swift, WidgetTunnelControl.swift, Library/Network/ExtensionProvider.swift) ·
[P2] github.com/mozilla-mobile/mozilla-vpn-client (ios/widgetextension/ToggleWidgetControl.swift, ToggleIntent.swift; PR #11238) ·
[P3] github.com/netbirdio/ios-client (NetBirdWidgetExtension/Controls/*, PRs #120, #125, #138) ·
[P4] github.com/nymtech/nym-vpn-client (WidgetShared/Sources/NymVPNControlWidget.swift; PR #5021) ·
also Windscribe iOS-App AppIntents/Intents/Connect.swift; Tailscale changelog v1.78.0;
Proton VPN ios-mac-app (widget intents open the app); Mullvad issue #8850.

WidgetKit: [W1] …/widgetkit/keeping-a-widget-up-to-date · [W2] …/widgetkit/widgetcenter ·
[W3] …/widgetkit/displaying-dynamic-dates · [W4] …/swiftui/toggle/init(ison:intent:label:) ·
[W5] …/widgetkit/swiftui-views; developer.apple.com/forums/thread/795793 (30 MB) ·
[W6] …/widgetkit/displaying-the-right-widget-background ·
[W7] …/widgetkit/optimizing-your-widget-for-accented-rendering-mode-and-liquid-glass ·
[W8] …/activitykit/displaying-live-data-with-live-activities; expressvpn.com/blog/expressvpn-network-insights-secure-device-assistant ·
[W9] github.com/apple/sample-backyard-birds.
