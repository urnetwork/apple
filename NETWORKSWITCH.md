# Network switch review

Symptom: switching between cellular and Wi-Fi does not reconnect instantly.
This review follows the path from the OS network signal to the re-dialed
transports and lists the places where that logic is broken or miswired.

Reviewed 2026-10-20 at apple `f81acae4`, sdk `14849d0c`, connect `58786550`
(all clean `main`). This is from reading the code only. Nothing was reproduced
on a device, and the timings are what the code allows, not measurements.

Findings marked **S** are in the shared Go code (connect/sdk), so they affect
every platform. Findings marked **A** are in the Apple extension and app. The
Android, Windows and Linux reviews (each found, then re-verified on a second
read, then given a reviewed fix plan) are at the end, followed by the status of
every fix.

## How a switch is supposed to flow on Apple

1. `NWPathMonitor` in the packet tunnel (`PacketTunnelProvider.swift:1277`)
   calls `handlePathUpdate`. It builds a signature from the interfaces the path
   uses plus its gateways (`:1346-1355`) and waits 350 ms for the path to
   settle (`:1376`).
2. A changed signature, or a usable path after an unusable one, calls
   `requestTransportRecovery`. That hops to the main queue, where
   `scheduleTransportRecovery` waits another 350 ms (`:2113-2160`).
3. The work item gives a `.path` reason to `DestinationRecovery` (`:2142`). It
   reads the shared intent and may rebuild the destination
   (`reconcileIntendedDestinationIfNeeded`, `:2022`) on the serial `.utility`
   recovery queue.
4. If that succeeds, `RecoveryEffects` keeps path effects at least 2 s apart
   (`:1095`) and calls `completeDestinationRecovery`, which calls
   `device.networkChanged()` (`:2058`).
5. In the SDK, `DeviceLocal.NetworkChanged` (`sdk/device_local.go:4515`) calls
   `RemoteUserNatMultiClient.NotifyNetworkChanged`
   (`connect/ip_remote_multi_client.go:8183`). That rebases the liveness clocks
   and calls `connect.NetworkChanged()` (`connect/util.go:194`), which:
   - kicks every `PlatformTransport` (`connect/transport.go:1152`)
   - drops the strategy's pooled API sockets
   - drops the DoH sockets
   - resets the p2p ICE state
   - resets the extender feed
6. Each kicked transport closes its connection (`runConnectionWatch`,
   `connect/transport_client_limit.go:310`) and re-dials. The first four use
   the reconnect fast path (0–250 ms jitter, `connect/net_http.go:990`). The
   rest share a staircase that adds 100 ms–1 s per dial.

In the best case the kick lands about 0.7–1 s after the OS path update, and a
jittered re-dial follows. The findings below are where that chain breaks, or
stretches into many seconds.

## Summary

| # | Severity | Layer | Finding |
|---|---|---|---|
| S1 | High | connect | A kick that lands while a dial is in flight is lost |
| S2 | High | connect | A kicked connection younger than 5 s waits out the rest of the reconnect timer |
| A1 | Medium | apple | The kick waits on destination/auth recovery and can be dropped by it (regression from `e63e877a`) |
| S3 | Medium | connect | The re-dial burst after a kick overflows the 4-slot fast path |
| S4 | Medium | connect | Dial failures on the dying path trip the process-wide "backend degraded" gate |
| A2 | Medium | apple | `sleep()` cancels a path recovery whose signature was already committed |
| A3 | Medium | apple | The first usable path after starting offline never kicks |
| A4 | Medium | apple | A failed recovery leaves `reasserting` on, and the app's health audit then restarts the tunnel |
| S5 | Low | connect | A kick during the pre-dial wait does not reset the dial backoff |
| S6 | Low | connect | A hard switch goes through the quality-hint coalescer and can be swallowed (fixed) |
| S7 | Low | connect | A network change does not wake the window's resize loop |
| S8 | Medium | connect | A network change does not end the window's platform-error backoff (found during the recent-exit work) |
| A5 | Low | apple | The `defaultPath` KVO and radio-type callbacks re-read a stale path and restart the debounce |
| A6 | Low | apple | A gateway-only change on the same interface counts as a hard change, and a new network behind the same gateway does not (fixed) |

## Shared layer (connect / sdk)

### S1: A kick that lands while a dial is in flight is lost (High)

Where:
- `connect/transport.go`: H1 runner `:2279-2343` and `:2379`, H3 runner
  `:3217-3302` and `:3344`
- `connect/util.go:43-55` (`Monitor`)

`Monitor.NotifyChannel()` returns the channel for the *next* `NotifyAll`. A
notify that already happened does not show up on a channel fetched afterwards.
Both runners fetch the kick channel only after `connect()` returns: in the
failure `select` (`:2336`, `:3296`) and for the connection watch (`:2379`,
`:3344`). `Kick` (`:1148-1154`) says "an in-flight dial is unaffected", but
nothing remembers that the kick happened. The failure arm's own comment ("the
failed dial was likely on the dead path — retry now over the new one")
describes exactly the case the code cannot detect.

Scenario, Wi-Fi → cellular:
- The Wi-Fi socket errors first. The runner starts a fast-path re-dial while
  the default route is still the dying Wi-Fi.
- The extension's kick arrives about a second later, during that dial, and is
  missed.
- The dial runs to its deadline:
  - up to 15 s for H1, through the strategy's `RequestTimeout`
  - 30 s for the H3 handshake idle timeout
  - 120 s for the DNS carriers
- The failure `select` then waits `dialRetryAfter`, because its freshly fetched
  channel never fires:
  - after a first failure, the ordinary 5 s timer
  - after repeated failures, a backoff that doubles up to 30–60 s

If the Wi-Fi was already failing (often why people switch), the backoff is
already large.

Scenario, cellular → Wi-Fi: a dial that was in flight on cellular succeeds. The
connection watch arms a fresh channel, and the tunnel stays on cellular until
something else breaks it.

Fix:
- Fetch the kick channel once at the top of each loop iteration, before the
  pre-dial wait.
- Use that same channel for the pre-dial wait, for an attempt context that is
  canceled when the kick fires, for the failure `select`, and for the
  connection watch.
- Call `noteKick()` wherever a kick is seen.

### S2: A kicked connection younger than 5 s waits out the rest of the reconnect timer (High)

Where:
- `connect/transport.go:2982-3001` (H1), `:3903-3921` (H3)
- `connect/util.go:667-678` (`Reconnect.After`)

`reconnect` is armed just before the connection runs. When a kick closes the
connection, the loop reaches the post-connection `select` with two arms:
- a kick channel fetched after the kick that killed the connection, so it does
  not fire;
