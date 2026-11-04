# DESKTOP2 — macOS functionality additions (iOS parity)

Goal: make the **macOS app a superset of iOS** — every iOS user flow available on
macOS, while keeping the macOS-native desktop layout (`NavigationSplitView`,
inline provider side-panel, menu-bar extra).

## Architecture context

The only platform-split files are the navigation roots
(`iOS/Navigation/MainTabView.swift`, `mac0S/Navigation/MainNavigationSplitView.swift`)
plus two pairs (`ConnectView-iOS/-macOS`, `SettingsForm-iOS/-macOS`). Everything
else is shared SwiftUI, gated by ~110 `#if os(...)` blocks (most are trivial
platform-API/layout shims). Account, Leaderboard, and Support already render the
identical shared views on both platforms, and subscribe + redeem-balance-code
were already reachable on macOS via `AccountRootView`. So the parity work is a
focused set of additions, listed below.

## Additions implemented

### 1. Onboarding / Introduction flow
Previously disabled on macOS (`displayIntroduction` hard-coded `false`, cover
commented out). Now the full funnel runs on macOS.
- `mac0S/Navigation/MainNavigationSplitView.swift`: presents `IntroductionView`
  (welcome → plan/paywall → participate-to-earn → refer) via `.sheet` with the
  required environment objects re-injected and a `minWidth/minHeight`; gating
  mirrors iOS (`isPro` / `introductionComplete`).
- `Main/MainView.swift`: threads `introductionComplete` into the macOS root.
- `Main/Connect/ConnectView-macOS.swift`: "get more data" (`promptMoreDataFlow`)
  now opens the Introduction flow (like iOS) instead of jumping to the upgrade
  sheet.

### 2. Guest mode
- `Authenticate/LoginInitial/LoginInitialView.swift`: the **"Try Guest Mode"**
  login entry (with `GuestModeSheet`) is now shown on macOS (was `#if os(iOS)`).
- `Main/Account/AccountRootView.swift` (macOS branch): guests can **upgrade to a
  full account** via a `.sheet` → `LoginNavigationView` (parity with the iOS
  create-account cover), wired through `handleSuccessWithJwt`.

### 3. Account menu (logout / referral / create account)
- `Main/Account/AccountRootView.swift` (macOS branch): added the shared
  `AccountMenu` to the toolbar. This surfaces **logout on macOS for the first
  time** (macOS previously had only a refresh button), plus the referral share
  link and the "create account" action.

### 4. Copy client ID
- `Shared/Views/Stats/ContractDetailsView.swift`: the "Copy client ID"
  context menu (right-click) now works on macOS (was `#if os(iOS)`).

### 5. Contract-details circle animation parity
- `Shared/Views/Stats/ContractDetailsView.swift` (`ContractPairViz`): the
  contract-circle swap (replaced contract slides out + fades, new fades in) and
  the 0.5s disc-growth now match the corrected Android behavior on iOS/macOS
  (each circle wrapped in a fixed `ZStack` so the swap overlaps cleanly).

## Implemented — Solana desktop wallet integration

**App-side (macOS), all built:**
- `Shared/ViewModels/ConnectWalletProviderViewModel.swift`: on macOS,
  `openURL` now rewrites the Phantom/Solflare universal link into
  `https://ur.io/wallet-connect?method=…&provider=…&<original params>` and opens
  it in the browser (`webConnectURL(from:)`); `isWalletAppInstalled` returns
  `true` on macOS (the web bridge detects the extension). The crypto/callback
  parsing is unchanged.
- `Authenticate/LoginInitial/LoginInitialView.swift`: the macOS "Sign in with
  Solana" button is enabled.
- `Main/Account/Wallets/WalletsView.swift`: the macOS Connect-wallet sheet now
  shows the full `ConnectWalletNavigationStack` (Phantom/Solflare deeplink +
  manual entry) instead of manual-entry only.

