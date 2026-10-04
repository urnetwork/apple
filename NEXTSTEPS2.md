# NEXTSTEPS2 — configuration to finish the Bittensor / wallet sign in
#### (and, at the end, the Stripe checkout config)

Follow-up to [BITTENSOR.md](BITTENSOR.md). The code is built and compiling across
`server`, `sdk`, `android`, `apple`, and `mmm/ur.io`. What remains is **configuration**:
one WalletConnect project id in three config files, three deploys in order, and a
short QA pass over four values that could not be verified from the repo.

Nothing below blocks a build. Every unset value degrades gracefully (see
[If the project id is left empty](#if-the-project-id-is-left-empty)).

---

## 1. WalletConnect Cloud project id

One project id is shared by all clients.

**Create it:** a project at the WalletConnect / Reown Cloud dashboard →
copy the **Project ID**. In the project settings:

- Name: `URnetwork`, URL: `https://ur.io`, icon: the ur.io favicon
  (this metadata is what the wallet shows on the approval screen — the clients
  already send the same values, so keep them consistent).
- Allowed domains / origins: `ur.io` (add `localhost` for local dev of the web ui).

**Then set it in three places.** All three are placeholders today.

### Android — `android/app/local.properties`

```properties
WALLETCONNECT_PROJECT_ID=<project id>
```

Surfaces as `BuildConfig.WALLETCONNECT_PROJECT_ID` (wired in `app/app/build.gradle`
next to `BUNDLER_RPC_URL`), and is passed to the bridge as `wc_project_id` by
`ui/login/LoginUtils.kt`. Gradle prints a warning when it is unset.

> `local.properties` is **not** in version control — it must also be set on the
> build machine / CI, the same way `BUNDLER_RPC_URL` is.

### Apple — `apple/app/URnetwork-Info.plist`

```xml
<key>URWalletConnectProjectId</key>
<string><project id></string>
```

Set (from `vault/main/walletconnect.yml`). Read by `BittensorWallet.walletConnectProjectId`
(`app/network/Shared/Bittensor/BittensorWalletConnector.swift`). When the user picks the
**WalletConnect** Bittensor wallet (Nova, Nightly, ...), the connector hands it to the SDK
session (`setWalletConnectProjectId`), which sends it to `https://ur.io/bittensor-connect`
as `wc_project_id` together with `wallet=walletconnect`. It is used on iOS and macOS alike.
The Talisman and TAO.com wallets never send it.

### Web + bridge — `mmm/ur.io` build environment

```sh
PUBLIC_WALLETCONNECT_PROJECT_ID=<project id>
```

**`PUBLIC_`, not `VITE_`** — production is built by Astro, whose `envPrefix` is
`PUBLIC_`, so a `VITE_*` variable never reaches the bundle (this is also why the
other client config there — `PUBLIC_SOLANA_MERCHANT`, `PUBLIC_SOLANA_USDC_MINT` —
uses that prefix). A WalletConnect project id is a public client identifier meant
to ship in the browser bundle, so `PUBLIC_` is correct on its own merits too.
There is no `.env` file in the repo today — set it in the build environment, or
add `mmm/ur.io/react/.env`. It is read by **both**:

- `react/src/components/BittensorConnect.jsx` — the `/bittensor-connect` bridge
  the native apps open for Bittensor (`/wallet-connect?provider=bittensor` routes
  there too, for older app versions). Precedence: the `wc_project_id` query param
  the app sends **wins**; this env var is the fallback.
- `react/src/auth/walletAuth.js` — the web ui's own "Continue with Bittensor" /
  "Continue with Solana" buttons in the login dialog.

The astro site imports these from `react/src` (`@ur` alias), so one value covers
both builds.

### If the project id is left empty

No crash and no dead buttons — wallet sign in simply falls back to **injected
wallets only**:

| surface | with a project id | without |
|---|---|---|
| web login dialog (desktop) | extension, else QR | extension only |
| web login dialog (mobile) | wallet app deep link | *no wallet path* |
| app sign in → bridge (desktop) | extension, else QR | extension only |
| app sign in → bridge (mobile) | wallet app deep link | wallet's in-app browser only |

Desktop users with an extension (Phantom/Solflare; Bittensor Wallet, SubWallet,
Talisman, polkadot-js) work either way. **Mobile wallet pairing is the thing the
project id buys.**

---

## 2. Deploy order

1. **`server`** — sr25519 verification + the `TAO` blockchain. Must be live
   **before** any client that can produce a Bittensor login, or those logins fail
   with `unsupported blockchain`. No DB migration is needed (`blockchain
   varchar(32)` already fits `TAO`).
2. **`mmm/ur.io`** — the `/wallet-connect` bridge (bittensor provider +
   WalletConnect) and the web login dialog. The shipped apps point at
   `https://ur.io/wallet-connect`, so the site must be redeployed before app
   releases reach users.
3. **`android` / `apple`** releases, built against the rebuilt SDK artifacts
   (already regenerated locally: `.aar`, `.xcframework`, cgo headers).

---

## 3. Verify in QA (four values written from spec, not from this repo)

Each is isolated as a named constant with a comment. If a wallet rejects the
session proposal or the server rejects a signature, start here.

| # | value | where |
|---|---|---|
| 1 | Bittensor CAIP chain id `polkadot:2f0555cc76fc2840a25a6ea3b9637146` (first 32 hex of the finney genesis hash) | `react/src/components/WalletConnect.jsx`, `react/src/auth/walletAuth.js` |
| 2 | Solana CAIP chain id `solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp` (mainnet-beta) | `react/src/auth/walletAuth.js` |
| 3 | WalletConnect Solana signature is base58 → decoded to base64 for the server | `react/src/auth/walletAuth.js` (`signInWithSolana`) |
| 4 | **One real-wallet signature end to end.** sr25519 is verified round-trip against `go-schnorrkel`, but not yet cross-implementation. Sign in once with a real wallet (Bittensor Wallet extension, polkadot-js, or a WalletConnect wallet) and confirm the server accepts it. | `server/model/auth_bittensor.go` |

The injected-wallet path touches neither chain id — that is the common desktop
case, and it exercises the server verification the same way.

---

## 4. Behavior worth knowing before QA

- **Signed message**: all clients sign the static `"Welcome to URnetwork"`, the
  same string the Solana flow already signs. No client sends a nonce; the server
  only enforces one *when present* (`handleLoginWallet`). If nonce presence is
  ever made mandatory, every wallet client must be updated together.
- **Bittensor wallets are storage only.** They are recorded for future use and
  can never be the payout wallet: the apps hide "Make default", and the server
  rejects it in `SetPayoutWallet` **and** skips the auto-set-first-wallet-as-default
  on wallet creation. A Bittensor *signup* also creates no payout wallet
  (`NetworkCreate` only auto-creates one for `SOL`/`MATIC`).
- **Connect wallet** for Bittensor is paste-an-address (ss58, checksum-validated
  server side) — no signature, per the decision in BITTENSOR.md.
- **Sign-up parity**: an unlinked wallet routes to create-network with the wallet
  on every client, including the web dialog (which swaps the email/password
  fields for the connected wallet's address).

---

## 5. Stripe checkout (the non-Apple upgrade path)

`POST /stripe/create-checkout-session` now takes a `ui_mode`:

- **`hosted`** (default, back-compatible) → returns `checkout_url` for the system browser. This is what the website already uses.
- **`embedded`** → returns `client_secret` + `publishable_key`, for **inline** checkout: the desktop apps load `https://ur.io/checkout?client_secret=<cs>&redirect_link=urnetwork://…` in an embedded webview (WebView2 / WebKitGTK). On completion the page returns `urnetwork://…?status=complete&session_id=…`, and the app polls the subscription balance.

A single Stripe Checkout Session **cannot** return both a `client_secret` and a `url` — the two are mutually exclusive by `ui_mode` — so the caller picks the mode. Note embedded checkout has **no cancel URL** (the customer never leaves the page), so the app must provide its own close affordance.

The subscription is granted by the **`invoice.paid` webhook**, never by the client. The client only polls afterwards.

### Config to fill in

```yaml
# config/<env>/stripe.yml   (the config repo — outside android/apple/server)
checkout:
  return_url: "https://ur.io/checkout?complete=1&session_id={CHECKOUT_SESSION_ID}"   # NEW, required for embedded
```

```sh
# mmm/ur.io build environment
PUBLIC_STRIPE_PUBLISHABLE_KEY=pk_live_…      # pk_test_… on canary
```

Both are optional-but-degrading: without `return_url`, embedded mode refuses cleanly ("Checkout is not configured") instead of stranding someone mid-payment in a webview; without the publishable key the build warns and `/checkout` says the same. A **malformed** key fails the build on purpose.

---

## Appendix — unrelated build config still outstanding

Not part of Bittensor, but needed to ship the desktop SDK artifacts (the cgo
header already exports `TAO`):

- **windows/arm64** SDK dll — needs `llvm-mingw` on the build host
  (`x86_64` builds today with the installed mingw-w64).
- **linux** SDK `.so` — needs `zig` (`sdk/cgo/Makefile` pins the glibc 2.35 floor
  via `zig cc`).

Until both are installed, `make -C sdk/cgo build_windows build_linux` cannot
produce `URnetworkSdkWindows.zip` / `URnetworkSdkLinux.zip`, and the
`windows` / `linux` apps cannot link the connect-drawer work against the current
SDK.
