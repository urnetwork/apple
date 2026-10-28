# DELAY: slow-internet indicator and live notifications

Status: designed and implemented 2026-10-27 in all four apps, uncommitted;
§14 records what was built. The §13 decisions were accepted the same day.
Spike S1 ran on a phone on 2026-10-28. ActivityKit refuses the tunnel
extension, so the iPhone shows a notification posted by the extension, and
the Live Activity is off until server pushes can drive it, the next step
(§5.5). Mockups are on the private
canvas "Slow internet tunnel indicator"
(https://claude.ai/artifact/Y8owXeHeX94bFZTTqMBuYW). The data comes from the
SDK's transport delay measurement, `connect/DELAY.md` (sdk API in its §10.4).

This plan covers Apple, plus Android (§7), Windows (§8) and Linux (§9), so
every app stays in step. The web app gets nothing (§10).

## 1. What the user sees

The SDK reports a quantized quality per direction, 0 (normal) to 1 (worst), in
steps of 0.25. The UI follows the worse direction: `q = max(UpQuality,
DownQuality)`.

| Surface | q = 0 | q > 0 |
|---|---|---|
| Connect screen, top right (iOS) | Nothing. | A "Poor signal" pill with the tunnel indicator and both delays (§5.2). It is a readout: nothing opens from it. |
| Connect screen, Mac | Nothing. | The same pill as a toolbar item, plus a "Slow internet" row in the menu bar extra. |
| Notification (iPhone) | None. | The tunnel extension posts "Slow internet" once the level has been above 0 for 30 s of the last 60 s, replaces it with "Internet back to normal" on recovery, and removes it 3 s later (§5.5). |
| Live Activity (iPhone) | None. | Off for now. With server pushes, the next step (§5.5): appears with a fade, deepens with q, shows the upload and download delay numbers when expanded, and fades out when q returns to 0. |
| Dashboard widget (iPhone, Android) | The provider count under the location. | The pill takes the provider count's place under the location, on the notice's dwell (§5.7). |
| Android | The normal VPN notification. | The VPN notification switches to the slow presentation (§7.2). No Live Update promotion (§7.3). |
| Windows | The normal tray icon. | The tray icon shows the tunnel, the tooltip shows the delays, one balloon per episode, and a connect-page pill (§8). |
| Linux | The normal tray icon. | The tray icon shows the tunnel, one `Gio::Notification` per episode, and a connect-page chip (§9). |
| Web (ur.io/app) | Nothing. | Nothing (§10). |

The details sheet is gone (§13, decision 8). The pill shows the upload and
download delays itself, or the throughput where a direction has no delay,
and "Notify me when my internet is slow", the in-app way to turn the notice
off, is in Settings only (§6). That toggle replaced "Show on Lock Screen and
Dynamic Island" when the Live Activity was turned off; that key is kept in
the localizations store, deprecated for apple, for the Live Activity's
return.

## 2. Tunnel indicator

### 2.1 Geometry

The indicator is a set of nested square outlines. Strokes thin as the squares
nest. Each square is the outer one scaled toward a vanishing point that sits
past the center, so the left and top gaps open wider than the right and bottom,
which gives the tunnel look. All values are relative to the box size `S`.

| Property | Value |
|---|---|
| Outer stroke | `0.094 · S` (2.25 pt at 24 pt) |
| Each nested stroke | × 0.60 |
| Each nested square | × 0.70, about the vanishing point `(0.55 S, 0.55 S)` |
| Resulting gaps | left and top ≈ 1.65 × right and bottom |
| Corners | Square, with mitered joins. Rounded corners soften the tunnel effect. |
| Opacity | 1 − 0.08 · depth index |
| Color | `urAmber` #F5C242 (the app's runtime-warning amber, Color.swift:21). Monochrome where the system requires it. |

The outer square is inset by half its stroke, so it fits the box exactly. Six
squares fit legibly at 16 pt. A seventh overlaps on the tight side at this stroke
weight, which was checked numerically.

| Quantized q | Squares |
|---|---|
| 0 | none: the indicator is hidden |
| 0.25 | 1, a single thick outline |
| 0.5 | 2 |
| 0.75 | 4 |
| 1 | 6, the full tunnel |

If the SDK's quality step is ever changed from 0.25, interpolate depth from this
table and round.

### 2.2 Sizes

| Placement | Size |
|---|---|
| Connect-screen pill | 18 pt, in a pill 30 pt tall. The recovered check is a 16 pt square. |
| Dynamic Island, compact leading | 20 pt, inset 3 pt from the leading edge: the island's curve cut the square corners at the edge (seen on a phone, 2026-10-28) |
| Dynamic Island, minimal | 17 pt: a square fits a circle only up to its diameter over √2, so 20 pt would touch the 28 pt limited-width circle |
| Dynamic Island, expanded leading | 36 pt |
| Lock Screen | 44 pt |
| Android status icon, notification header | 24 dp vector |
| Android large icon | 40 dp |

### 2.3 Implementation

`TunnelIndicator(depth: Double)` is a SwiftUI `Shape` stack: a `ForEach` over
six `Rectangle().stroke(style: StrokeStyle(lineWidth:, lineJoin: .miter))`
frames, with the geometry computed from §2.1. The Android vectors use
`strokeLineJoin="miter"` the same way. It ships in a file shared by the app and widget targets, like
`WidgetTheme.swift`, and takes no font or asset dependency. The canvas's Tunnel
component (`Tunnel.dc.html`) is the reference implementation of the geometry
and of the staggered fade timing in §3.

Accessibility: the pill is one element. Its label is "Poor signal" (or
"Fallback"), and its value is the up and down delays, or the rates where they
show. The icon itself is not read, because the label already says it.

## 3. Motion

The squares never move. Each has a fixed place in the tunnel, so a data update
only changes which squares are visible, and each one fades in or out in place.
The canvas's motion board computes its storyboard frames from the same timing
function as its live preview (`visibilityAt` in `Tunnel.dc.html`).

| Change | Motion |
|---|---|
| Deeper (0 → q, or to a higher level) | New squares fade in one at a time from the outside inward: 420 ms each, ease-out, started 110 ms apart, so several overlap mid-fade. A square starts 6% larger, scaled about the vanishing point, and settles to its size as it fades in, so it seems to recede into the tunnel. 0 → 1 builds the full tunnel in 970 ms. |
| Shallower (to a lower level, or to 0) | Squares fade out from the inside outward: 320 ms each, started 90 ms apart, easing back toward 1.06×. 1 → 0 clears in 770 ms. |
| Pill, island and card | Appear together with the first square. On a fade to 0 they wait until the last square starts fading ((n − 1) × 90 ms, 450 ms from the full tunnel), then fade. |
| Apple pill, back to normal | As the squares fade out, a green check (16 pt, square) and "Internet back to normal" fade in at once. That holds 3 s, then the pill fades. A new slow level during the hold ends it and the slow content returns. The reading going away (a reset, the device remote unlinked) or the can't-reach banner is not a recovery: the pill leaves as in the row above. |
| Numbers only | `.contentTransition(.numericText())`. The tunnel does not animate when only the numbers change. The Apple pill's width eases. |

- **Implementation.** Keep all six squares in the view tree and animate their
  opacity and scale. Don't insert and remove views: insertion transitions are
  less dependable in widgets and Live Activities.
  - In SwiftUI each square gets `.animation(.easeOut(duration: 0.42).delay(0.11
    * order), value: level)`, where `order` counts from the first square that
    changes.
  - Fading out uses the reverse order, 0.32 s and 0.09 s.
  - Compose uses `animateFloatAsState(target, tween(420, delayMillis = 110 *
    order))`.
- **Skipped levels.** A jump between non-adjacent levels, such as 0.25 → 1,
  runs the same staggered build for every square that changes.
- **Reduced Motion.** Keep the opacity fades and the stagger; drop the scale.
  The Apple pill also drops its slide and the digit roll: the digits
  cross-fade.
- **Live Activities.** Custom animations are capped at 2 s and skipped on
  Always-On displays with reduced luminance. The longest sequence here is
  970 ms. Entry and exit are system animations: the island expands on start
  and is removed on end. The fades above run on each update, and the 3 s
  recovered update (§5.5) carries the fade to 0 before the activity ends.
- **Android notification.** The small icon swaps between static per-level
  drawables and cannot animate. The in-app pill carries the motion.
- **Notification dwell.** The in-app pill follows the SDK level directly. The
  surfaces outside the app wait longer before they appear: the Live Activity,
  the Android notification (its content and status-bar icon), the Windows and
  Linux tray icons and tooltips, the Windows balloon and the Linux
  notification.
  - The tray follows the dwell whatever the notification setting, which gates
    only the balloon or notification. Through the minimum stay it holds its
    last level.
  - A tray that followed the level would flicker through slow stretches too
    short to notify about.
  - They appear only after the level has been non-zero for at least 30 s of
    the last 60 s.
  - Once shown, they stay at least 60 s and end with the 3 s recovered state.
  - The reason: worst-of-10 already stretches one bad second to about 10 s,
    and without a dwell that would post a notification. The calibration
    research found that every comparable system pairs a fast estimate with a
    slower, corroborated alert.
  - Each platform keeps this policy as a small pure, unit-tested function, with
    these defaults as constants.

## 4. Copy and number formats

| Key (source) | Where |
|---|---|
| "Slow internet" | Pill (not Apple's), sheet title, Mac menu bar row, Live Activity title, Android title |
| "Poor signal" | Apple pill |
| "Slow" | Dynamic Island compact trailing |
| "Fallback connection" | Pill (not Apple's) and Mac menu bar row, when `Fallback` is set (D10 in connect/DELAY.md) |
| "Fallback" | Apple pill, when `Fallback` is set |
| "Using a slower fallback connection" | Sheet, Live Activity and Android title, when `Fallback` is set |
| "URnetwork is using a slower fallback connection because its usual connection isn't available on this network." | Sheet body, when `Fallback` is set (not Apple: deprecated for apple) |
| "URnetwork is still connected" | Live Activity and Android subtitle |
| "Upload delay" / "Download delay" | Expanded island, Lock Screen, sheet, Apple pill's VoiceOver value |
| "Internet back to normal" / "Delays cleared" | The 3 s recovered state (the Apple pill shows only the first) |
| "Your network is delaying traffic. URnetwork is still connected." | Sheet body (not Apple: deprecated for apple) |
| "Show on Lock Screen and Dynamic Island" | Sheet toggle and Settings |

- Add one YAML file per key under `~/urnetwork/localizations/keys/`, with
  `platforms: [apple, android]` and all 28 locales, then run `npm run gen` and
  `npm run check`.
- The `source` must equal the Swift literal exactly.
- `CatalogLookupTests` does not scan `widgets/`, so Live Activity strings use
  `LocalizedStringResource("…", defaultValue: "…")`, as
  `QuickConnectControlMetadata.swift` does.
- Delay: under 1 s show whole milliseconds ("640 ms"); from 1 s show one decimal
  ("1.2 s"); from 10 s show whole seconds.
- Throughput: shown only when the SDK reports a limited rate (non-zero), as
  bits per second ("48 kb/s", "1.4 Mb/s"). Format the number with
  `Measurement<UnitInformationStorage>` and wrap it in a localized "%@/s" key.

## 5. Apple

### 5.1 Data

Add `TransportDelayStore` (`@MainActor`, `ObservableObject`) to `DeviceStores`
(`Shared/ViewModels/DeviceStores.swift:41-88`). Follow `NetworkPeersStore` and
the `TransportStatusListener` in `TransportSettingsStore.swift:289-297, 392-399,
462-516`.

- A private `NSObject` wrapper for the SDK's `TransportDelayChangeListener`.
- Hop to the main actor, guard on the generation counter, and publish only on
  change.
- **Register first, then read `getTransportDelay()` once.** Registration does
  not replay the current value. Read off the main actor, because getters can
  block for up to the rpc timeout.
- Close subscriptions off the main actor. Reset on suspend, and read again on
  resume.
- Gate on remote availability. While `getConnected()` is false, publish
  "unavailable" and hide the pill, rather than showing the last level (the
  device-remote stale-stat rule). `device.add(RemotePresenceListener)` is the
  push signal.
- Published state: `level` (0 to 4), `upDelayMillis`, `downDelayMillis`,
  `upBitsPerSecond`, `downBitsPerSecond`, `fallback`, `available`. `fallback`
  only switches the copy (§4). The tunnel and the motion are the same.

### 5.2 iOS connect screen

- In `ConnectView-iOS.swift`, add `.overlay(alignment: .topTrailing)` on the
  root `ZStack` (161): 16 pt from the trailing edge and 8 pt below the top safe
  area.
- **The pill (variant A+, §13 decision 8).** It takes the compact island's
  look: a black rectangle with square corners, like the tunnel's, in a 1 pt
  `urAmber` outline at 35%. Height 30 pt, padding 6 / 10, spacing 8.
  - The 18 pt tunnel.
  - "Poor signal" in amber, system font semibold 14 pt; "Fallback" when
    `Fallback` is set.
  - "↑ 800 ms", then "↓ 1.9 s": system font semibold 13 pt with tabular
    digits. The arrows are 10 pt bold at 55% white.
  - The worse direction, the larger delay, is amber, with its arrow at 75%
    amber.
- **Numbers.** Each direction shows its standing delay. With no delay but a
  limited rate it shows the rate, and with neither it hides. With both hidden
  the pill is the tunnel and the label.
- **Fitting.** The text follows Dynamic Type. With too little room, at large
  text sizes or in a long translation, the pill drops the better direction,
  then the numbers (`ViewThatFits`).
- **A readout, not a button.** Nothing opens from it. VoiceOver reads one
  element: the label, with the numbers as its value.
- **Refresh.** The SDK reports only level changes, so `TransportDelayStore`
  re-reads the numbers every 10 s while the pill shows them, off the main
  actor. The device stores reset while the app is inactive, which stops it.
- The app-wide `CantReachUrnetworkOverlay` banner (`MainView.swift:129`) also
  sits at the top. While that banner shows, the pill hides: the banner is the
  more severe state.
- Show and hide with `.transition(.opacity.combined(with: .offset(y: -6)))`,
  and nest the tunnel per §3. The recovered state is in §3.
- The rules are a pure value, `SlowInternetPillContent`, tested by
  `SlowInternetPillContentTests`.

### 5.3 Mac

- **Connect window:** a `ToolbarItem` next to the provider-list toggle
  (`ConnectView-macOS.swift:420-441`) showing the same pill, a readout here
  too: no popover.
- **Menu bar extra:** a "Slow internet" row after the "Providing" row
  (`NetworkApp.swift:819-826`). Device stores reset when the window hides, so
  feed this row from a listener that lives outside `DeviceStores`, as
  `ConnectViewModel`'s background tunnel listener does (401-461). Render cached
  values: the comment at `NetworkApp.swift:492-499` warns against synchronous
  SDK getters in the menu.
- **No Mac Live Activity.** ActivityKit is unavailable on macOS. An iPhone's Live
  Activity already appears in a paired Mac's menu bar on its own.

### 5.4 Live Activity UI

- **Shared definition.** `TransportDelayAttributes: ActivityAttributes` in a
  file shared by the app, the extension and the widgets, the way
  `WidgetRefresh.swift` is shared:
  ```swift
  struct TransportDelayAttributes: ActivityAttributes {
      struct ContentState: Codable, Hashable {
          var level: Int                 // 0...4; 0 only in the recovered end state
          var upDelayMillis: Int64
          var downDelayMillis: Int64
          var upBitsPerSecond: Int64     // 0: not limited, hide the line
          var downBitsPerSecond: Int64
          var fallback: Bool             // title: "Using a slower fallback connection"
      }
  }
  ```
- **Widget.** An `ActivityConfiguration(for: TransportDelayAttributes.self)`
  added to the `URnetworkWidgets` bundle (`widgets/URnetworkWidgets.swift:18-36`)
  inside `#if os(iOS)`, like `QuickConnectControl`. The widget target is iOS
  17+; the app's own ActivityKit calls need `#available(iOS 16.2, *)`.
- **Presentations** (canvas: Dynamic Island and Lock Screen):

  | Presentation | Content |
  |---|---|
  | Compact | Leading: the 20 pt tunnel. Trailing: "Slow" in amber, semibold. |
  | Minimal | The tunnel alone, fitting the 28 pt limited-width circle. |
  | Expanded | Leading: the 36 pt tunnel with "Slow internet" and the subtitle. Bottom: two inset rounded containers for upload and download, each with the delay (title3, tabular) and the rate when limited. The worse direction's number is amber. |
  | Lock Screen | The same content as expanded, 14 pt margins, 84–160 pt tall. The recovered state is one line. |

- **Look.** System font, medium weight or heavier: the widget target bundles no
  fonts, and the HIG asks for heavier weights. Set
  `.keylineTint(Color(urAmber))`. Add the amber to `WidgetTheme.swift`, since
  the widget target can't see the app's asset catalog.
- **Tap.** Deep-link to the connect screen, via `widgetURL`. The pill there
  shows the numbers.
- **Info.plist.** Add `NSSupportsLiveActivities = YES` to
  `URnetwork-Info.plist`. Add `NSSupportsLiveActivitiesFrequentUpdates` only if
  push updates (§5.6) need the budget.

### 5.5 Live Activity lifecycle: the constraint

The app process is suspended in the background (`UIBackgroundModes` is only
`fetch`), so the app hears no SDK events while the user is in other apps. The
network extension owns DeviceLocal and keeps running, but iOS limits who can
start an activity:

| Who | Start | Update and end |
|---|---|---|
| App in the foreground | Yes | Yes |
| App in the background or suspended | No: `ActivityAuthorizationError.visibility` | Only while it has run time, which it doesn't have here |
| Packet tunnel extension | Compiles: not marked unavailable for app extensions in the iOS 27.1 SDK. Runtime unverified, expected to fail the same visibility check. | Unverified |
| APNs push | Yes, via push-to-start (iOS 17.2+, `pushToStartTokenUpdates`) | Yes, via the activity's push token |

So the user's design, "appears on its own when slow", needs one of:

1. **Extension-driven.** This works only if the spike shows the packet tunnel
   can start activities.
2. **Push-to-start from the platform.** There is no APNs code anywhere today:
   the app has only `aps-environment` development entitlements, there is no
   token registration, and the server has no APNs client. The tunnel already
   sets `excludeAPNs = true`, so pushes don't ride the tunnel.

**Spike S1 (a phone test of the initial build).** The initial version builds
the extension-driven path first:

- `PacketTunnelProvider` calls `Activity.request`, `update` and `end` itself.
- It logs every `ActivityAuthorizationError` to the extension's diagnostics log.
- Behind a debug setting it can also try `ActivityStyle.transient` (iOS 18+).

The spike is then a run on a phone: degrade the network until quality goes
non-zero, with the app backgrounded and with it terminated, and read the log.
Until the servers stamp the header, the Developer screen's scripted episode
stands in for the slow network (§14).
Record the iOS version. Until the result is in, the app-process start path
(foreground) stays in place too, so the build is useful either way.

**Plan by outcome:**

| S1 shows | Plan |
|---|---|
| The extension can start, update and end | Fully local. The extension's delay listener drives the activity. This is the best outcome and needs no server work. |
| The extension can update and end, but not start | Phase 1: the app starts an activity whenever q > 0 while it is in the foreground, and the extension keeps it updated and ends it. Phase 2 adds push-to-start for the background case. |
| The extension can do none of these | Phase 1 is the in-app pill only (plus the Mac surfaces). The Live Activity waits for Phase 2. |

**S1 result (2026-10-28, scripted episode, read from the Developer screen's
log): the extension can do none of these, the table's third row.**

- **Start.** `Activity.request` in the extension fails with
  `ActivityAuthorizationError.unsupportedTarget`, reason "Target does not
  include NSSupportsLiveActivities plist key". It still failed with that key
  in the extension's own Info.plist, checked in the installed build, so
  ActivityKit accepts only the app as the requester. The key was removed
  again.
- **Update and end.** When the app started the activity in the foreground
  (`app start ok`), the extension could not see it: `Activity.activities`
  was empty there, so its updates at 40 s and 55 s changed nothing.
- **An earlier misread.** A first run seemed to show the extension starting
  the activity in the background. It was the app, still in the foreground at
  the 30 s mark.
- **Consequence.** An activity the app starts freezes once the app is
  suspended: nothing can update or end it until the app returns. It is marked
  stale after 60 s.

**Decision (2026-10-28): a notification now, push notifications next.**

- **The iPhone notice is a local notification posted by the tunnel
  extension.** It needs no app process, so it shows with the app suspended
  or closed. It follows the dwell policy:
  - posted at the policy's start, as "Slow internet" or "Using a slower
    fallback connection", with "URnetwork is still connected";
  - replaced by "Internet back to normal" at the recovered state;
  - removed at the end, and at once when the tunnel stops.

  A change of level or numbers posts nothing, since each post alerts. The
  notification plays no sound, and it needs notification permission, which
  the toggle asks for (§6).
- **The Live Activity is off.** `TransportDelayActivityAppDriver.showsActivity`
  is false, and the app no longer declares `NSSupportsLiveActivities`. An
  activity the app started would freeze once the app is suspended. The
  widget views, the attributes, the presenter and the policy stay for the
  next step.
- **No push notifications yet.** A push crosses the same slow link as the
  report that triggers it, so on a bad link it arrives late, and on a dead
  one not at all. Even so, a local notification is easy to miss, and only a
  push can start and keep up a Live Activity with the app suspended.

**Next step: push notifications for the Live Activity.**

- **Setup.**
  - An APNs auth key (`.p8`) from Certificates, Identifiers & Profiles ›
    Keys, with APNs enabled for Sandbox & Production, team scoped. Note its
    Key ID. The team is `6BGU69Q742`, which signs `network.ur`.
  - Push Notifications on the `network.ur` App ID. The app's entitlements
    already carry `aps-environment`.
  - An `apns` block in the server vault's `apple.yml`: `team_id`, `key_id`,
    `bundle_id: network.ur` and `private_key`.
  - Xcode builds get sandbox tokens; TestFlight and App Store builds get
    production tokens. The server sends each token to its own environment.
- **Design.**
  - The app registers its push-to-start token (iOS 17.2+,
    `pushToStartTokenUpdates`) and each activity's update token
    (`activityUpdates`, `pushTokenUpdates`) with the API, per client.
  - The extension reports the dwell policy's start, update and end to the
    API instead of posting the notification. Level changes are already rare
    (connect/DELAY.md D7, hysteresis).
  - The server holds a token-based APNs client and relays the reports.
    - Headers: `apns-push-type: liveactivity` and topic
      `network.ur.push-type.liveactivity`.
    - Payload: `attributes-type: TransportDelayAttributes`, and the content
      state in the `ContentState` coding keys.
    - `start` carries an alert, which lights the screen and shows the
      expanded activity, more visible than a notification.
    - `end` carries the recovered content and a `dismissal-date` 3 s out.
  - Then the app declares `NSSupportsLiveActivities` again, and
    `showsActivity` turns back on.
- **Known limits.**
  - Push-to-start needs iOS 17.2.
  - Pushes cross the slow link.
  - After a force-quit, iOS may not wake the app to hand over a push-started
    activity's update token. The server then cannot update or end that
    activity, and it goes stale until the app runs.
- **First step.** A phone check with no server deploy: the Developer screen
  shows the push-to-start token, and a command on a Mac sends start, update
  and end pushes to it with the key. It shows how visible the alert is, and
  how pushes behave under the Network Link Conditioner.

**Rules, whoever drives the activity:**

- **Start** when q goes from 0 to above 0, the toggle is on, and the tunnel is
  connected. No alert sound: the HIG reserves alerts for essential updates.
  Start silently.
- **Update** on a level change, and refresh the numbers at most every 30 s while
  slow. The extension's `WidgetSnapshotWriter` already runs a 30 s tick. Set
  `staleDate = now + 60 s`, so if updates stop (for example the extension is
  killed), the system marks the activity stale and the view shows the numbers
  muted.
- **Fade out:** update to the recovered state, then 3 s later call
  `end(dismissalPolicy: .immediate)`. Ending removes the activity from the island
  at once, so the recovered state must arrive as an update first.
- **End immediately** when the tunnel stops, the toggle goes off, or the user
  signs out. At the 8 h limit, start a new activity if the connection is still
  slow.

### 5.6 Extension wiring

- `WidgetSnapshotWriter` (`extension/WidgetSnapshotWriter.swift:143-230`) already
  subscribes to DeviceLocal listeners, writes App Group JSON, and posts Darwin
  notifications. Add the transport delay listener beside its existing ones, or in
  a sibling `TransportDelayActivityController` created at
  `PacketTunnelProvider.swift:1592`.
  - It writes `Widgets/transport-delay.json` (the level and the numbers) for the
    app and widgets.
  - It drives ActivityKit if S1 allows.
  - It enforces the rules in §5.5.
- **Memory.** The extension has a 32 MiB Go soft limit and is killed below 50 MiB
  (`TunnelMemoryBounds.swift:124-140`). ActivityKit calls are small; keep SwiftUI
  out of the extension.
- **SDK build tags.** The extension links `URnetworkExtensionSdk`, built with
  tags `sdk_mobile_bind,ios_extension` (sdk/build/Makefile:149-158). The
  `TransportDelay` API must not sit behind `!ios_extension`.

### 5.7 Dashboard widget (iPhone and Android)

Accepted 2026-10-28, variant A of the "Dashboard widget with the slow internet
pill" proposal (a local HTML mock rendered to PNG). It applies to the iOS
`DashboardWidget` (medium and large) and Android's Glance `DashboardWidget`
(short, tall and compact).

- **Placement.** While the notice shows, the pill takes the place of the
  header's subtitle, the provider count, under the location title. Nothing else
  in the widget moves. The provider count returns when the spell ends.
- **Why there.** The pill sits with the location it describes, where the eye
  lands first. In the footer (variant B), beside the faint "Updated" line, it
  read as metadata. The provider count is the least urgent fact while the
  connection is slow.
- **When.** A surface outside the app, so it follows the notice's dwell (§3),
  as the notification does: 30 s of slow time in the last 60 s, then at least
  60 s up. It shows only while the widget shows tunnel data (signed in and
  connected).
  - It follows the dwell whatever "Notify me when my internet is slow" says,
    as the Windows and Linux trays do. The setting gates only the
    notification. Turning the setting on mid-episode posts nothing until the
    next episode.
  - It has no recovered state: a widget cannot hold one for 3 s.
- **Look.** The A+ pill (§5.2), scaled to the widget's type:
  - 22 pt tall, with a static 14 pt tunnel at the level. A widget renders once
    per update, so no square fades.
  - "Poor signal", or "Fallback", in amber semibold 11 pt.
  - ↑/↓ values in semibold 11 pt with tabular digits, and 8 pt arrows at 55%
    white. The worse direction is amber.
  - Square corners, black fill, a 1 pt outline in 35% amber.
  - The header grows by about 10 pt, and the medium widget keeps room above
    the footer.
- **Values.** The in-app pill's rules (`SlowInternetPillContent`): each
  direction's delay, else its limited rate, else hidden. A tight row drops the
  better direction, then the numbers.
  - The numbers are as of the widget's last update; the footer's "Updated"
    already says how old.
  - Android's compact (2×1) size has no room for words, so it shows the tunnel
    and the worse value only.
- **Data and refresh.**
  - iOS: the timeline provider reads `Widgets/transport-delay.json`, the dwell
    policy's content, which the extension already publishes.
  - The extension reloads the dashboard timeline when the pill appears or
    leaves, or when the level or the fallback changes. It does not reload for
    a refresh of the numbers. The hysteresis keeps those changes rare, well
    inside WidgetKit's reload budget.
  - Android: MainService's dwell policy (`SlowInternetNoticePolicy`) publishes
    the same state for the Glance widget and updates it through
    `GlanceWidgetRefresh`, on the same changes.
- **Glance limits.** Glance has no canvas and no font features. The tunnel
  uses the notification's vector drawables (`ic_tunnel_1..4`) tinted amber,
  and the box is a shape drawable. The digits are not tabular.
- **Accessibility.** The header reads as one element: "Germany. Poor signal.
  Upload delay 800 milliseconds, download delay 1.9 seconds". The widget's tap
  target is unchanged: the whole widget opens the connect screen, and the
  toggle stays the toggle.
- **The overview widget carries the same pill.** The overview (DUO.md, "As
  built") reuses the dashboard's header, so the pill shows there by the same
  rules: the large and extra-large widgets on Apple, and the super-large and
  Samsung cover widgets on Android.
  - iOS: a dashboard reload also reloads the overview, through the overview's
    own throttle. A pill change is urgent, so the overview follows within 1 s.
  - Android: `GlanceWidgetRefresh` updates the overview whenever it updates
    the dashboard.

## 6. Settings

| Setting | Default | Where |
|---|---|---|
| Notify me when my internet is slow | On | Settings only: the details sheet that also had it is gone. App Group defaults, read by the extension. Turning it on asks for notification permission if the user has not been asked; without permission the extension cannot post. |

The DeviceLocal tuning knobs (connect/DELAY.md §10.4) are set where the
extension constructs DeviceLocal. They are not user settings.

## 7. Android

### 7.1 In-app indicator

- **Pill.** Add a TopEnd pill to `ConnectScreen` (`ui/connect/ConnectScreen.kt`)
  with `statusBarsPadding()` plus 12 dp, following
  `ReferralRoyalToast.kt:55-60`. Use `AnimatedVisibility` with a fade and the
  §3 nesting. Draw the tunnel in Compose with `Canvas` and the §2.1 geometry.
- **Referral toast.** It draws TopCenter over everything and nearly full width on
  phones (`MainNavHost.kt:1072-1086`), so hide the pill while the toast shows.
- **State.** Follow `ThroughputViewModel.kt:342-375`:
  `device.addTransportDelayChangeListener { viewModelScope.launch { … } }`.
  View models close their subscriptions on process stop, so read
  `transportDelay` again on reopen. Adding the listener to `ConnectDevice`
  (`ConnectSdk.kt`) means updating the fakes in `ConnectViewModelTest` and
  `DeviceConnectCommandTest`.
- **As built (2026-10-28): variant A+, as on Apple.**
  - **Rules.** `SlowInternetPillContent` (Kotlin) holds them, and
    `SlowInternetPillContentTest` mirrors Apple's tests.
  - **Drawing.** `SlowInternetPill` draws in the system font. When narrow, it
    drops the better direction, then the numbers. It holds "Internet back to
    normal" for 3 s.
  - **No recovery.** A disconnect or the referral toast is not a recovery. A
    screen stop forgets the pill, so a return starts fresh.
  - **No tap.** The details sheet is deleted.
  - **Refresh.** While the slow content shows on the visible screen,
    `ConnectViewModel` re-reads the numbers at once and then every 10 s. The
    notification keeps its 30 s.
  - **No digit roll.** Compose has no equivalent, so the numbers change in
    place and the width eases.

### 7.2 Notification (default)

The VPN foreground notification is always present while connected (channel
`urnetwork`, id 101, `MainService.kt:1271-1376`). While q > 0, change its
content instead of posting a new notification. That needs no new channel and no
new permission.

- **Wiring.** `MainService.attachToCurrentDevice` (346-433) subscribes to the
  transport delay listener. It updates through `updateForegroundNotification()`,
  coalesced with `CoalescedPost`, because nothing throttles that path today.
- **Content.** `vpnNotificationPresentation` (`VpnNotificationPolicy.kt`, a pure
  function, unit-tested) gains a delay input. While slow:
  - the small icon is `ic_tunnel_<level>`;
  - the title is "Slow internet", or "Using a slower fallback connection" when
    `Fallback` is set;
  - the BigText has two lines, upload and download, each with the delay and the
    rate;
  - the large icon is the amber tunnel;
  - the Disconnect action stays.
- **Return to 0.** Show "Internet back to normal" for 3 s, then the normal VPN
  text. `InsufficientBalanceMonitor` is the episode template, but drive this
  from the service, not from a Compose effect.
- **Icons.** `ic_tunnel_1` to `ic_tunnel_4` are monochrome 24 dp vectors with
  white silhouettes, like `ic_status`, generated from the §2.1 geometry.
- **Permission.** On Android 13+ users who never granted `POST_NOTIFICATIONS`
  won't see this in the shade (the app asks only from Settings). For them the
  in-app pill is the indicator.
- **Fades.** Notification posting and removal are system animations. The
  content swap and the recovered state are our transition.

### 7.3 Not planned: Live Update while slow

Android 16+ can promote the same notification. The status bar then shows a chip
with the small icon and "Slow" (canvas: Android).

- **What it takes.**
  - `NotificationCompat.Builder.setRequestPromotedOngoing(true)` and
    `setShortCriticalText("Slow")` (androidx.core 1.18.0 has both).
  - `<uses-permission android:name="android.permission.POST_PROMOTED_NOTIFICATIONS"/>`
    written as a literal string, because the compileSdk 36 jar lacks the
    constant.
  - A check of `NotificationManagerCompat.canPostPromotedNotifications()`.
  - The notification already meets the other requirements: ongoing, a title,
    BigTextStyle, no custom views, not a group summary, and a channel above
    `IMPORTANCE_MIN`.
- **Against.** Google's Live Update guidance asks for user-initiated activity,
  not ambient information, and lists alerts as inappropriate. The team already
  declined Live Updates for the VPN session for that reason
  (`android/QUICKCONNECT.md:60-66`).
- **Decision (2026-10-27).** Not shipping; §7.2 only. This section stays for
  reference. If promotion is ever revisited, put it behind a flag, promote only
  while slow, and confirm
  `FLAG_PROMOTED_ONGOING` with `adb shell dumpsys notification` on 16.0 and
  later devices, because promotion rules differ between SDK revisions.

### 7.4 Dashboard widget

The Glance dashboard widget shows the pill as on iPhone (§5.7), and the compact
size shows the tunnel and the worse value only.

## 8. Windows

The app process (URnetwork.exe) holds a DeviceRemote through SdkHost over the C
ABI. The urnetworkd service hosts DeviceLocal with default settings, so delay
measurement is on, but the service runs in session 0 and cannot notify the
user.

- **Data.** SdkHost subscribes `addTransportDelayChangeListener` in its
  per-session `subs_` (beside SdkHost.cpp:3690-3700) and reads the current value
  off the UI thread after registering.
  - It is gated on remote presence, through a new observer slot beside the
    single remote-change slot.
  - It is marshaled with `AppController::OnUi`, so it drives the tray and the
    balloon while the window is hidden, and the window while it is visible. The
    state is applied again when the window shows.
- **Tray.** Through the dwell (§3), the tray shows a tunnel icon per level:
  light and dark `.ico` files generated from the §2.1 geometry by
  `tools/make-icons`. The tooltip reads "URnetwork — Slow internet" with the
  delays, inside the 128-character limit, then "Internet back to normal" for
  3 s.
- **Notification.** One tray balloon per slow episode, after the dwell (§3),
  with "Notify me when my internet is slow" in Settings > General, on by
  default. The unpackaged build has no toast activation (only an AUMID), so
  there are no toasts.
- **Connect page.** The pill goes in the top-right pane header for the current
  breakpoint: the unused `PaneAMeta` slot in one-pane mode, the rightmost
  visible pane header otherwise.
  - XAML squares with the §3 fades, gated on `UISettings.AnimationsEnabled`, on
    an amber capsule.
  - It defers to `RegionPromptBar`, the can't-reach banner.
  - A click opens a flyout with the copy and the numbers.
- **Tests.** Pure headers (geometry, formats, dwell, the tray decision),
  compiled by the Go tests the way `TrayConnectionState.h` is.
- **As built (2026-10-28): variant A+, as on Apple.** The WinUI and XAML code
  is not compiled yet, since that needs Windows.
  - **Look.** A black, square-cornered box in a 35% amber outline holds the
    18 px tunnel, "Poor signal" or "Fallback", and the ↑/↓ delays or rates in
    tabular digits, the worse direction amber.
  - **No tap.** Nothing opens from it: the button and the flyout are gone.
  - **Rules.** They live in `SlowInternet.h`, ported from Apple's
    `SlowInternetPillContent`, with the specs in
    `tools/slow-internet-tests.cpp`.
  - **Fitting.** The pill fits the room the pane title leaves, dropping the
    better direction and then the numbers.
  - **Recovery.** A green check and "Internet back to normal" hold 3 s.
  - **Refresh.** It re-reads every 10 s while the slow content shows.
  - **Hidden window.** The pill is put away, so a recovery that happened off
    screen is not shown.
  - **Motion.** The numbers and the width change at once; WinUI has no digit
    roll or width ease.
  - **Font.** The text stays in the app's Montreal face, per the Windows type
    policy.
  - **Unchanged:** the tray.

## 9. Linux

The GUI holds a `urnet::DeviceRemote` through the C ABI. The root daemon hosts
DeviceLocal with defaults, and cannot notify.

- **Data.** A device-lifetime listener in SdkHost `subs_`, kept alive for the
  tray like the ConnectLocation listener, with an ungated handler through
  `PostToMain`. The value is unavailable while the remote is down
  (RemoteChange false, or not `tunnelBound`).
- **Tray.** Through the dwell (§3), the StatusNotifierItem `IconName` swaps to
  `urnetwork-tray-slow-1..4`, PNGs generated from §2.1, with a tooltip line
  ("Connected · Slow internet", then "Internet back to normal" for 3 s).
- **Notification.** A `Gio::Notification` with a fixed id, sent through
  `Gio::Application::get_default()`.
  - Posted after the dwell and replaced on change.
  - Shows the 3 s recovered state, then is withdrawn.
  - The toggle is "Notify me when my internet is slow".
  - The episode logic follows `balance_notice::Tracker`: pure and tested.
- **Connect page.** An amber chip (`.ur-chip-amber`) in the top-right pane
  header slot for the current mode, with a TunnelIndicator widget drawn the way
  `NavIcon` is and motion through UrMotion. On Linux the platform rule wins over
  §3: with animations off there is no motion at all, fades included.
- **Localization.** `T_(key, English)` with linux-tagged keys, and new sources
  listed in `POTFILES.in`.
- **As built (2026-10-28): variant A+ on the connect page, as on Apple.**
  - **Look.** `SlowInternetPill` is a black, square-cornered frame with a 1 px
    amber border at 35%. It holds the 18 px tunnel, "Poor signal" or
    "Fallback", then the ↑/↓ values in tabular digits, the larger delay amber.
  - **No tap.** It opens nothing.
  - **Rules.** `slow_internet::PillContent` (tested) decides the words, the
    drop to the worse direction and then to the label alone, and the 3 s
    green-check "Internet back to normal" hold.
  - **Fitting.** The pill asks only for the widest line that fits its
    header's room, so the 380 px statistics rail never widens.
  - **Refresh.** The numbers re-read every 10 s while slow with the window
    up, and every 30 s while it is hidden, which keeps the notification's
    numbers fresh.
  - **No recovery.** Nothing more severe takes the pill's spot on Linux, so
    only an unavailable reading makes it leave without a recovery.
  - **Motion.** The text fades when it swaps to or from the recovered state.
    The width does not ease, and the digits do not roll.

## 10. Web: not planned

Decided 2026-10-27: there is nothing to build for the web. ur.io/app controls a
hosted DeviceLocal on the proxy host, and its connect transports run from the
proxy host to a connect edge, between server machines. That connection is the
one that matters for the web, and it is on our side. So a "slow internet"
indicator has nothing of the user's to measure.

- Hosted devices set `EnableTransportDelay = false`
  (server/proxy/proxy_device.go), which also spares thousands of them the
  header overhead.
- No ur.io UI, JS bridge or site copy keys are built.

## 11. Implementation map

| Repo | Files |
|---|---|
| apple | `Shared/ViewModels/TransportDelayStore.swift` (new), `DeviceStores.swift`; `Main/Connect/ConnectView-iOS.swift`, `ConnectView-macOS.swift`; `NetworkApp.swift` (menu bar row); a shared `TunnelIndicator.swift` and `TransportDelayAttributes.swift` (app, extension, widgets); `widgets/URnetworkWidgets.swift` plus a new `TransportDelayLiveActivity.swift`; `Shared/Widgets/WidgetTheme.swift` (amber); `extension/WidgetSnapshotWriter.swift` or a new `TransportDelayActivityController.swift`; `URnetwork-Info.plist` (`NSSupportsLiveActivities`); Settings forms (toggle). |
| android | `ui/connect/ConnectScreen.kt`, `ConnectViewModel.kt`, `ConnectSdk.kt`; a new `ui/components/TunnelIndicator.kt`; `MainService.kt`, `VpnNotificationPolicy.kt`; `res/drawable/ic_tunnel_1..4.xml`; tests. |
| localizations | `keys/*.yaml` for the §4 copy. |
| sdk | Rebuild the AAR and xcframeworks once the `TransportDelay` API lands. Hosted devices set `EnableTransportDelay = false` (server/proxy/proxy_device.go). |
| windows | `src/App` SdkHost listener and observer slot, AppController tray and balloon, TrayIcon assets (`tools/make-icons`), connect page pill and flyout, Settings toggle; pure headers with Go tests (§8). |
| linux | SdkHost device-lifetime listener, Tray icon names and assets, `Gio::Notification` episode tracker, connect page chip and TunnelIndicator widget, Settings toggle (§9). |

## 12. Tests

- **Geometry and depth table.** A unit test for `TunnelIndicator`'s frames
  (strokes and offsets at 24 pt), checked against the canvas reference.
- **`TransportDelayStore`.** The generation guard drops late events. Remote
  disconnected means unavailable and hidden. The value is read again on resume.
- **Live Activity previews.** `#Preview(as: .dynamicIsland(.compact), using:
  attributes) { states }` for each level, plus expanded, minimal, Lock Screen and
  recovered.
- **Lifecycle policy as a pure function.** `(previous level, new level, toggle,
  tunnel, now) → start, update, end or nothing`, with tests for the 3 s
  recovered end and the 30 s number refresh.
- **Android.** `VpnNotificationPolicyTest` gets slow-state, recovered and
  coalescing cases. Update the connect fakes.

## 13. Decisions

Accepted 2026-10-27:

1. **iOS Live Activity:** run spike S1 first, then follow the plan for its
   outcome (§5.5). If the extension cannot start activities, the choice between
   shipping the Phase 1 limits and building push-to-start is made with the
   spike's results.
2. **Android:** the §7.2 content swap on the VPN notification. No Live Update
   promotion (§7.3).
3. **Live Activity default:** on and silent, with the toggle one tap away in
   the details sheet and in Settings. Apple warns that unexpected activities
   can feel unwanted.

Accepted 2026-10-28, after spike S1 (§5.5):

6. **iPhone notice:** a local notification posted by the tunnel extension,
   gated by "Notify me when my internet is slow". The Live Activity is off.
7. **Next step:** push notifications, so the Live Activity can start and stay
   up to date with the app suspended (§5.5).

Accepted 2026-10-28:

8. **The connect-screen pill:** variant A+ (square corners, "Poor signal",
   both delays, no tap), from the "Slow internet pill, Live Activity style"
   proposal (§5.2). The details sheet and the Mac popover go.
9. **The pill on every app:** Apple, Android (§7.1), Windows (§8) and Linux
   (§9), each with its details surface removed. Not the web app: the platform
   does not measure the web user's connection (§10).
10. **The pill on the dashboard widget:** variant A on iPhone and Android
    (§5.7). The pill takes the provider count's place under the location, on
    the notice's dwell.

Still open:

4. **Thresholds: set 2026-10-27; the field trial is still to run.** The
   defaults now follow the research report (connect/DELAY.md §10.1–§10.3: per-second
   aggregation, the second-worst of 10 seconds, 1.5 Mbit/s / 750 kbit/s and
   500 ms zero points). The shadow trial in connect/DELAY.md §13 sets the final
   values before notifications ship.
5. **Web:** nothing to build (§10). The connection that matters for a hosted
   device is on the server machines, not the user's link.

## 14. As built (2026-10-27, uncommitted)

All four apps are implemented. Nothing has run on a device; the builds and
tests below ran on a Mac.

**Shared.**

- **Copy.** 13 keys in `localizations/keys/slow_internet*.yaml`, in 28
  locales, tagged apple, android, windows and linux (no site tag) and generated
  for all four apps.
- **Formats.**
  - Locale-independent: a "." decimal, like each app's existing rate formatter.
  - A value that rounds across a unit boundary moves up a unit: 9,950 ms reads
    "10 s", and 999,500 bit/s reads "1.0 Mb/s".
  - 0 hides the value.
- **Refresh.** The SDK fires only on a level or `Fallback` change, so each app
  re-reads the numbers while they are on screen.
  - Apple: every 10 s while the pill shows them, and at each policy deadline
    in the extension.
  - Android, Windows and Linux: every 30 s while slow. Windows also re-reads
    when the flyout opens or the window shows.
- **Dwell.** The surfaces outside the app follow the dwell, including the
  trays; the in-app pill follows the level (§3).

**Apple.**

- **Widget target.** It links no SDK. It gets three plain-Swift files:
  `TransportDelayAttributes`, `TransportDelayFormat` and `TunnelIndicator`.
  Only the app (`TransportDelayStore`) and the extension
  (`TransportDelayActivityController`) map `SdkTransportDelay`.
- **Content state.** It carries `previousLevel`. Widget views keep no state
  between updates, so this field is how each square fades in its order.
- **Snapshot file.** The extension writes `Widgets/transport-delay.json`, with
  its reading and what its policy wants shown. In the foreground the app
  follows that file:
  - it starts the activity when the extension could not;
  - it attaches to an activity that is already up;
  - it ends the activity on toggle off, policy hidden, tunnel stopped or
    sign-out;
  - it leaves a stale snapshot alone, so the extension does not mistake it for
    the user's dismissal.
- **Lifecycle additions.**
  - A user dismissal keeps the activity away until the level has been normal
    for 60 s.
  - At the 8 h limit it restarts if still slow.
  - A new session ends activities left over from a killed one.
  - Each step re-reads the toggle, because a suspended extension misses Darwin
    notifications.
- **After S1 (2026-10-28).** The extension posts the notification
  (`TransportDelayNotification` in `TransportDelayActivityController.swift`)
  and no longer calls ActivityKit. The app's Live Activity path is off
  (`showsActivity`), and `NSSupportsLiveActivities` is out of
  `URnetwork-Info.plist`. The toggle reads "Notify me when my internet is
  slow" (§6). The Developer screen keeps the scripted episode and an
  on-screen log, and the transient-style switch is gone. The bullets below
  describe the Live Activity build that S1 tested.
- **The episode drives the pill too (2026-10-28).** While its slow part plays,
  `TransportDelayStore` shows the episode's reading in place of the device's
  (`TransportDelayStore.reading(device:simulationStartedAt:now:)`), stepping
  at each change of the script. The pill therefore runs through levels 2, 4
  and 3, then recovers at 75 s, on a phone with no slow network. It still
  needs the device remote linked.
- **Spike S1 instrumentation.**
  - Extension log lines tagged `live-activity`: the iOS version, every start
    attempt and outcome, and every ActivityKit error. App-side lines are
    prefixed `app`.
  - A Developer-screen switch for the transient style.
  - A Developer-screen "Slow internet episode" (`TransportDelaySimulation`).
    It plays a scripted slow spell in the extension: level 2 from 0 s, 4 at
    40 s, 3 at 55 s, normal at 75 s. The activity starts at 30 s, updates at
    40 s and 55 s, shows the recovered state at 90 s and ends at 93 s. Until
    the servers stamp the header (connect/DELAY.md §11, rollout), a real slow
    network reads quality 0, so this is how S1 runs today.
- **Mac.** The toolbar shows the iOS pill; the details popover is gone. The
  amber "worse" number is the larger delay.
- **Pill exit.** On a fade to 0 the pill waits until its last square starts
  fading, computed from the depth it leaves (`containerExitDelay(fromDepth:)`),
  as on the other platforms, so a single square never leaves an empty pill.
- **Pill A+ (2026-10-28, §13 decision 8).**
  - `SlowInternetPillContent` holds the rules: the label, each direction's
    text, the worse direction, the two narrower forms and the recovered
    state. `SlowInternetPill` draws it, and `SlowInternetPillHost` runs the
    motion and the 3 s hold. The details sheet, its cards and the Mac
    popover are deleted.
  - `TransportDelayStore.setPillVisible` replaced `setDetailsVisible`. The
    host sets it while the slow content shows, so the 10 s re-read runs only
    then, and only while the store has a device: the app active.
  - The `slow-internet` deep link (the Live Activity's) now lands on the
    connect screen, like `connect`.
  - Copy: `slow_internet_poor_signal` ("Poor signal") and
    `slow_internet_fallback_short` ("Fallback"), apple only, in 28 locales.
    The two sheet bodies are deprecated for apple. "Fallback connection"
    stays live: the Mac menu bar row, left as it was, still shows it.
  - VoiceOver reads a rate after "Upload delay" or "Download delay", as the
    Live Activity's cards label it, so no new keys were needed.
  - The text sizes follow Dynamic Type (`@ScaledMetric`), so at the largest
    sizes the pill grows past 30 pt. The tunnel and the check stay fixed.
  - Verified: the iOS and macOS builds pass, and so do the simulator suites,
    `SlowInternetPillContentTests` (9) with the transport delay, tunnel,
    connect and catalog suites, 100 tests in all. Not yet seen on a device.
- **Info.plist.** `URnetwork-Info.plist` sets `NSSupportsLiveActivities`.

**Android.**

- **Slow content.**
  - Collapsed text: "URnetwork is still connected".
  - Expanded text: the two direction lines. A line hides when its delay is 0,
    and its rate is appended only when non-zero.
  - Icons: small icon `ic_tunnel_<level>`, the amber large icon and an amber
    `setColor`.
  - The same channel and id, with Disconnect kept and no promotion.
- **Recovered.** "Internet back to normal" / "Delays cleared", with the normal
  `ic_status` icon and a faint tunnel large icon. The normal content returns
  after 3 s.
- **Gating.**
  - The slow content applies only while the base status is CONNECTED, so
    connecting, failed and tunnel-down states are never hidden behind "still
    connected".
  - The dwell resets when connect is no longer requested.
  - The pill also needs a requested connection, and yields to the referral
    toast.
  - The details sheet shows the recovered copy if the reading clears while it
    is open.
- **SDK mirror.** `TransportDelayUi`, a plain copy of the SDK type, keeps the
  policy and formats testable without the native library.

**Windows.**

- **Tray decision.** A pure header: `SlowInternet.h` `DecideTray` and
  `TrayEpisode`. The balloon shows once per episode. The episode's balloon
  moment is spent whether or not the setting posts it, so turning the setting
  on mid-episode does not post a late balloon.
- **Tray ink.** On a light taskbar the tunnel is #AE8009, the same hue darkened
  to 3:1 contrast; #F5C242 would be 1.6:1. Dark taskbars use #F5C242.
- **Icons.** Eight icons, `tray_{light,dark}_slow_{1..4}.ico`, drawn by
  `make-icons -only-tunnel`, with RC ids 130–133 and 140–143. The full
  generator has drifted from the committed brand icons, which stay untouched.
- **Setting.** "Notify me when my internet is slow" in Settings > General,
  `app_prefs.json` key `notify_slow_internet`.
- **Pill placement.** `PaneASlowHost` sits in pane A's right slot, because
  `PaneAMeta` is a TextBlock and cannot host the button. Panes B and C have
  their own hosts.
- **Reads.** The value is read on a coalesced worker through the C ABI, off
  the UI thread and off SdkHost's lock. It publishes "unavailable" while the
  remote is down.

**Linux.**

- **Chip.** It moves to the rightmost pane header for the current fold. On the
  way to 0 it fades once the last square starts fading: (n−1) × 90 ms, 450 ms
  for the full tunnel.
- **Notification.**
  - Id `slow-internet`, replaced only when its content changes.
  - Withdrawn at once when unavailable or switched off, with no recovered
    state.
  - A new episode needs a fresh 30 s.
- **Setting.** Connections > "Notify me when my internet is slow", pref key
  `slow_internet_notify`.
- **Tray art.** `assets/urnetwork-tray-slow-1..4.png`, 32 × 32, white on
  transparent.
- **Refresh.** It reads through `ReadOnMain`, with the feed's revision taken
  inside the read, so an answer the main loop kept loses to any push since. A
  failed read changes nothing.

**Verified.**

- **Apple.**
  - Every target built for iOS and macOS against an SDK framework bound from
    the current sdk and connect trees. It used a scratch copy, so
    `sdk/build/apple` is untouched.
  - The new simulator suites pass: TunnelIndicator 12, TransportDelayFormat 7,
    TransportDelayActivityPolicy 17, TransportDelaySharedState 6 and
    TransportDelayStore 9. The existing connect, catalog and device suites pass
    too.
  - One failure predates this work: `TunnelDiagnosticLogTests` expects two
    `writePathLine(diagnostic)` calls, and the committed extension has three.
  - The macOS unit tests compiled but did not run.
- **Android.** The play flavor's unit tests pass: 1771 tests, 0 failures. They
  ran against a TransportDelay-capable AAR bound from current source, via
  `BRINGYOUR_HOME`. The checked-in `sdk/build/android` AAR (Oct 20) lacks this
  API and some older symbols, so a normal build fails until it is rebuilt.
- **Windows.** The new C++ specs (902 checks), make-icons and the windows Go
  suite pass. The WinUI code was not compiled, since that needs Windows.
- **Linux.** 1660 unit tests pass, and the GUI sources pass `-fsyntax-only`
  against the regenerated C++ header. The GUI was not linked, because the
  vendored SDK is stale.

**Before shipping.**

- Rebuild the SDK artifacts:
  - `make build_apple` (done 2026-10-27) and `make build_android` in
    `sdk/build`;
  - the cgo zip for Windows (`tools/fetch-deps.ps1`) and Linux
    (`scripts/fetch-deps.sh`).
- Run spike S1 on a phone (§5.5).
- Check on devices:
  - the pill, its motion and its recovered hold. Checked on an iPhone on
    2026-10-28 with the Developer episode: it looks good. Android, Windows and
    Linux are still to check;
  - notification rendering and dwell timing;
  - Reduce Motion;
  - Live Activity previews and layouts, once push brings it back;
  - the Windows pill and tray;
  - GNOME and KDE notifications, and the SNI icon swap.

## 15. References

- Apple HIG, Live Activities (updated 2026-10-13): best practices; iPhone sizes
  (compact 52.33 × 36.67 pt, minimal 36.67–45 × 36.67 pt, expanded and Lock
  Screen 371 × 84–160 pt, limited width 28 pt); 2 s animation cap; 14 pt Lock
  Screen margins; immediate removal from the island on end.
- ActivityKit swiftinterface, iOS 27.1 SDK: `request` (16.2+, `style:` 18.0+,
  `alertConfiguration:start:` 26.0+); `pushToStartToken` (17.2+);
  `ActivityAuthorizationError.visibility`.
- Android Live Updates (developer.android.com, notifications/live-update):
  requirements and use criteria.
- androidx.core 1.18.0 `NotificationCompat` Live Update APIs.
- Prior decisions: `apple/QUICKCONNECT.md:151-154`;
  `android/QUICKCONNECT.md:60-66`.