**Web bridge, built:** `mmm/ur.io/astro/src/pages/wallet-connect.astro` — a
standalone page that drives the Phantom/Solflare **browser extension**
(`connect` / `signMessage`) and redirects back into the app via
`urnetwork://…` using the **identical NaCl-box envelope** the app already
decodes (tweetnacl `box.before/after` ↔ the Go SDK's
`box.Precompute/SealAfterPrecomputation`; ephemeral web keypair persisted in
`localStorage` so the connect→sign hops share a secret).

The crypto libs are **bundled** (not CDN): `tweetnacl` + `bs58` are deps of
`ur-react`, the flow lives in `react/src/components/WalletConnect.jsx`, and the
Astro page mounts it as a `client:only` island (`@ur/components/WalletConnect.jsx`),
so Vite bundles them into the page chunk.

**Remaining for Solana:** deploy the page to `ur.io/wallet-connect` and test the
round-trip with a real Phantom/Solflare extension (the one part only on-device
testing can confirm).

### `ur.io/wallet-connect` route reference

- **Route:** `GET https://ur.io/wallet-connect`
- **Source:** `mmm/ur.io/astro/src/pages/wallet-connect.astro` → mounts the
  `client:only` React island `mmm/ur.io/react/src/components/WalletConnect.jsx`
  (tweetnacl + bs58 bundled from `ur-react` deps).
- **Opened by:** the macOS app — `ConnectWalletProviderViewModel.openURL` calls
  `webConnectURL(from:)`, which rewrites a Phantom/Solflare universal link
  (`https://phantom.app/ul/v1/{connect|signMessage}?…`) into this route,
  preserving the original query and adding `method` + `provider`.

**Request query params**