- `reconnect.After()`, which waits a random part of
  `ReconnectTimeout − age` (5 s minus the connection's age).

This breaks `Kick`'s contract to "skip any pending reconnect backoff so the run
loop re-dials immediately". It only works when the connection is older than
5 s.

Scenario: the extension keeps path recoveries 2 s apart, and a cellular attach
often reports a second path change (gateways, IPv6) soon after the first. The
second kick closes connections that were re-established 1–2 s earlier. Each
re-dial then waits 0–4 s (about 1.5–2 s on average) before it starts. Any
connection made just before a switch behaves the same way.

Fix: have `runConnectionWatch` report that it closed the connection for a
network change. In that case, skip the remaining wait and go straight to
`nextDialTime(true)`.

### S3: The re-dial burst after a kick overflows the 4-slot fast path (Medium)

Where:
- `connect/net_http.go:959` (`reconnectFastPathLimit = 4`), `:990-1030`,
  `:916-952`
- every window exit uses the device's one strategy:
  `NewApiMultiClientGenerator(… self.clientStrategy …)` at
  `sdk/device_local.go:4771`, and `connect/ip_remote_multi_client_api.go:1324`
- mode election `connect/transport.go:1914-1924`, `standDown` `:2005-2008`

The cap assumes "a handful of platform transports" per strategy. In fact every
window exit owns a transport on the same strategy:
- 4 quality exits under the iOS mobile policy (`sdk/mobile_memory_policy.go:237`)
- 6 on desktop (`connect/ip_remote_multi_client.go:200`)
- plus the speed window

A kick re-dials all of them at once. Every dial after the fourth goes to the
shared staircase.

Auto mode makes this worse:
- When H1 drops, the election goes to `None`.
- Every transport's parked H3, H3-DNS and DNS-pump runners then wake and take
  staircase slots too, whenever their optional H3 lease is held.
- That pushes later H1 re-dials back by seconds, up to the 10 s lead cap.

Flows pinned to an exit whose re-dial is near the back of the staircase stall
for that long.

Fix:
- Size the fast path for the window: per transport, or at least the window's
  hard max plus the provider's transports.
- Keep the lower modes parked for a short grace period after a kick, so they
  do not race H1 on a fresh path.

### S4: Dial failures on the dying path trip the "backend degraded" gate (Medium)

Where:
- `connect/transport_family.go:585-593` (`noteDialFailure` →
  `noteBackendFailure`)
- `connect/transport.go:418`, `:444-454`, `:481-496`
- effects in `connect/transfer.go:10083-10085`, `:10139-10145`,
  `:10218-10220`
- window growth and race width in `connect/ip_remote_multi_client.go`
  (`backendDegraded`, `degradedWindowTarget`, `multiRaceClientCount`)

Three failed dials in a row, anywhere in the process, mark the backend as
degraded. It stays that way until a dial succeeds, or until 2 minutes pass
with no failures. A switch causes exactly that: several exits re-dial on a
path with no route, and they all fail at once.

While the backend is marked degraded:
- send sequences skip `CreateContract`;
- they start their contract retry at the 5 s maximum. That value is computed
  once per wait, so it stays at 5 s even after the gate clears;
- successor contracts are not requested;
- the window does not grow;
- new flows race 2 exits instead of the full set.

`NetworkChanged` does not reset the failure count.

Fix:
- Reset the backend failure count in `connect.NetworkChanged()`.
- Do not count dials that a kick canceled, or dials that failed with a local
  error (no route, network down, address unavailable).
- Re-check `isBackendDegraded()` on each contract retry instead of keeping the
  maximum interval for the whole wait.

### S5: A kick during the pre-dial wait does not reset the backoff (Low)

Where:
- `connect/transport.go:2287-2289`, `:3225-3227`
- `connect/transport_family.go:567-580`, `:664-670`

The kick arms in the pre-dial waits skip the wait but do not call `noteKick()`.
The failure arms do (`:2341`, `:3299`).

Scenario: the first dial on the new path fails once, which is common while the
link is still attaching. The next wait is then the old network's grown backoff:
- up to 60 s for a transport that is not pinned to a family;
- up to 5 min for the provider's pinned IPv4/IPv6 transports.

Fix: call `noteKick()` in those arms, and treat the dial as a reconnect.

### S6: A hard switch goes through the quality-hint coalescer (Low)

Where:
- `connect/util.go:194-199`
- `connect/transfer_network_quality.go:101-118`
- `connect/transfer_window_quality.go:44-52`, `:70-77`

`NetworkChanged()` calls `NetworkQualityChanged()` to trigger the remeasure.
That path drops any notification that comes within 5 s of the previous one,
and moves the 5 s window forward each time. So a hard switch shortly after a
quality hint gets no remeasure. Typical quality hints are Wi-Fi bars dropping
as you walk away, or a radio-type change. Cellular then keeps the Wi-Fi pacing
estimate until normal feedback corrects it. This hurts throughput right after
the switch, not connectivity.

Fix: let a hard change start a new measurement generation regardless of the
quiet interval.

Fixed: `NetworkChanged()` advances a process-wide `networkPathGeneration`
before it asks for the remeasure. Each of the three coalescing owners records
the newest path generation it accepted: the client's local dispatch, each send
sequence, and the shared pacing service. A notification from a newer
generation starts a new measurement inside the quiet interval. Hints on the
same path coalesce as before. On a shared service, only the first sibling to
bring the new generation resets it, and the others coalesce into that reset.
The provider still coalesces our notification on its side, because the wire
message carries no hard-change flag.

### S7: A network change does not wake the window resize loop (Low)

Where: `connect/ip_remote_multi_client.go:12688-12703`, `:8183-8197`.

The resize loop waits for its monitor or for `WindowResizeTimeout` (15 s).
`NotifyNetworkChanged` does not notify it. A window that lost exits during the
outage, or one that started offline (A3), can wait up to 15 s before it
expands on the new path.

Fix: notify the resize monitor from `NotifyNetworkChanged`.

### S8: A network change does not end the window's platform-error backoff (Medium)

Where: `connect/ip_remote_multi_client.go` (the enumerator loop in
`randomEnumerateClientArgs` and its client mint), `ip_remote_multi_client_demand.go`
(`fixedClientArgs`), `ip_remote_multi_client_outcome.go` (`windowRetryDelay`).

Found while building the recent-exit memory. Each failed platform call the
window makes (listing destinations, minting a client) waits out
`windowRetryDelay` before it tries again. The delay doubles from
`WindowEnumerateErrorTimeout` (1 s) toward `WindowErrorBackoffMax` (15 s) on
each consecutive failure, and only a successful call resets it. During an
outage every call fails, so by the time the path comes back the window can be
asleep for up to 15 s. Nothing ended that wait on a network change: S7 wakes
the resize loop, but the resize loop has no destinations to add until the
enumerator asks again. The first round on the new network could start up to
15 s late, which also delays the recent-exit lookups.

Fix: a network change starts the window's error backoff over and ends every
platform-error wait.
- `RemoteUserNatMultiClient.NotifyNetworkChanged` calls each window's
  `notifyNetworkChanged`. That resets the error streak, notifies a new
  per-window `networkChangeMonitor`, and wakes the resize loop (S7).
- The three retry waits go through `waitWindowRetry`. Each fetches the
  network-change channel before the call it waits out, so a change that lands
  during the failing call still ends the wait.
- A rate limit is the platform's answer, not the path's: its streak is kept
  and its wait is never ended early.

## Apple extension and app

### A1: The kick waits on destination/auth recovery and can be dropped by it (Medium, regression)

Where:
- `PacketTunnelProvider.swift:2139-2143`, `:1104-1132`, `:2022-2045`,
  `:2050-2059`
- `TunnelAuthRecoveryContinuation.swift:126-198`

Before `e63e877a` ("Restore Apple tunnels autonomously after restart",
2026-09-07), the path work item called `device.networkChanged()` directly. Now
it submits a `.path` reason to `DestinationRecovery`, and
`device.networkChanged()` runs only after `reconcileIntendedDestinationIfNeeded`
succeeds. If that check does not succeed, the kick never happens:

- **An error.** `TunnelIntentStore.loadChecked` throws for a missing App Group
  or an undecodable record, or `restoreDestination` fails. The result is
  `failed`, which sets `reasserting` and drops `.path` (`:185-186`).
- **A superseded destination.** If the destination ticket changed while the
  request was queued (for example, a location change), `pending` is cleared
  without any log (`:177-178`).
- **Auth not settled.** If a JWT refresh is in progress, the request is held
  until the next auth publication (`:179-183`).

There are two more delays:
- The kick waits behind any destination restore already running on the serial
  `.utility` recovery queue (`:1082`).
- A `.path` reason merged into a `.wake` attempt that fails is dropped with it.

The kick does not depend on the intent or on auth. The SDK documents it as
cheap and safe to call on every path update.

Fix:
- Call `device.networkChanged()` directly from the path work item, keeping the
  2 s spacing there.
- Hand only the destination reconciliation to `DestinationRecovery`.

### A2: `sleep()` cancels a path recovery whose signature was already committed (Medium)

Where: `PacketTunnelProvider.swift:1405`, `:2342-2355`, `:2162-2169`,
`:2171-2178`, `:1494-1498`.

The sequence:
1. The path queue commits `stablePathSignature` when it requests recovery,
   before the recovery runs.
2. `sleep()` cancels the pending main-queue work item.
3. On `wake()`, `networkStateRefresh` compares the current path with the
   committed signature, sees no change, and does nothing.
4. The `.wake` reason only probes exits.

Scenario: the phone leaves Wi-Fi as it locks, so the path change and the sleep
land within about 0.7 s of each other. After wake, the window stays on the dead
Wi-Fi sockets until pings or TCP keepalive notice, which takes about 10 s or
more.

Fix: keep a "last kicked signature" that changes only when the kick runs, and
compare against it on wake. Alternatively, do not cancel a pending path
recovery in `sleep()`.

### A3: The first usable path after starting offline never kicks (Medium)

Where: `PacketTunnelProvider.swift:1326-1333`, `:1382-1384`.

An unusable path is remembered only when a stable signature already exists, and
the first usable path is treated as the baseline only.

Scenario: the tunnel starts with no network (on-demand at boot, or a restart in
airplane mode or a dead zone).
- The transports' dials fail and back off toward 60 s (5 min for the
  provider's pinned transports).
- When the network arrives, nothing kicks them.
- Because of S7, the window can then wait up to 15 s more before it expands.

Fix: treat an unusable first observation as an unavailable edge. That is, set
`physicalPathWasUnavailable` even when `stablePathSignature` is nil, so the
first usable path triggers a kick.

### A4: A failed recovery leaves `reasserting` on, and the app then restarts the tunnel (Medium)

Where:
- `PacketTunnelProvider.swift:1121-1127` and `:2153-2156` (set), `:1067` (the
  only clear)
- `TunnelLocalStateIdentity.swift:526-538`
- `VPNManager.swift:225-250`, `:924-940`, `:1018-1055`, `:1243-1313`

`reasserting = true` is set on a failed destination or path recovery, and on a
failed settings retry. It is cleared only when a *new* readiness level is
applied. `TunnelReadinessOwner.begin` returns nil when the level has not
changed, so a tunnel that stays "connected" keeps reporting `.reasserting`.

In the foreground, the app treats anything except `.connected` as unhealthy:
1. An app-visible path change (audit after 1 s) or the status change itself
   (audit after 5 s) starts a forced reconcile.
2. The reconcile adopts the running tunnel and gives it 5 s
   (`VPNTransitionalHealthAuditDelay`).
3. It then stops and restarts the tunnel (`reset: true`).

The result is an outage of several seconds on a tunnel that was working.

The same 6–10 s restart can hit a tunnel that is genuinely re-establishing
after a long outage. The extension's own recovery takes longer than that: a
60 s transport-down expiry and 15 s resize passes. So the app can restart a
tunnel that was about to recover on its own.

Fix:
- Clear `reasserting` once the current readiness is confirmed again. For
  example, set `reasserting = next == .establishing` in `reconcileReadiness`
  even when `begin` returns nil.
- Do not set `reasserting` for a failed path recovery.
- Separately, consider whether the app should restart a tunnel the extension
  is still recovering.

### A5: The `defaultPath` KVO and radio-type callbacks re-read a stale path and restart the debounce (Low)

Where: `PacketTunnelProvider.swift:1447-1454`, `:1482-1490`, `:1421-1444`,
`:1324-1325`.

The `defaultPath` observer exists because `NEProvider.defaultPath` "can lead
the physical monitor". But it re-checks `pathMonitor.currentPath`, which in
exactly that case is still the old path, so it cannot bring the kick forward.

Each of these calls also increments `pathSignatureGeneration`, which restarts
the 350 ms settle window:
- this observer;
- each `CTServiceRadioAccessTechnologyDidChange`;
- each change in Wi-Fi bars.

A burst of radio-type changes during a cellular attach keeps pushing back the
hard-change check.

Fix:
- When `defaultPath` changes but the monitor's signature has not, check again
  after a short delay.
- Do not let quality-only callers restart the hard-change debounce.

### A6: A gateway-only change on the same interface counts as a hard change (Low, needs a log check)

Where: `PacketTunnelProvider.swift:1346-1355`.

The signature is the interfaces in use plus `path.gateways`. Two problems can
follow:
- If a cellular attach reports its gateways (for example an IPv6 router) a few
  seconds after the interface, the second signature change kicks connections
  that were just re-established on the right interface. With S2, each extra
  kick costs seconds.
- In the other direction, Wi-Fi A → Wi-Fi B on the same interface, with the
  same gateway address (192.168.1.1 is common) and no unusable path in
  between, produces no kick.

The `[path]` diagnostic lines (`TunnelDiagnosticLog`) would show which of these
happens in practice.

Fix: if the interfaces are unchanged and only the gateways changed, within a
few seconds of a hard change, extend the settle window instead of kicking
again.

Fixed: the signature is now structured (`TunnelPhysicalPathSignature`). It
holds the interfaces in use, their gateways, and the interfaces' own addresses:
IPv4 exactly, IPv6 by its /64, with link-local and loopback left out. A settle
on the same interfaces is classified as follows (`TunnelPhysicalPathTransition`):
- An address in use is gone: change (cause `address`). This catches Wi-Fi A→B
  on the same interface behind the same gateway address.
- An address family that was not there before: change (cause `family`). A v6
  transport that failed its dial and is backing off can then dial at once.
- Only the gateways changed, within `TunnelRecoveryTiming.lateGatewayGrace`
  (5 s) of the path appearing or changing: refined, no kick (cause
  `late-gateway`). After the grace, a gateway change still kicks.
- Only an address added in a family already in use: refined, no kick.

An unavailable edge in between still recovers whatever comes back. The log
line names the cause: `stable physical path transition=… cause=…` or
`stable physical path refined cause=…`. One case is still not detected: a
different network that hands out the same address behind the same gateway
address. That would need the SSID.

## Timing once these are fixed

- **OS path update → kick:** 350 ms settle, plus a 350 ms main-queue debounce,
  plus queue hops. The second debounce is redundant for path changes because
  the path queue already groups them, so about 0.4 s is achievable.
- **Kick → re-dial start:** 0–250 ms jitter per transport, as long as the fast
  path covers the whole window.
- **Re-dial → traffic:** one TCP+TLS+WebSocket upgrade (H1) or QUIC handshake,
  plus a DNS lookup for the platform host if its answer is not cached.
- **After an outage → first window round:** about one platform round trip.
  The network change ends the window's error backoff (S8) and wakes its
  resize loop (S7). The remembered exits are asked for in that same round.

## How to check on a device

The extension log shows each stage:
- `stable physical path transition=`: the settle window fired
- the `path-recovery` `started` and `completed` breadcrumbs
  (`SdkRecordTunnelRecoveryStage`)
- the SDK's `network_change rebased=true kick=true` event
- `[t]kick: closing connection for re-dial`
- `[t]auth error`: a failed re-dial
- `[multi]routing … transport restored`

How to read them:
- The gap between `path-recovery started` and `network_change` measures A1.
- A `kick: closing` line with no successful re-dial for seconds afterwards
  points to S1, S2 or S3.
- The developer menu's `SimulateNetworkChange` runs the SDK half without the
  extension plumbing. That separates the A findings from the S findings.

## Fix plan: shared layer

Landing order: S1, S2 and S5 (one change to the two runner loops), then S4,
then S3, then S7. S6 stays open as a low item.

- **S7.** `NotifyNetworkChanged` wakes every window's resize monitor after the
  broadcast, so a window short of exits expands on the new path now instead of
  at its next 15 s pass.

- **Kick generation (S1, S2, S5).** `PlatformTransport.Kick` increments a
  `kickGeneration` counter before it notifies. Each runner iteration records
  the counter at the start. `kickedSince(generation)` returns an
  already-closed channel when a kick happened since then, so a kick is never
  lost because a channel was fetched too late. Using it:
  - **Pre-dial wait:** a kick skips the wait and calls `noteKick()` (S5).
  - **Dial:** the dial runs on its own context, which `cancelOnKick` cancels
    (S1).
    - A dial that ends after a kick counts as neither a dial failure nor a
      backend failure; the runner retries at once.
    - A dial that completes just as the kick lands is closed and replaced.
    - For H1, the dial context lives for the whole iteration, because the
      strategy observes delivery through it.
  - **Connection watch:** armed from the iteration's generation.
  - **After the connection:** a connection a kick closed re-dials at once,
    without `reconnect.After()` (S2).
- **S3.**
  - `nextDialTime(hadConnection, afterKick)`: a re-dial a kick asked for uses
    `ClientStrategy.NextKickReconnectTime()`, which gives the same 0–250 ms
    jitter without taking a fast-path slot.
  - `holdAfterKick`: an Auto mode that was standing down waits its
    `ModeInitialDelay` after a kick, so H1 gets the new path first. A lower
    mode that was carrying traffic re-dials at once.
- **S4.**
  - `connect.NetworkChanged()` calls `noteBackendNetworkChanged()` before the
    listeners, which starts a fresh failure count.
  - Dials cancelled by a kick are not counted (part of the S1 change).
  - While the backend is marked degraded, the contract wait polls the gate at
    the base retry interval instead of the backed-off one. Requests are still
    skipped, and later requests keep the backed-off spacing.
- **Egress DNS cache (Windows #7, Linux LOW 3).** `connect.NetworkChanged()`
  also calls `forgetEgressDnsServers()`, which clears the Windows/Linux
  egress-resolver server list. That list is keyed by interface index, which a
  same-adapter switch keeps.
- **SDK export (Windows #4).** `sdk.NetworkChanged()` is now exported at
  package level (`urnet::networkChanged()` / `urnet_network_changed()`), for a
  process that holds no `DeviceLocal`.
- **S8.** See the finding: the window's platform-error backoff restarts on a
  network change, and the waits on it end (`waitWindowRetry`,
  `notifyNetworkChanged`).
- **S6.** See the finding: `networkPathGeneration` lets a hard change through
  every quality coalescer once.
- **Kick re-dial cap (decision 2).** `ClientStrategySettings.KickReconnectLimit`
  (12) gives kick re-dials their own slots on the strategy.
- **Recent-exit memory (decision 4).** See "Recent-exit memory" below.
- **Tests:**
  - `connect/transport_kick_test.go`:
    - a kick during an in-flight dial;
    - a kick against a young connection, twice;
    - the degraded count reset;
    - the uncapped kick fast path;
    - the post-kick hold;
    - a source anchor for the runners.
  - Cache-clear tests in the Linux and Windows egress resolver test files (they
    run only on those OSes).
  - `connect/ip_remote_multi_client_network_change_test.go` (S8): the backoff
    reset with the rate-limit streak kept; a wait ended by a change during the
    wait and by one during the failing call; a rate-limit wait not ended; a
    source guard that every retry wait goes through `waitWindowRetry` with a
    network-change channel. Five deliberate mutations are each caught.
  - `connect/ip_remote_multi_client_recent_exits_test.go`: 22 tests for the
    recent-exit memory.

## Recent-exit memory

This is the second half of decision 4. It is implemented in connect, so every
platform gets it. When a window loses an exit to an outage on our side, it
remembers that exit for `MultiClientSettings.RecentExitMemoryTimeout` (5
minutes; zero or negative turns the memory off). The rounds that re-form the
window ask for the remembered exits by id first.

- **What is remembered.** Every window except Fixed IP, whose sticky redial is
  unchanged:
  - an exit lost to transport loss (`errTransportDownTimeout`), always;
  - an exit lost to a "Blackhole" verdict, only when the verdict was collected
    in the dark. Two things must both hold: the uplink gate was holding (an
    open stale epoch inside its 60 s cap, or the scheduler-pause hold), and
    the verdict's evidence started no earlier than the tunnel's last packet
    from any provider.
- **Never remembered:**
  - verdicts on a fresh uplink or past the gate's cap;
  - send-stall convictions, stats-unhealthy removals and contract-reliability
    verdicts;
  - user actions: drop exit, shuffle, remove provider;
  - declines, collapses, family swaps, drains and window close.
- **Bounds.** One entry per destination. At most the window's hard max (else
  the largest of its min, max or fixed size), keeping the newest.
- **Use.** Each round takes every valid entry once and asks the platform for
  each one by id (`NextDestinationsForClientId`), all in parallel.
  - If the last generator call succeeded, the lookups run alongside
    discovery. If it failed, they run after discovery answers, so a failing
    platform is asked once per retry.
  - A returned exit leads the push order with its original stats, then goes
    through the normal mint, ping and pool admission.
  - An exit the platform does not return is dropped. A lookup error puts the
    entry back.
  - Discovery leaves out the remembered destinations and fills the rest.
- **Cleared** on a profile change, a shuffle, window close (a destination
  change builds a new multi-client), and remove-provider (that provider only).
  It is kept across a network change.
- **Logs:** `event=recent_exit action=remember|try|admit|drop|expire`, with a
  reason and client ids only.
- **To measure on devices:**
  - the hit rate: `try` against `admit` and `drop reason=evaluation`;
  - how often `reason=uplink_hold` appears;
  - whether the burst of by-id lookups after an outage (up to the window's
    hard max) is acceptable for the platform.
  - In a speed window the platform does not filter out an offline named
    provider, so a remembered offline exit costs one evaluation. On a
    low-memory device that slot can wait up to `PingTimeout`.

## Fix plan: Apple

Landing order: A1, A3 and A4, then A2 and A5. A6 waits for on-device logs.

- **A1.** Path changes call a direct `kickTransports(reason:)`:
  - It skips the second 350 ms debounce and keeps the 2 s spacing; a kick that
    arrives inside the spacing is postponed, never dropped.
  - `device.networkChanged()` runs on its own serial queue, not the
    destination-recovery queue.
  - The destination reconciliation (`DestinationRecovery`, `.path`) runs
    after the kick.
  - `completeDestinationRecovery` no longer kicks.
- **A2.** If a kick is pending when `sleep()` runs, it becomes an owed kick
  that `wake()` performs first. Only `stopTunnel` cancels a kick without owing
  it.
- **A3.** An unusable first observation counts as an unavailable edge, so the
  first usable path after starting offline kicks.
- **A4.** `reconcileReadiness` re-asserts `reasserting = (readiness ==
  .establishing)` when the level is already applied (new
  `TunnelReadinessOwner.isApplied`), so a failed recovery no longer leaves the
  tunnel in `.reasserting`. The app-side restart now also waits while the
  tunnel recovers on its own (decision 4).
- **A5.**
  - Radio-type and Wi-Fi-bar callbacks update quality only; they no longer
    restart the hard-change debounce.
  - An update with the same signature as the pending evaluation does not
    restart it either.
  - A `defaultPath` change checks the monitor's path again after 0.5 s.
- **A6.** See the finding: a structured signature with the interfaces' own
  addresses, and a late-gateway grace.
- **Tests:** the path state machine moves into a value type in
  `TunnelLocalStateIdentity.swift`, covered in `TunnelRecoveryTests`. The
  Swift build has to be rebuilt against a fresh `make build_apple`.

## Android

Reviewed at android `f95c6c5da`. The review was confirmed by reading the code.
Platform behavior that could not be shown in code is marked.

**How the switch is wired.**
- **Process.** Everything runs in one process. The callbacks are registered for
  each `DeviceLocal` in `MainApplication.initDevice`
  (`MainApplication.kt:2547-2549`) and are not tied to a screen.
- **Membership signal.** A callback on physical internet networks
  (INTERNET+NOT_RESTRICTED+TRUSTED+NOT_VPN) feeds `AvailableNetworkTracker`.
  It kicks:
  - when a network is added after the first;
  - when one is lost while another remains;
  - on a change to the link-properties fingerprint;
  - on a change to the set of transports.

  It also drives `device.offline`.
- **Default signal.** A default-network callback feeds `DefaultNetworkTracker`
  and kicks when the default network's identity changes.
- **Kick.** Both go through `TunnelRecoveryPolicy` (350 ms trailing debounce,
  at least 2 s between kicks) to `device.networkChanged()` on the main thread.
- **Checked and fine:**
  - no socket binding or `protect` anywhere;
  - `setUnderlyingNetworks(null)`;
  - the kick is not gated on auth or intent;
  - screen-off cancels only wake audits;
  - no watchdog restarts the service on a network change.

**1. The membership callback kicks for networks that are not the default
(High).**
- Evidence: `AvailableNetworkTracker.kt:60`, `:85`, `:94-101`. The listen
  request has no VALIDATED requirement (`PhysicalInternetNetworkRequest.kt:21-24`).
- Scenario: Wi-Fi joins while on cellular.
  - `onAvailable(wifi)` arrives at L3 connect, before validation.
  - Kick #1 re-dials over cellular, which is still the default.
  - Wi-Fi validates and the default flips; kick #2 is held until 2 s after #1.
  - Kick #2 then lands on connections less than 5 s old (S2).
  - The tunnel reaches Wi-Fi about 5–7 s after association.
- Similar spurious kicks: cellular's linger teardown, the background cellular
  network's bounces when "mobile data always active" is on, and IPv6/RDNSS
  arriving after IPv4.
- Fix:
  - Membership kicks only on offline→online:
    `added && !wasAvailable && hasSeenAvailableNetwork`. `onLost` never kicks.
  - Link properties kick only for the current physical default network, and
    only for a material change: the interface changed, or a non-link-local
    address was removed.
  - Keep the 2 s floor as a flap limiter.
  - Move the decisions into a pure class with scenario tests.
- With the shared changes this becomes more important, because each redundant
  kick now cancels a dial.

**2. ESCAPE mode leaves the app inside its own VPN, so on API 31+ the default
callback follows the tun (Medium; High for provide-only devices).**
- Evidence: the ESCAPE branch adds no app rules (`MainService.kt:630-633`). The
  app's package is disallowed only in DENYLIST (`:651`) and in the always-on
  guard (`:883`). AOSP `Vpn.agentConnect` reports the VPN to default-network
  callbacks.
- Who hits ESCAPE: provide-only devices, and any device while offline
  (`VpnPacketFlowConfiguration.kt:69-78`).
- Effects:
  - Provide-only devices never see a default flip, so their only kick is the
    early membership kick of #1. They can stay on cellular indefinitely.
  - Going offline flips the default to the VPN and kicks with no network.
  - Connect/disconnect on a providing device kicks every transport about
    350 ms later.
  - Devices on API < 31 are unaffected (platform knowledge, not shown in
    code).
- Fix (option B): on API 31+, drive `DefaultNetworkTracker` from
  `registerBestMatchingNetworkCallback(physical request + NOT_VCN_MANAGED)`,
  and read NOT_METERED from the tracked network. Option A (disallow the app in
  ESCAPE) was rejected: it would let ESCAPE↔DENYLIST hand over in place
  without resetting other apps' sockets.

**3. The first network after registering while offline never kicks (Medium).**
- Evidence: the first add and the first default are only baselines
  (`AvailableNetworkTracker.kt:60`, `DefaultNetworkTracker.kt:14`), and
  `SetOffline` does not kick.
- Scenario: the app starts at boot before attach, or restarts in airplane mode.
  The transports keep their backoff of up to 60 s (5 min for pinned ones), and
  provide-only devices have no rescue path.
- Fix: before registering, record whether any physical internet network
  exists. If none does, the first `onAvailable` counts as a recovery. Do not
  set `device.offline` from that snapshot.

**4. Always-on: any dip in providers swaps the live tunnel for the blackhole
guard (Medium, conditional).**
- Evidence: `VpnServiceStartPolicy.kt:172`, which is evaluated on every
  window-status update. The guard closes the packet flow and disallows only
  the app.
- Scenario: a switch that drops `providerStateAdded` to 0 blackholes
  everything, including excluded apps, and forces a rebuild that cannot hand
  over in place. Whether a switch actually reaches 0 providers was not
  verified.
- Fix: `vpnAlwaysOnGuardRequired = systemAlwaysOn && (!deviceAvailable ||
  wouldEscape)`.

**5. The raw `connected` flag rebuilds the tunnel on every 0↔N provider crossing
(Low).**
- Evidence: `VpnPacketFlowConfiguration.kt:85`.
- An existing test suggests this may be intended. Deferred: measure before
  changing.

**Order:** the shared changes plus an AAR rebuild, then 2, 3, 1 and 4. The AAR
is built with `make build_android` from `sdk/build`, and the app with
`-x buildSdk`.

## Windows

Reviewed at windows `2e38e28e`. Nothing was compiled on this Mac.

**How the switch is wired.**
- **Ownership.** The service owns `DeviceLocal`.
- **Signal.** `EgressMonitor` subscribes to `NotifyIpInterfaceChange`,
  `NotifyRouteChange2` (prefix-0 routes) and WLAN quality. The tun is
  filtered out.
- **Refresh.** On every event, `DiscoverEgress` picks the lowest-metric default
  route per family, then `setEgressInterfaceIndex` runs, then the network
  event is recorded unconditionally.
- **Coalescer.** `CaptureReadiness` and the `TunnelWatchdog` coalescer
  (750 ms) feed the sampler thread, which calls `networkChanged()` and then
  `notifyNetworkChange()`.
- **Provider-only devices** use `NetworkChangeNotifier`.
- **Checked and fine:**
  - the index is set before the kick;
  - the tun's own notifications are filtered;
  - WFP permits the service on any interface;
  - the failsafe is unlikely to fire mid-switch.

**1. No dedup on what actually changed: one switch produces several kicks (High
once the shared changes land).**
- Evidence: `if (networkEvent) networkEvent(); // UNCONDITIONAL`
  (`EgressMonitor.cpp:236`). Only the tun is filtered (`:259-260`).
- Scenario: Ethernet plugged in while on Wi-Fi.
  - Link-up kicks.
  - DHCP finishes later and kicks again.
  - The stale route deletion kicks a third time.
  - Churn on Hyper-V/WSL/Bluetooth adapters also kicks.
- Fix:
  - Add an `EgressChangeFilter` per-family signature in the portable
    `NetworkChangeNotify.h`:
    - *networkChanged*: {ifIndex, usable, address or /64, gateway}
    - *bindingMoved*: {ifIndex, exact address}
  - `NetworkConfig::ObserveEgress` fills it.
  - `Refresh` gates the network event on *networkChanged* and `onChange_` on
    *bindingMoved*.
  - Subscribe to `NotifyUnicastIpAddressChange`.
  - The freeze branch forces a kick via `sessionReadiness`.
  - Keep the 750 ms window, then shrink it after measuring.

**2. The sampler's sleep ignores new events (Medium).**
- Evidence: `wait_for(…, [&]{ return channel->cancelled.load(); })`
  (`TunnelWatchdog.cpp:385-386`).
- So the kick lands 0.75–2.0 s after the first event.
- Fix: wake on a pending network or quality event (a `SamplerWoken`
  predicate).

**3. A spurious kick at every tunnel start (Medium; regression from
`3ba89691`).**
- Evidence: `Start()`'s Refresh fires the network event before the watchdog
  exists, and the watchdog then replays it (`TunnelWatchdog.cpp:93-96`).
- With the shared changes, this cancels or replaces the first platform dial.
- Fix: `Start()` seeds the baseline without reporting.

**4. The app's own SDK never follows a switch (Medium).**
- Evidence: the status's egress fields are refreshed only on republish
  (`TunnelController.cpp:2867`), and `OnEgressChanged` never republishes. The
  app never calls `networkChanged`.
- Effects:
  - The app's sockets stay pinned to the dead adapter index.
  - JWT refresh and API calls fail until the next push.
- Fix:
  - On the service side, keep live egress values that `Status()` overlays, and
    request a push through a `CoalescedWorker` moved to `Common/` (never on
    the OS callback or sampler thread).
  - On the app side, when the index pair moves to a non-zero value, call
    `urnet::networkChanged()` on a worker thread. The SDK export is done.

**5. Two full kicks per burst (Low; remove together with the shared changes).**
- Evidence: `networkChanged()` and then `notifyNetworkChange()`
  (`TunnelWatchdog.cpp:408-410`). In the SDK the second is the first
  (`reliability_controls.go:760-761`).
- With the shared changes, the second kick can cancel the dial the first one
  started.
- Fix: delete the second call.

**6. The split-tunnel source address follows only index changes (Low–Medium).**
- Evidence: `EgressMonitor.cpp:199`, `:232`.
- Scenario: SSID A→B on the same adapter leaves excluded apps bound to the old
  address.
- Fix: fire `onChange_` on #1's *bindingMoved*.

**7. The egress resolver's DNS cache stays stale for up to 60 s (Low).** Fixed
in connect; see "Fix plan: shared layer".

**8. Sessions with only the RPC open never kick (Low, debug only).** The
watchdog starts after the fence (`TunnelController.cpp:1032-1049`). Fix: start
an inert watchdog in the fence, or document the gap.

**Order:**
1. #5, #7, #3 and #2 in the same SDK build as the shared changes.
2. #1 with #6.
3. #4.
4. #8.

Verification needs the Windows VM.

## Linux

Reviewed at linux `120e5df`. Most of the daemon does not build on macOS.

**How the switch is wired.**
- **Signal.** Nothing listens to the OS. `TunnelHost::Reap` runs on a 1 s GLib
  tick, and `ReadNetworkQuality` reads:
  - the IPv4 default route from `/proc/net/route`;
  - sysfs `carrier` and `speed`;
  - `/proc/net/wireless`.
- **Dedup.** `LinuxNetworkQualityTracker::Observe` reports Path on a change of
  validity, interface or carrier.
- **Kick.** `ExitSampler::NoteNetworkChange` or `networkChanged()`.
- **Checked and fine:** self-exclusion (cgroup-BPF fwmark plus an `ip rule`
  into `main`) follows a switch with no action needed.

**HIGH 1. The egress-witness recheck stops the session whenever there is no
IPv4 route.**
- Evidence: the IPv4 marked-socket leg fails on any connect error
  (`Tunnel.cpp:3125-3131`). Its IPv6 twin accepts
  ENETUNREACH/EHOSTUNREACH/EADDRNOTAVAIL (`:3195`). Two failed rechecks call
  `StopUnsafeSessionLocked` (`TunnelHost.cpp:2662-2703`).
- Scenario:
  - 30–60 s without an IPv4 default route mid-switch kills the tunnel with a
    false "egress unprotected" error.
  - On an IPv6-only network the session always stops, contradicting
    `Tunnel.cpp:1937`.
- Fix:
  - Accept a no-route errno when the socket's mark is known to be the egress
    mark, and add the same mark requirement to the IPv6 leg.
  - At bring-up, still require at least one family to bind, with a truthful
    message.
  - Put the decision in a pure `WitnessTreatmentVerdict` helper with table
    tests.

**HIGH 2 → Medium after the shared changes. A carrier change alone counts as a
path change.**
- Evidence: `NetworkQuality.hpp:34-36`.
- Scenario: Ethernet unplugged while Wi-Fi is up. The first kick fires while
  eth0 still holds the default route (NetworkManager defers the route
  removal), and a second follows when the route moves.
- Fix: folded into MEDIUM 1.

**MEDIUM 1. The detector sees only the IPv4 interface name and carrier, at
1 Hz.**
- Evidence: `TunnelHost.cpp:2564` reads only `/proc/net/route`. The gateway is
  parsed and discarded (`NetworkQuality.hpp:72-74`). The netlink monitor the
  design called for was never built.
- Missed switches:
  - from one IPv6-only network to another;
  - Wi-Fi A→B on the same interface;
  - DHCP or bearer re-addressing.
- Fix: replace `ReadNetworkQuality` with `ReadNetworkPath`.
  - Per family it records the interface, gateway and source address. The
    source comes from a UDP `connect()` probe. The tun's address is excluded,
    and IPv6 is compared at /64.
  - Read `carrier_up_count`, falling back to `carrier_changes`.
  - New tracker:
    - loss never kicks;
    - the first change kicks immediately (leading edge);
    - a 2 s holdoff, after which the path is checked again;
    - a same-identity rejoin kicks only after an offline gap;
    - `Rebase` after every `NewDeviceLocked` (this also fixes LOW 2);
    - `ForceKickOnNextPath`.
  - Netlink comes later, as a "re-poll now" trigger.

**MEDIUM 2. DNS repair on hosts without systemd-resolved runs on a 10 s tick,
not on the switch.**
- Evidence: `kDnsVerifyIntervalSeconds = 10` (`TunnelHost.cpp:76`, `:2491`).
  It only matters for the direct-file tier.
- Fix:
  - Check every tick for every backend except SystemdResolved.
  - Skip `ApplyFilterLocked` when nothing changed.
  - In the direct-file re-apply, adopt a file without the marker as the new
    backup. Otherwise, after a mid-session switch, disconnecting restores the
    previous network's resolv.conf.

**LOW 1. Nothing kicks after resume.**
- No logind handling.
- Fix: in `Reap`, before the try-lock, watch the growth of `CLOCK_BOOTTIME −
  CLOCK_MONOTONIC` and call `ForceKickOnNextPath` when it grows.

**LOW 2. The tracker's baseline is stale, or taken during bring-up.** Fixed by
MEDIUM 1's `Rebase`.

**LOW 3. The egress resolver's DNS cache stays stale.** Fixed in connect; see
"Fix plan: shared layer".

**LOW 4. The GUI's SDK never hears about switches.** This only matters for its
API calls while disconnected. Deferred.

**Order:**
1. HIGH 1.
2. MEDIUM 2.
3. The shared changes plus LOW 3, then rebuild the Linux SDK library.
4. MEDIUM 1 + HIGH 2 + LOW 2.
5. LOW 1.

The netlink trigger and LOW 4 are optional. Holdoff tuning and an
all-links-down 2 min check need a real Linux host.

## Fix status

All of this landed on `main` on 2026-10-20 (see decision 1).

connect's suite was run on the final tree: the merged `main` `94209546`
plus this work. The nine tests that used to hit a nil-pointer panic in
`acquireAffinityDelivery` were skipped for that run, so it could reach the
end. Those nine now pass on their own: upstream `85feef40`, which
preserves affinity races under cancellation, fixed the panic. The run took
about 30 minutes: 6,126 pass, 35 fail, 35 skip.
- 33 of the 35 also fail on a clean copy of `94209546`.
- The other two failed only under the load of parallel builds:
  `TestDeviationTimerDoesNotCoverAnUnsampledStall` and
  `TestManagedStreamOpenRegistrySurvivesSequentialUniqueChurn`. Each passes
  3 of 3 in isolation, on both trees.

None of the 33 is in code these fixes change, and another developer is
fixing them. An earlier run, on `58786550`, had 47 failures, all also on that
HEAD; upstream has since fixed some of them. Each of the five connect commits
was also checked on its own: `go vet` plus that commit's tests.

| Item | Status |
|---|---|
| S1, S2, S5 | Implemented in connect; tests added |
| S3, S4 | Implemented in connect; tests added |
| S7 | Implemented in connect; test added |
| S8 | Implemented in connect; tests and a source guard added, mutation-checked |
| Kick re-dial cap (decision 2) | Implemented in connect: `ClientStrategySettings.KickReconnectLimit` (12) gives kick re-dials their own slots; past it a re-dial takes the ordinary reconnect path; 3 tests |
| Recent-exit memory (decision 4) | Implemented in connect: `ip_remote_multi_client_recent_exits.go`, 22 tests, race-clean, eight deliberate mutations each caught. The SDK needed no change. On-device measurement still needed. |
| S6 | Implemented in connect: `networkPathGeneration` lets a hard change through every quality coalescer once; 6 tests, six deliberate mutations each caught |
| Windows #7, Linux LOW 3 | Implemented in connect |
| Windows #4 SDK export | Implemented in sdk (`sdk.NetworkChanged`); cgo headers regenerated |
| SDK artifacts | Local build outputs, not committed. Rebuild them from the landed connect and sdk: `make build_apple` and `make build_android` from `sdk/build`, and `make -C sdk/cgo build_linux build_windows_amd64`. Windows arm64 can't be built on this machine (no `aarch64-w64-mingw32-clang`). |
| A1–A5 | Implemented in the extension, with its timing in `TunnelRecoveryTiming`. On an iPhone 17 / iOS 27.0 simulator, linked against the rebuilt SDK: `TunnelRecoveryTests` 67/67, including the new path-transition, `isApplied`, timing-default and A6 tests. The macOS app and extension build. On-device checks still needed. |
| Decision 4 (app restart policy) | Implemented in the app: `vpnTunnelRecoveryInProgress` and `VPNManagerSettings.recoveryPatience` in `waitForRecoverableTunnelHealth`, with the episode kept per tunnel instance. Every `VPNManager` timing and bound now comes from `VPNManagerSettings`. `VPNReconciliationSupportTests` 58/58 on the same simulator, linked against the rebuilt SDK. On-device checks still needed. |
| A6 | Implemented in the extension: structured path signature with local addresses, a late-gateway grace, and a cause on every transition line; 10 new path-transition and address tests, and the existing transition tests moved to the structured signature |
| Android 1–4 | Implemented in android. New pure `PhysicalPathRecovery` and the tracker changes; fix 2 uses `registerBestMatchingNetworkCallback` on API 31+. Timing moved into `TunnelRecoverySettings` and `VpnTunnelTimingSettings`. `testPlayDebugUnitTest -x buildSdk`: 1642 tests, 0 failures, 1 skipped. That includes the fixed `DeveloperAffinityMaxTimeTest` (added in `3d5e3b2c0`), which was already failing before this work: it required `resetReliabilitySettings()` and also forbade the text `ReliabilitySettings(`, and it now forbids only a constructed settings object. android HEAD `f95c6c5da` did not compile, so three login lambda-arity call sites were patched first (`AuthCodeLoginSheet`, `SeedphraseLoginSheet` and the debug `FlightGateDebugReceiver`). All eight variants (github, play, solana_dapp, ethos_dapp × debug, release) compile. On-device checks still needed. 5 deferred (measure first). |
| Windows 1–6, 8 | Implemented in windows. Changes: <ul><li>an `EgressChangeFilter` signature dedup, with `ObserveEgress` and a `NotifyUnicastIpAddressChange` subscription;</li><li>baseline at `Start`, sampler wake, one kick per burst;</li><li>a live egress overlay in `Status()` plus a coalesced push;</li><li>an app kick via `urnet::networkChanged()`;</li><li>a watchdog for rpc-only sessions;</li><li>the 15 s freeze kick (decision 6) and the watchdog, capture and notifier timing moved into settings (see Settings instead of constants).</li></ul>Tests: <ul><li>Go wiring suite 550 pass / 0 fail / 3 skip before the settings rounds (HEAD: 520 / 0 / 19); the affected subset afterwards: 61 pass / 0 fail / 0 skip;</li><li>native `network-change-notify` 53/53, `watchdog-settings` 11/11, `capture-readiness` 17, `stats-publish` 8/8;</li><li>mingw syntax check: the same errors as clean HEAD, none new.</li></ul>Not compiled with MSVC. |
| Linux HIGH 1, HIGH 2, MEDIUM 1, MEDIUM 2, LOW 1, LOW 2 | Implemented in linux. Changes: <ul><li>the witness verdict plus `no_network` at bring-up;</li><li>DNS repair checked every tick, plus resolv.conf backup adoption;</li><li>a rewritten path tracker: `ReadNetworkPath` with a source probe and `carrier_up_count`, a 2 s holdoff, `Rebase`, `ForceKickOnNextPath`;</li><li>a suspend detector;</li><li>the dead-tunnel watchdog's offline pause (decision 5);</li><li>every watchdog, reaper, path and suspend timing moved into settings (see Settings instead of constants).</li></ul>Tests: <ul><li>clang on macOS 1550 pass / 0 fail; g++ 13 in a Linux container 1555 pass / 0 fail;</li><li>the 13 daemon sources compile with no warnings in the container (not linked, because the local SDK copy is from September);</li><li>a live-kernel harness 21/21; connect's Linux-only tests 9/9.</li></ul>Netlink trigger and LOW 4 deferred. |
| Settings follow-up (2026-10-21) | A check of every function the connect commits changed found constants they still read. Those, and the package constants that only fed defaults constructors or the fallbacks for non-positive settings, moved into settings (see Settings instead of constants). The SDK's device RPC limits, the server's hybrid stream queue and sn's swarm fallback read the moved values. Tests: <ul><li>connect: `go vet` clean, tests included; a new test pins the defaults that used to be one constant to each other, and two cover a non-positive quiet interval;</li><li>connect full suite on `f1837db6` plus this change: 6,173 pass, 36 fail, 35 skip. All 36 fail the same way, run alone, on a clean `f1837db6`;</li><li>connect and sdk build for linux, windows and js/wasm, and connect for android;</li><li>server `connect` and sn `miner` build and vet. Their unit-level H3 and swarm tests pass. The H3 integration tests need `WARP_ENV=local`, and two swarm tests need 127.64.x.x loopback aliases, which macOS lacks; those fail the same way on clean checkouts.</li></ul> |

## Settings instead of constants

Every timing value and policy count on the switch path is now a field of the
settings its owner is built with, with its default set in one place. The rule
is written down in `connect/CODESTYLE.md` under "Tunables live in settings":
- no global or hard-coded tunables;
- one default, in one place;
- each field documents its unit, why it has that default, and what zero means;
- a legacy constant moves into settings when a change touches code that reads it.

| Where | Settings | What moved, with defaults |
|---|---|---|
| connect | `ClientStrategySettings`, `MultiClientSettings`, `ClientSettings`, `SendBufferSettings`, `PlatformTransportSettings`, `H3DatagramSettings` | <ul><li>`ReconnectFastPathLimit` 4 (non-positive disables the fast path), `ReconnectFastPathMaxDelay` 250 ms (non-positive means no jitter), `RecentExitMemoryTimeout` 5 min (non-positive turns the memory off), `KickReconnectLimit` 12 (non-positive removes the cap);</li><li>moved on 2026-10-21 from constants that functions this work changed still read: `WindowQualityRemeasureInterval` 5 s (non-positive coalesces nothing and lets no evidence shrink the window), `NetworkQualityNotificationRetryInterval` 100 ms (non-positive does not retry), `EvaluationFailureLogInterval` 5 s (non-positive logs every line), `H3StreamWriteBatchMaxMessageCount` 16 and `H3StreamWriteBatchMaxByteCount` 64 KiB (non-positive writes one message at a time), and `HybridStreamQueueMessageCount` 32 and `HybridStreamQueuePayloadByteCount` 64 KiB (must be positive; the client and the server share them);</li><li>defaults that were package constants, now set in their defaults constructors: `MaxHttpResponseBodyBytes` 2 MiB, `IpFamilyStarvedRetryTimeout` 60 s, `ReadTimeout` and `BlackholeTimeout` 30 s, the transfer queue depth 32, the receive sequence depth 256 and the `H3DatagramSettings` limits. The fallbacks for non-positive values read those constructors too, as the signal worker count now does. A test pins the defaults that used to be one constant to each other.</li></ul> |
| SDK, server, sn | `deviceRpcSettings` (`sdk/device_rpc.go`); the server's `ConnectHandlerSettings.H3DatagramSettings`; sn's miner swarm settings | <ul><li>SDK: mux frame 3 MiB and queue 4 MiB, HTTP concurrency 2, and an HTTP body limit taken from `ClientStrategySettings.MaxHttpResponseBodyBytes`. Non-positive values use the defaults.</li><li>Server: the hybrid stream queue comes from its `H3DatagramSettings`.</li><li>sn: the swarm's response-body fallback reads `ClientStrategySettings`.</li></ul> |
| Apple app | `VPNManagerSettings` (`VPNReconciliationSupport.swift`), owned by `VPNManager` | <ul><li>health audit delays: 0 s disconnected, 1 s disconnecting, 3 s connected-backend, 5 s transitional, 1 s app path, 1 s RPC connected;</li><li>`tunnelCheckTimeout` 10 s, `healthPollInterval` 250 ms, `recoveryPatience` 120 s;</li><li>`stateBurstCoalesceDelay` 20 ms, `bootstrapLookupTimeout` 2 s, `backgroundHealthLease` 25 s, `rpcConnectTimeout` 15 s;</li><li>`preferencesOperationTimeout` 30 s, `providerLogoutMessageTimeout` 2 s, `maximumProfilesToRemove` 32, `profileJwtConvergeAttempts` 3.</li></ul> |
| Apple extension | `TunnelRecoveryTiming` (`TunnelLocalStateIdentity.swift`), owned by the provider | `pathSettleDelay` 350 ms, `minimumKickInterval` 2 s, `minimumPathRecoveryInterval` 2 s, `defaultPathRecheckDelay` 500 ms, `wakeHealthGrace` 5 s, `lateGatewayGrace` 5 s (0 kicks on every gateway change), `settingsRetryDelay` 350 ms, `authObservationDeadline` 15 s, Wi-Fi sampling every 5 s with 1 s leeway (0 samples once) |
| Android | `TunnelRecoverySettings` (`TunnelRecoveryPolicy.kt`), `VpnTunnelTimingSettings` (`VpnServiceStartPolicy.kt`) | <ul><li>transport recovery debounce 350 ms, minimum interval 2 s, wake audit debounce 350 ms, wake health grace 5 s;</li><li>TUN retry delays 250 ms, 1, 2, 5, 10, 30 s (the last repeats), shared by configuration rebuilds and the Always-on guard;</li><li>Always-on connect re-request 30 s (was a literal).</li></ul> |
| Windows | `TunnelWatchdogSettings` and `DeadTunnelSettings` (new `Service/TunnelWatchdogSettings.h`), `NetworkNotifySettings` (`NetworkChangeNotify.h`), `CaptureReadinessSettings` (`CaptureReadiness.h`) | <ul><li>sampler 2 s, evaluator 1 s, freeze 5 s (asserted as five evaluator ticks), freeze network change 15 s, join budget 250 ms and its 10 ms poll;</li><li>dead-fast 20 s and 8 packets, dead-slow 90 s, SDK unresponsive 30 s, its arm 10 s, the notice 30 s;</li><li>network-change window 750 ms;</li><li>capture probe-age resolution 1 s (also the sampler's re-probe delay), freshness 8 s, stall diagnostic 30 s.</li></ul> |
| Linux | `DeadTunnelSettings` (`TunnelWatchdog.hpp`), `HostSettings` (`daemon/HostSettings.hpp`), `LinuxNetworkPathSettings`, `LinuxSuspendSettings` | <ul><li>evaluate 1 s, sample 2 s, freeze five evaluate ticks, offline rebase 5 s;</li><li>dead-fast 20 s and 8 packets, dead-slow 90 s, SDK unresponsive 30 s, its arm 10 s, the notice 30 s;</li><li>reaper 1 s (asserted equal to the evaluate tick), nftables check every 5 ticks, logged every 12th failure;</li><li>DNS and egress-witness check cadences and attempt counts;</li><li>path holdoff 2 s, suspend threshold 1 s (0 turns the detector off).</li></ul> |

Left as constants, in code this work did not touch:
- **connect:** the package constants whose readers this work did not change, such as `backendDegradedWindow`, `nextConnectMaxLead`, `quarantineMemoryDuration`, `networkQualityMaximumRememberedPeerCount` and `controlDialLogInterval`. The H3 memory ledger's rows (`platformH3*Bytes`, `platformH3DialTransientByteCount`) also stay. They record the memory a carrier retains, and its tests pin them to each other, so they are facts rather than knobs: a setting could drift from what the code holds.
- **Apple:** the extension's memory monitor and widget snapshot cadences, and `tunnelStopCloseJoinTimeoutMilliseconds`.
- **Android:** `VPN_STATE_BURST_COALESCE_MILLIS` (20 ms, the reconcile coalescer every device listener shares), the foreground-service start adoption timeout and retry delays, `MainService`'s close-monitor `wait(1000)`, and the analytics and connect-UI constants.
- **Windows:** the app's network-country watch budgets, `StopBudget.h`, and the 10 ms `try_lock_for` in `ActivateCapture`.
- **Linux:** `kLogUploadReturnBudget`, `kProviderCloseWaitMillis`, the storm thresholds and strike count, `ProviderStatusLease::kLeaseMillis`, and `GlogFlusher`'s 1 s interval.

## Decisions needed

All six are decided.

1. **Landing.** Done on 2026-10-20. In each repo, a `fix/network-switch`
   branch was merged into `main` (no fast-forward), pulled with
   `--rebase=merges`, and pushed:
   - connect `45c09519`, in five commits: re-dial at once (S1–S5, S4, the
     cap); remeasure pacing (S6); wake the window (S7, S8); the recent-exit
     memory; and the CODESTYLE rule;
   - sdk `1d67a1d6`;
   - android `3b07ce57f`, in three commits: the login-callback compile fix,
     the `DeveloperAffinityMaxTimeTest` fix, and the network-switch changes;
   - linux `f0e2507`;
   - windows `40125dac`, merged on request before the MSVC build and the VM
     checks, which are still to do;
   - apple: this record's merge, in three commits: the extension, the app,
     and this file.

   Each push also carried the commits that were already on that repo's
   local `main`, made under the same git identity. The P2P answer-replay
   change in connect is another stream's, committed by it as `5f935e6b`.
   The SDK build outputs (xcframeworks, AAR, desktop libraries) are not
   committed; rebuild them after pulling.
2. **Uncapped kick re-dials (S3).** Decided: a cap of 12, as a setting
   (`ClientStrategySettings.KickReconnectLimit`). It is above every device's
   transport count today (about 5 on iOS, up to about 11 on desktop), so a
   switch is unchanged. It bounds a future growth in transports per device.
   Kick re-dials hold their own slots, and one past the cap takes the ordinary
   reconnect path. The fleet-wide herd from many devices handing over together
   is left to the 0–250 ms jitter and the platform's client-limit backoff. If
   the load balancer shows handshake spikes, widen `ReconnectFastPathMaxDelay`.
3. **Release coordination.** Decided on 2026-10-21: the SDK is updated along
   with the apps. Kicks now cancel in-flight dials, so every extra kick costs
   a dial, and a Windows or Linux build that bundles the new SDK needs its own
   kick fixes (Windows #1/#5, the Linux tracker). Each app bundles its SDK at
   build time, so each app's release carries the new SDK together with its
   own fixes. Apple and Android already dedup their kicks.
4. **Apple app restart policy.** Decided: the app waits while the tunnel is
   recovering by itself, and the window first retries the exits it just had.
   - The app no longer restarts a tunnel at the 5 s grace deadline while
     `vpnTunnelRecoveryInProgress` holds: the profile is connected or
     reasserting, the RPC answers, the SDK tunnel runs, a provider window
     wants exits and has not latched `failed`. The wait is bounded by
     `VPNManagerSettings.recoveryPatience` (120 s). A window that never
     forms latches `failed` after its own silent rebuild (two 45 s outcome
     deadlines), which hands the decision back to a restart. The episode
     start is kept per tunnel instance and cleared when a wait is abandoned
     because the app went inactive, so an old episode never shortens a new
     one.
   - The window remembers the exits it lost to an outage on our side for 5
     minutes and asks for them first on the next round (see Recent-exit
     memory).
5. **Linux dead-tunnel watchdog while offline.** Decided: pause it. While
   the tracker reports offline, the NoInbound and NoExit stops don't count
   down. The SDK-unresponsive check and the veto still use real time, so a
   wedged SDK is still stopped. A return after `offlineRebaseMillis`
   (default 5 s) or more offline restarts every timer. A shorter blip only
   has its own seconds excluded, so a link that drops for under 5 s at a
   time cannot keep a dead tunnel alive. A link that keeps dropping for 5 s
   or longer restarts the windows on every return; that is the intended
   cost of not stopping a tunnel for time it spent offline. Implemented in
   `TunnelWatchdog.hpp` (`StepOffline`), fed by `NetworkQuality.hpp`
   `offline()`.
6. **Windows freeze kick threshold.** Decided: 15 s. A stall of 5–15 s still
   rebases the failsafe timers but no longer kicks. Implemented as
   `TunnelWatchdogSettings.freezeNetworkChangeMillis` (default 15000), decided
   by the portable `FreezeResponseFor` helper. A 5–15 s stall during capture
   now applies `CaptureReadiness::ProofBarrier()` without queuing a network
   event.

## Open follow-ups

- **Shared:**
  - S6: the provider still coalesces our quality notification on its side (the wire message has no hard-change flag).
  - The recent-exit memory's 5 minutes and its in-the-dark verdict rule are first values; tune them from the `recent_exit` events.
- **Apple:**
  - A6: `lateGatewayGrace` (5 s) is a first value; tune it from the `refined cause=late-gateway` lines. A different network handing out the same address behind the same gateway address is still undetected.
  - `recoveryPatience` (120 s) is a first value. Tune it from device logs: the time between `tunnel recovering on its own` and the tunnel turning healthy.
- **Android:**
  - Fix 5 is deferred until it can be measured.
  - `NetworkCountryReporter` still uses `registerDefaultNetworkCallback`, so in ESCAPE mode on API 31+ it sees the VPN. That only affects country reporting.
- **Windows:**
  - The app's Preparing bind still receives index 0, because egress is reported only once routes are installed.
  - An interface with both a ULA and a global IPv6 address whose global prefix is renumbered re-pushes the split tunnel but does not kick.
- **Linux:**
  - The daemon links an untracked local copy of the SDK library (`app/third_party/urnetwork-sdk`), which on the build Mac predates this work. The release build stages the new one (decision 3).

## Still to verify on devices

- **Shared (any platform):**
  - After an outage of a minute or more, the first `window enumerate` after the network returns comes within about a second, not after a backoff of up to 15 s.
  - The exits held before the outage come back first: `recent_exit action=try`, then `admit`.
- **Apple:**
  - Wi-Fi→cellular and cellular→Wi-Fi: the time from `stable physical path transition` to `network_change`, then to the first `transport restored`. Target is about 1–1.5 s.
  - A switch just before the phone sleeps: an `owed-across-sleep` kick on wake.
  - A start in airplane mode: one `physical-path-restored` kick when the network returns.
  - No lingering `.reasserting` after a failed recovery.
  - A cellular attach whose gateway arrives late logs `refined cause=late-gateway`, with no second kick.
  - Wi-Fi A→B on the same interface without an unusable gap kicks once, with `cause=address`.
  - A switch that leaves the tunnel `.reasserting` past 5 s: the app logs `tunnel recovering on its own` and does not restart it. It restarts only when the window reports `failed` or after 120 s.
- **Android** (from the `[tunnel-lifecycle] transport recovery reasons=` lines):
  - Wi-Fi joining while on cellular: exactly one `default-network-changed`, and none for the second network appearing or for cellular lingering out.
  - Wi-Fi turned off while cellular is up: one kick.
  - Provide-only device on API 31+, toggling Wi-Fi: one kick each time.
  - Airplane-mode start, then airplane mode off: one `physical-network-returned`.
  - No always-on guard during a provider dip.
  - Data Saver degraded state in ESCAPE mode.
  - A regression pass on API 26–30.
- **Windows** (on the VM):
  - An MSVC build and `urnetworkd selftest`.
  - Switch matrix (Wi-Fi→Ethernet, cable out, Wi-Fi→phone hotspot, Wi-Fi→WWAN): one kick per switch, about 750 ms after the first event.
  - No kicks from Hyper-V/WSL churn or IPv6 privacy-address rotation.
  - The app re-pins to the new interface after a switch.
  - The split tunnel follows a same-adapter SSID change.
  - One kick after a Modern Standby resume ("Long enough to have been a sleep…").
  - A 5–15 s stall under load: the timers rebase and the log says "Too short…", with no kick.
  - `--rpc-only` sessions kick.
  - Service stop does not hang.
- **Linux:**
  - All links down for 2 min, and a switch onto an IPv6-only network: the session survives. The journal shows "no network…" and then "back on a network after 120s offline", with no failsafe stop.
  - With no exit proven on the new network, the no-exit stop comes 90 s after the return, not earlier.
  - A Wi-Fi blip under 5 s restarts no watchdog timer.
  - An SDK that hangs while offline is still stopped after 30 s.
  - A cable pull with Wi-Fi up gives exactly one kick, when the route moves.
  - Tune the 2 s holdoff: expect 1, at most 2, path-change lines per switch.
  - Suspend/resume on wired and on Wi-Fi gives one kick.
  - On a host without systemd-resolved, DNS is out for at most about 1 s per switch, and disconnect restores the new network's resolv.conf.
  - A connect with no network shows the `no_network` message.
  - A GCC 11 build on Ubuntu 22.04.
