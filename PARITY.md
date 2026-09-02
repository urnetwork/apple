# Cross-platform parity audit — 2026-07-16

Seven audits over six app surfaces, grounded in current source (not planning docs):

1. iPad vs iPhone (this repo)
2. Android tablet vs iPad (`../android`)
3. Android vs iOS
4. macOS vs iOS (this repo)
5. Windows vs macOS (`../windows`)
6. Linux vs macOS (`../linux`)
7. Web vs macOS (`../mmm/ur.io/react`)

Corrections to prior notes discovered during verification:

- **Android contract-stacks port is DONE** (`ui/stats/ContractStatsScreen.kt` + `ContractStatsViewModel.kt` use the new `ContractPeerRow`/`ContractEntry` SDK API; zero references to the old aggregated API). Earlier notes said "pending".
- **macOS "Sign in with Solana" was enabled, then deliberately removed** (`LoginInitialView.swift:1111-1113` comment). macOS is now the only platform without Solana login.
- **`mmm/ur.io/APP.md` overstates the web app** (claims DNS editor / block-ads toggle are built; code has them bound but unwired). **`windows/PLAN.md`+`NEXTSTEPS.md` understate the Windows app** (code is well past the "subset" framing).
- **iOS dead code:** `ConnectView-iOS.swift:383` presents a guest→create-account `fullScreenCover` on `ConnectViewModel.isPresentedCreateAccount`, but nothing ever sets it `true` (`AccountMenu` binds `AccountRootViewModel`'s flag instead). Wire it or delete it.

---

## 1. iPad vs iPhone

**Posture:** iPad is a build target (`TARGETED_DEVICE_FAMILY "1,2"` app+extension, all iPad orientations, no `UIRequiresFullScreen` → Split View/Stage Manager resizable) but **not a UI target**. Zero `horizontalSizeClass` reads, zero `.popover`, no iOS `NavigationSplitView`, no scene manifest. `MainView.swift:77-99` hard-selects the phone `MainTabView` for all iOS; `MainNavigationSplitView` exists but is macOS-gated.

The only genuinely iPad-adaptive screen is login (`LoginInitialView.swift:52-95`, two-column when landscape+pad) — and its trigger is fragile: it seeds from `UIDevice.current.orientation` at `onAppear` (`:224`), which is `.unknown`/`.faceUp` at launch, so a landscape iPad often gets the single-column phone layout until rotated.

**Gaps (file:line):**

| # | Gap | Where |
|---|-----|-------|
| D1 | Connect drawer = full-width fixed-math phone drawer (`sheetMaxHeight 680`, hard-coded tab bar `49+safeArea`, screenHeight offsets) | `ConnectView-iOS.swift:48,76,237,255-268,446-449,469-470` |
| D2 | Connect globe/grid canvas hard-coded **256pt**, never scales | `ConnectButtonView.swift:30`; `ConnectCanvasConnectingStateViewModel.swift:46`; `ConnectCanvasConnectedStateView.swift:106` |
| D3 | Onboarding funnel full-screen, **no width cap**, full-width CTAs (every new user sees this stretched) | `IntroductionView.swift:58-246`; `IntroductionUsageBar.swift`; `ParticipateReferView.swift`; presented `MainTabView.swift:213` |
| D4 | Leaderboard header/rows uncapped full width | `LeaderboardView.swift:56,257-303` |
| D5 | Settings `Form` uncapped (macOS variant caps 600; iOS doesn't) | `SettingsForm-iOS.swift:40-348` |
| D6 | Payout detail uncapped | `PayoutItemView.swift:106,114` |
| D7 | All modals are `.sheet` with small fixed detents → tiny centered cards on iPad (guest/auth-code/Solana login sheets, redeem code, update-referral, connect-wallet); stats sheets have `#if os(macOS)` sizing but no iPad sizing | `LoginInitialView.swift:156,174,189`; `RedeemBalanceCodeSheet.swift:101`; `SettingsView.swift:125`; `WalletsView.swift:189`; `ConnectStatsSections.swift:282` |
| D8 | Two-column login trigger uses device orientation, not size class | `LoginInitialView.swift:59,221-238` |
| D9 | **Root cause:** no size-class/regular-width layout path anywhere on iOS | `MainView.swift:77-99`; `MainTabView.swift:97` |
| D10 | No multi-window/Stage Manager posture (single `WindowGroup`, no scene manifest) — app IS resizable but no layout responds | `NetworkApp.swift:139-203` |

**Well-adapted already (keep):** width caps `maxWidth: 600` on AccountRoot/Feedback/ContractDetails/Wallet(s)/Profile/ConnectActions content; auth forms capped 400; `TransferChart` Canvas is width-responsive.

## 2. Android tablet vs iPad

**Posture:** same story, slightly ahead of iPad. Not orientation-locked, resizable (targetSdk 36 default), TV/leanback is the explicit large-screen investment. `material3-window-size-class` is on the classpath but **never used**; adaptation keyed off a bespoke `isTablet()` heuristic (`utils/DeviceUtils.kt:10-34`) that **misses 7-8" tablets in portrait** (requires landscape unless diagonal ≥ 9").

| Dimension | iPad | Android tablet |
|---|---|---|
| Adaptive nav | none (phone TabView) | `NavigationRail` in tablet-landscape (`MainNavHost.kt:193-201,429`) |
| Login forms | capped 400pt; 2-col landscape (fragile) | capped 512dp centered (all screens) |
| Connect canvas | fixed 256pt | fixed 256dp (`ConnectButton.kt:100`; TV gets 128) |
| Connect sheet | full-width custom drawer, fixed math | `BottomSheetScaffold` full-width, no cap (`ConnectScreen.kt:270`) |
| Onboarding funnel | uncapped full-screen | uncapped full-width (`introduction/Introduction*.kt`) |
| Settings/account/wallet/stats/leaderboard | uncapped | uncapped (`SettingsScreen.kt:416`, `AccountScreen.kt:118`, `LeaderboardScreen.kt:100`, …) |
| Two-pane layouts | none | none (no `ListDetailPaneScaffold`; adaptive pane lib not even a dependency) |
| Size-class API | absent | present-but-unused dep |
| Resource qualifiers | n/a | no `values-sw600dp`/`layout-sw600dp` at all |
| One custom-adaptive screen | login | Feedback (3 branches — but landscape-tablet column is left-aligned not centered, `FeedbackScreen.kt:236-244`) |

**Shared parity checklist for both platforms** (mirrors the stats-UI mirroring convention):
1. Cap content width on every screen (iOS 600pt / Android 600–640dp), matching the screens that already do it.
2. Scale the connect canvas with available space instead of 256 fixed (both platforms, same constant).
3. Cap the connect drawer/sheet width on large screens.
4. Adopt real size-class detection: `horizontalSizeClass` on iOS (fixes D8), `currentWindowAdaptiveInfo`/WindowSizeClass on Android (fixes portrait-tablet miss).
5. Adaptive nav: Android already swaps to rail; iOS candidate = reuse `MainNavigationSplitView` on regular-width iPad or `.tabViewStyle(.sidebarAdaptable)`.
6. Two-pane candidates (later): provider list, account tree, stats drilldowns.

## 3. Android vs iOS

**Overall: strong parity.** Auth, onboarding funnel, connect surface (button/canvas/status/drawer stats/DNS pill/blocker), providers, contract stacks, split rules, DNS editor, network peers, provider stats, wallets/points/reliability, referral, leaderboard, settings tail, feedback — all ported both ways.

**iOS-only (Android lacks):**
- Sign in with Apple (platform-appropriate; still a login-method gap).
- **OS-level quick connect and widgets** — at parity as of 2026-09-02: iOS has the Control Center / Lock Screen / Action button control, Siri/App Intents and the dashboard, provider globe and contracts Home Screen widgets (`app/widgets/`, `QUICKCONNECT.md`); Android has the polished Quick Settings tile, launcher shortcuts and the same three widgets (`android/QUICKCONNECT.md`).
- On-demand VPN reconnect rules (`VPNManager.swift` `NEOnDemandRuleConnect`); Android relies on always-on only.
- "Review URnetwork" explicit row (`AccountRootView.swift`); Android fires in-app review programmatically instead.

**Android-only (iOS lacks):**
- Per-app split tunnel (`AppSplitRulesScreen.kt` + drawer apps panel) — platform limitation on iOS, by design.
- **Profile network-name editing** with live validation (`ProfileScreen.kt`); iOS displays only. Portable.
- Account switcher popup + switch-account screen (`AccountSwitcher.kt`, `SwitchAccountScreen.kt`); iOS has the lighter `AccountMenu`.
- API-error full retry screen (`ApiErrorScreen.kt`); iOS uses snackbars.
- Verified `https://ur.io/c` app links; iOS has only the `urnetwork://` custom scheme (no associated-domains).
- Flavor rails: Play Billing / Stripe / Solana Pay / EthOS wallet; F-Droid background self-update; battery-optimization + foreground-icon toggles; TV/leanback; boot auto-restart.

**Divergences worth aligning:**
1. Google SSO absent on the default `github` flavor (`BRINGYOUR_BUNDLE_SSO_GOOGLE`) — different default login surface per store.
2. Upgrade flow: Android has explicit billing-error dialog + purchase-pending overlay; iOS relies on flags + `PurchaseSuccessView`.
3. Referral share: native share sheet (iOS) vs bespoke full-screen overlay (Android).
4. Celebratory overlays: Android has a whole `overlays/` system; iOS uses sheets/snackbars.
5. Notifications setting: app preference (iOS) vs OS permission flow (Android).
6. Insufficient-balance CTA target: intro funnel (iOS) vs `Route.Upgrade` (Android).
7. Deep-link scheme mismatch: `urnetwork://` (iOS) vs `ur://` (Android) — matters for the ur.io/wallet-connect bridge return path.
8. Seeker multiplier placement: wallet (iOS) vs settings, solana_dapp only (Android).

## 4. macOS vs iOS

**Near-complete parity — the 2026-07-10 push held.** All recent iOS work is reachable on macOS: connect stats sections, contract stacks (+copy-client-ID), split rules, DNS editor, network peers, provider stats charts, device rename, blocked-location search, wallet bridge. Architecture confirmed: only split screens are the nav roots + `ConnectView-*` + `SettingsForm-*` pairs (plus in-file `SSOButtons`/`AppDelegate` splits); 83 `#if os` guards, ~65 cosmetic.

**Remaining gaps:**
1. **Sign in with Solana on macOS login** — deliberately removed (`LoginInitialView.swift:1111-1113`). The Bittensor button in the same view proves the ur.io/wallet-connect browser bridge works on desktop; `presentSignInWithSolanaSheet` is already passed into macOS `SSOButtons` (`:997`) unused. Re-adding is small wiring — but it was removed on purpose, so this is a **product decision**, not just a task. Every other platform has Solana login.
2. Dead guest cover (see corrections above) — iOS-side fix; nothing to port.
3. "Allow providing on cellular" absent on macOS — N/A by design.

**macOS extras (superset, intended):** menu-bar extra (4-state icon), Cmd-Q intercept/hide-to-tray, launch-at-login, Account command menu, disconnect-before-purchase, side provider table, refresh toolbar buttons.

## 5. Windows vs macOS

**Maturity:** WinUI 3 / C++/WinRT + `urnetworkd` service + wintun + WFP split-tunnel driver. Code is well past the planning docs — but **never compiled on a Windows toolchain** (`NEXTSTEPS.md:15-19`); all parity is static-source parity. SDK artifact for arm64 also blocked on `llvm-mingw` (apple `NEXTSTEPS2.md` appendix).

**At/near parity already:** full email auth + guest + auth-code + Solana/Bittensor bridge login, connect + provider picker + all four detail sheets (contracts/split/DNS/throughput) + blocker + performance profile, plan/usage/redeem/balance-codes, Stripe embedded checkout, profile rename, leaderboard, feedback, localization (28 locales), tray, deep links, per-app split tunnel (Windows-only, matches Android capability).

**Gaps vs macOS:**
- **Google + Apple SSO** — absent (`sso_google=false`, `SdkHost.cpp:105`); planned as system-browser OAuth, not built.
- **Provide control entirely** — no mode picker, no toggle, tray provide-state hardcoded false (`SdkHost.cpp:793`, `AppController.cpp:157`). Contradicts the v1 plan scope.
- **Wallet/payout depth** — list+add-address only; no set-default/remove/payments/points breakdown/reliability/unpaid-data/earnings.
- **Settings tail** — kill switch, blocked locations, device rename/spec, auth-code create, copy client-ID/referral code, update referral network, notifications, product updates, Discord/DePIN links, delete account, version, launch-at-startup (tray app), custom network space (hardcoded `Ids.h:52`).
- Onboarding funnel, App Intents equivalent, updater, export logs, provider-contracts entry point (code path exists, no UI), animated connect canvas.

## 6. Linux vs macOS

**Maturity:** GTK4/gtkmm + libadwaita, single-process tunnel (`/dev/net/tun` + `resolvectl`), strict snap. **Written but not yet compiled** (needs Ubuntu toolchain; GTK UI "written blind").

**At/near parity:** the whole connect surface — email auth + guest + upgrade + auth-code + Solana/Bittensor login, connect/disconnect, provider chooser, performance controls, 3 stats charts, contract stacks, split-rules editor, DNS editor + pill, blocker toggle, plan/usage card, Stripe (embedded WebKitGTK), redeem code, peers line, tray, deep links, i18n.

**Gaps vs macOS — roughly the whole Account half** (matches `linux/NEXTSTEPS.md` §6 as known remaining work): no Account/Profile/Settings/Wallets/Leaderboard/Support screens at all; no Google/Apple SSO; no onboarding funnel; provide is a boolean switch not a mode picker; tray is 2-state (provide icon asset shipped, unused); no notifications/autostart/blocked locations/device rename/delete account/balance-codes management/referral share/custom API/export logs/provider contracts (enum exists, unwired); plain connect button (no canvas animation).

## 7. Web vs macOS

**Architecture:** `/app` React subtree (desktop = macOS-style sidebar, mobile = iOS-style tab bar); three planes — REST (account), browser-extension bridge (`chrome.proxy` data plane), hosted `DeviceLocal` controlled via ~40MB wasm SDK over device-rpc websocket.

**Account plane: essentially complete parity** — account root, profile (richer identity list), settings subset, wallets (set-payout/remove/history), balance codes, blocked locations, leaderboard, support, reliability, provider stats, contract stacks (full port at `/app/contracts`).

**Gaps (device-plane editors cluster):**
1. Split rules — absent entirely (0 refs).
2. DNS editor — read-only summary card; `useDns().save` bound-unused (`ConnectStats.jsx`).
3. Block-ads toggle + counts — `useBlockActions`/`deviceSetBlockerEnabled` bound, **no UI**.
4. Connect options (mode/Fixed-IP/Strong-Anonymization) stored as intent-only; needs `setPerformanceProfile` wasm binding (`Connect.jsx:163-172`).
5. Insufficient-balance state — absent (needs `contractStatus` binding).
6. Regional DNS pill dormant — `getRecommendedDnsResolverSettings` unbound in wasm (`deviceStore.js:236`).
7. Device rename + spec + client-ID copy — absent (`useDevices` bound-unused).
8. Account points/rewards breakdown + Seeker multiplier + unpaid-provided figure — absent.
9. Transfer chart is a single down/up chart, not the native Remote+Blocked+Local card set.

**Web-only:** Proxies screen (HTTPS/SOCKS5/WireGuard client creation), Manage Subscription screen (cross-store cancel routing), Stripe rail + customer portal, Operator Client UI launcher, Solana desktop login, responsive mobile layout, 6-language i18n.

**Intentional web-inherent absences (not gaps):** local tunnel/reconnect, provide mode, guest mode (dropped), notifications, launch-at-startup, log attach.

---

## Cross-cutting matrices

Login methods (✓ present · ✗ missing · ◐ partial):

| Method | iOS | Android | macOS | Windows | Linux | Web |
|---|---|---|---|---|---|---|
| Email/password | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Apple | ✓ | ✗ | ✓ | ✗ | ✗ | ✓ |
| Google | ✓ | ◐ flavor | ✓ | ✗ | ✗ | ✓ |
| Solana | ✓ | ✓ | **✗ (removed)** | ✓ | ✓ | ✓ |
| Bittensor | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Guest | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ (dropped) |
| Auth code | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

Key surfaces:

| Surface | iOS | Android | macOS | Windows | Linux | Web |
|---|---|---|---|---|---|---|
| Connect + stats sheets (contracts/split/DNS) | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ (contracts only) |
| Onboarding funnel | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ |
| Provide control (mode) | ✓ | ✓ | ✓ | ✗ | ◐ bool | n/a |
| Account/Settings tree | ✓ | ✓ | ✓ | ◐ | ✗ | ✓ |
| Wallets/points/reliability | ✓ | ✓ | ✓ | ◐ | ✗ | ◐ (no points) |
| Leaderboard + Support | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ |
| Per-app split tunnel | n/a | ✓ | n/a | ✓ | ✗ | n/a |
| Large-screen layout | ✗ | ◐ | ✓ | ✓ | ✓ | ✓ |
| Compiled & runtime-verified | ✓ | ✓ | ✓ | **✗** | **✗** | ✓ |

---

## Prioritized worklist

**P0 — small, high-visibility, or decisions:**
1. iOS+Android large-screen pass, phase 1 (mechanical): width caps on the uncapped screens (iPad D3-D6; Android gap #11), scalable connect canvas (both), drawer/sheet width caps (both). Same-change-both-repos, like the stats-UI mirroring.
2. Fix size detection bugs: iOS login orientation seed (D8 → size class), Android `isTablet()` portrait miss.
3. **Decide:** re-add Solana login on macOS via the bridge (it was removed when the bridge didn't exist; now it does and macOS is the only holdout).
4. Web: wire the already-bound block-ads toggle; then the DNS editor (`save` is bound); fix `APP.md` to match reality.
5. iOS: delete or wire the dead connect-screen guest cover; port profile network-name rename from Android.

**P1 — structural parity:**
6. Windows: provide control (mode picker + tray state) + the settings tail; wallet depth (set-default/remove/payments).
7. Linux: the Account half (settings form first: rename/copy-ID/blocked locations/delete account), provide mode picker, 4-state tray.
8. Android: quick-settings tile (only platform with no OS-level connect affordance); consider universal-link parity on iOS (`ur.io/c` associated domain) and unify deep-link schemes (`ur://` vs `urnetwork://`).
9. Web: split rules port, `setPerformanceProfile` + `contractStatus` + `getRecommendedDnsResolverSettings` wasm bindings, device rename/client-ID.

**P2 — longer arc:**
10. Compile + runtime-verify Windows and Linux (toolchain blockers: MSVC/WinUI build host; Ubuntu GTK4 box; `llvm-mingw` + `zig` for SDK artifacts per `NEXTSTEPS2.md` appendix).
11. iPad/tablet phase 2: adaptive nav (sidebar/rail on iOS regular width; Android already has rail), two-pane provider/account layouts, Stage-Manager-aware sizing.
12. Onboarding funnel on Windows/Linux; points/rewards breakdown on Windows/Linux/Web.
13. Align celebratory-overlay / error-screen UX between iOS and Android (Android's overlay system + API-error screen vs iOS sheets/snackbars).