| param | when | value |
|---|---|---|
| `method` | always | `connect` \| `signMessage` |
| `provider` | always | `phantom` \| `solflare` |
| `dapp_encryption_public_key` | always | base58 Curve25519 pubkey (app's ephemeral key) |
| `redirect_link` | always | `urnetwork://{provider}-connect` or `urnetwork://{provider}-sign-message` |
| `cluster` | always | `mainnet-beta` |
| `app_url` | connect | app metadata URL (`https://ur.io`) |
| `nonce` | signMessage | base58 nonce |
| `payload` | signMessage | base58 NaCl-box-encrypted `{ message(base58), session, display:"utf8" }` |

**What the page does:** resolves `window.phantom?.solana` / `window.solflare`.
For `connect` it calls `.connect()`, generates an ephemeral web Curve25519
keypair (persisted in `localStorage` keyed by `dapp_encryption_public_key`), and
box-encrypts `{ public_key, session }`. For `signMessage` it reloads that web
keypair, decrypts `payload` to recover the message, calls
`.signMessage(bytes, "utf8")`, and box-encrypts `{ signature }`.

**Response — redirect to `redirect_link` with:**

| outcome | params appended to `redirect_link` |
|---|---|
| connect success | `{provider}_encryption_public_key=<base58 web pubkey>`, `nonce=<base58>`, `data=<base58 box{public_key, session}>` |
| signMessage success | `nonce=<base58>`, `data=<base58 box{signature}>` |
| error / rejection | `errorCode=-1`, `errorMessage=<text>` |

The app receives this via `.onOpenURL` and parses it with the **unchanged**
`handleConnect` / `handleSignMessage` (`ConnectWalletProviderViewModel.swift`).

- **Crypto:** NaCl box (Curve25519-XSalsa20-Poly1305). tweetnacl
  `box.before`/`box.after`/`box.open.after` are wire-compatible with the Go SDK's
  `SdkGenerateSharedSecret` / `SdkEncryptData` / `SdkDecryptData`
  (`box.Precompute` / `SealAfterPrecomputation` / `OpenAfterPrecomputation`);
  base58 via bs58 ↔ `SdkEncodeBase58` / `SdkDecodeBase58`.
- **Notes:** the page is `noindex`; because browsers may block automatic
  navigation to the `urnetwork://` scheme, it also surfaces a manual **"Return to
  URnetwork"** link carrying the same callback URL. The `urnetwork://` scheme is
  registered in the shared `apple/app/URnetwork-Info.plist`.

<!-- superseded section retained below for history -->
## (superseded) In progress / blocked

### Solana desktop wallet integration
Native-macOS equivalents of the iOS **Sign-in-with-Solana** and
**external-wallet-connect** flows.

**How iOS works today:** everything runs through `ConnectWalletProviderViewModel`
(`Shared/ViewModels/`), which builds Phantom/Solflare mobile universal links
(`https://phantom.app/ul/v1/connect|signMessage`), the wallet app performs the op
and redirects back into the app via the `urnetwork://` custom scheme with a
**NaCl-box (Curve25519-XSalsa20-Poly1305) encrypted payload**. The crypto and the
`.onOpenURL` callback handlers (`LoginInitialView`, `WalletsView`) and the backend
calls (`authLogin`/`createAccountWallet` via `SdkWalletAuthArgs`) are **already
cross-platform** (gomobile SDK + the `urnetwork://` scheme in the shared
Info.plist). Only the "open the wallet" step and the `isWalletAppInstalled`
gating are mobile-specific.

**macOS problem:** Phantom/Solflare on desktop are **browser extensions**, not
URL-scheme apps — they don't claim `phantom://`/the universal links, so the
existing deeplink transport dead-ends and every connect/sign button is
`.disabled`.

**Plan (approach: hosted web connect page + `urnetwork://` callback):**
- *App-side (doable here):* enable the macOS Sign-in-with-Solana button and the
  Wallets deeplink-connect option, wire the Solana sheet + `.onOpenURL` into the
  macOS Settings branch, drop the desktop `isWalletAppInstalled` gating, and swap
  the "open Phantom mobile link" step for "open a hosted web connect page in the
  browser." Because the returned envelope is identical, `handleConnect` /
  `handleSignMessage` and the callback handlers work **unchanged**.
- *Server-side (external dependency — NOT in this repo):* a small hosted dapp
  (e.g. `https://ur.io/wallet-connect`) using `@solana/wallet-adapter` +
  `tweetnacl` that talks to the browser extension, encrypts the response with the
  app's dapp Curve25519 pubkey, and redirects to
  `urnetwork://…?data=…&nonce=…&…_encryption_public_key=…`.

**Status: the app-side changes are ready to implement; they require the hosted
web page to actually function end-to-end.** Alternative that avoids a web page:
add a WalletConnect Swift SDK (heaviest; reuses only the backend layer).

## Remaining

Nothing outstanding on the iOS→macOS parity list. The only open item is the
Solana **deploy + real-wallet test** noted above. (The in-app rating prompt and
the blocked-location country search were the last two small items and are now
done — see additions 6/7.)

### 6. In-app rating prompt (macOS)
- `Main/Connect/ConnectView-macOS.swift`: `onAppear` now wires
  `connectViewModel.requestReview` (gated on `getShouldShowRatingDialog()`),
  mirroring iOS — the review prompt fires on macOS instead of never.

### 7. Blocked-location country search (macOS)
- `Main/Account/BlockedLocations/BlockedLocationsView.swift`: the macOS
  add-blocked-location sheet now has a search field bound to
  `viewModel.searchCountry` (the iOS `.searchable` equivalent).

## Kept as macOS-unique (desktop-native, no iOS equivalent)

- Menu-bar extra (status + Connect/Disconnect/Show/Quit) and "Quit URnetwork".
- "Launch at startup" setting.
- Inline provider-list side panel + toolbar toggle (vs the iOS modal sheet).
- Disconnect/reconnect around an App Store purchase (the Mac App Store build;
  the direct download buys with the connection as it is).

## Excluded by decision

- **Seeker multiplier** (Solana Seeker phone) — being removed in a future change;
  not ported.
- **"Allow providing on cellular"** — meaningless on desktop (no cellular);
  intentionally omitted.
