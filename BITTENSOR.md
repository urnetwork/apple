# BITTENSOR — "Sign in with Bittensor" & "Connect Bittensor Wallet" feasibility

**Status: EVALUATION ONLY — no code written. Awaiting a go/no-go and the four
decisions in [Open questions](#open-questions).**

> **Update 2026-11-13.** The USDC payout rails this evaluation describes (gap 8,
> open question 3) are history. Provider earnings have been paid in SN25α to a
> Bittensor coldkey since 2026-10-06, and USDC provider payouts ended on
> 2026-11-12. On 2026-11-13 the owner closed USDC out, and the Apple app's last
> USDC payout surfaces were removed: Connect Solana wallet, the Solana wallet
> card and the final USDC payout line.

Goal evaluated: add **"Sign in with Bittensor"** (wallet auth login) and
**"Connect Bittensor Wallet"** (external wallet) to the URnetwork iOS and Android
apps, using the **Tao.com app** as the wallet — mirroring the existing Solana
(Phantom/Solflare) integration.

---

## Bottom line

The app-side wiring is a straightforward extension of the existing Solana
pattern, but there are **two hard blockers** — one external, one internal:

1. **The Tao.com app exposes no third-party connect protocol.** No documented
   deep link, URL scheme, WalletConnect, or SDK was found. You cannot drive it
   the way iOS drives Phantom/Solflare today.
2. **The URnetwork backend cannot verify sr25519 signatures.** `VerifySignature`
   only handles Solana (ed25519) and Ethereum (secp256k1); Bittensor returns
   `unsupported blockchain`, and there is no substrate crypto dependency.

Both are solvable, but (1) pushes toward a **wallet-agnostic WalletConnect-v2 /
web-bridge approach** (any Bittensor wallet) rather than a Tao.com-specific deep
link, and (2) is a **mandatory backend + SDK change** — this is not app-only
work like the macOS parity effort.

---

## (a) What the Tao.com app can actually do

- **Identity**: "TAO.com: Bittensor wallet," App Store id `6476235156`, seller
  Ark Technology Labs LLC / © Tensora Opco Limited — "the first native iOS mobile
  app and non-custodial wallet for Bittensor and TAO" (send/receive/stake/trade
  subnet tokens, MEV Shield).
- **Platforms**: App Store lists **iOS only** (iOS 16+). Marketing says "all
  major platforms" but **no Android build and no browser extension** are
  confirmed.
- **Developer surface**: **none found** — no deep link, URL scheme, WalletConnect,
  signMessage API, or SDK/docs. It is a **consumer wallet, not an integrable
  one**, as of this research.
- **Ecosystem contrast**: other Bittensor wallets **do** support third-party
  connect — **Nova** and **Nightly** (iOS+Android) via **WalletConnect**, and the
  Bittensor browser extension supports dApp auth. The pattern exists; the Tao.com
  app just doesn't publish it.

**Implication:** using the Tao.com app *specifically* (à la Phantom app-to-app)
is **not possible today** without Tensora publishing a connect API. A shipping
solution should be **wallet-agnostic** (any WalletConnect-capable Bittensor
wallet) and treat Tao.com support as best-effort/pending.

## Bittensor signing model

- Substrate-based; accounts are **sr25519** with **ss58** addresses (not raw
  base58 pubkeys like Solana).
- Standard signing = polkadot-js **`signRaw`** (`type: 'bytes'`); verification =
  `signatureVerify` (schnorrkel). **Gotchas:** signers wrap the payload in
  `<Bytes>…</Bytes>` before signing, and **sr25519 signatures are
  non-deterministic**.
- Established **"Sign in with Bittensor"** pattern exists (challenge =
  `{hotkey}:{timestamp}:{nonce}`, `signRaw`, server re-verifies with replay
  protection) — e.g. taostats "Bittensor Auth," ORO-AI/bittensor-auth. **Maps
  cleanly onto URnetwork's existing server nonce flow.**
- **Go verification is available**: **`ChainSafe/go-schnorrkel`** (pure-Go
  sr25519, audited, Substrate-interoperable); ss58 decode via
  `vedhavyas/go-subkey`.
- Industry-standard mobile handshake = **WalletConnect v2, Polkadot namespace**:
  methods `polkadot_signMessage` / `polkadot_signTransaction`, account id
  `polkadot:<genesisPrefix>:<address>`; the dApp receives **address + signature**.
  SDKs: Reown/WalletConnect Polkadot guide, `paritytech/polkadot-onboard`,
  `Koniverse/SubConnect-v2`.

## How the existing URnetwork flows work (ground truth)

- **iOS connect/sign** — `apple/app/network/Shared/ViewModels/ConnectWalletProviderViewModel.swift`:
  deep-links Phantom/Solflare universal links with a Curve25519-ECDH encrypted
  envelope (`SdkEncryptData`/`SdkDecryptData`/`SdkGenerateSharedSecret`), returns
  via `urnetwork://phantom-connect` etc. `ConnectedWalletProvider` = `.phantom |
  .solflare`. **The macOS variant already adds a web bridge** (`webConnectURL(...)`
  → `https://ur.io/wallet-connect?...`), which is the reusable pattern here.
- **iOS sign-in args** — `Authenticate/LoginInitial/LoginInitialViewModel.swift:263`:
  `SdkWalletAuthArgs{ blockchain = SdkSOL, message, signature, publicKey }` →
  `authLogin`.
- **iOS add-wallet args** — `Shared/ViewModels/AccountWalletsViewModel.swift:318`:
  `SdkCreateAccountWalletArgs{ blockchain, walletAddress }` → `createAccountWallet`.
- **iOS URL registration** — `apple/app/URnetwork-Info.plist`: `CFBundleURLSchemes
  = urnetwork`; `LSApplicationQueriesSchemes = solflare, phantom`.
- **SDK blockchain enum** — `sdk/api.go:748-756`: `type Blockchain = string`;
  **only** `SOL` and `MATIC`. `sdk/wallet_view_controller.go:278`
  (`AddExternalWallet`) **hard-rejects** anything except SOL/MATIC.
- **Server verification** — `server/model/auth_model.go`: `handleLoginWallet`
  (:453) already binds a **server-issued single-use nonce** into the signed
  message (SIWE-equivalent), then `VerifySignature` (:593): `sol` → ed25519,
  `eth|matic|poly` → secp256k1, **else → `unsupported blockchain`**. `server/go.mod`
  has only `go-ethereum` + `solana-go` (no schnorrkel/subkey).
- **Android** — `android/app/app/src/...`: Solana connect uses the **Solana
  Mobile Wallet Adapter** (`com.solana.mobilewalletadapter.*`), Solana-only, a
  **fundamentally different mechanism** than iOS. **No deep-link envelope flow and
  no WalletConnect client exist today.**

## (b) Recommended approach

Because Tao.com publishes no connect API, use a **wallet-agnostic WalletConnect-v2
flow delivered through the existing `ur.io/wallet-connect` web bridge**, uniform
on iOS, Android, and macOS. This reuses the return-envelope plumbing already
built for macOS and sidesteps the missing Tao.com deep link.

**"Sign in with Bittensor" (authLogin):**
1. App requests a nonce (`AuthWalletNonceCreate`) and builds a SIWE-style message
   embedding it.
2. App opens `https://ur.io/wallet-connect?method=signMessage&provider=bittensor&message=…&nonce=…`.
   The page runs a **WalletConnect v2 Polkadot dApp client** (QR + mobile
   deep-link); the user approves in **any WC-capable Bittensor wallet** (Nova /
   Nightly today; Tao.com if/when it adds WC) via `polkadot_signMessage`.
3. Page returns `urnetwork://…?address=<ss58>&signature=<hex>` — same envelope
   shape as Solana.
4. App builds `SdkWalletAuthArgs{ blockchain: "TAO", message, signature,
   publicKey: ss58 }` → `authLogin`. Server verifies sr25519 (new branch) and
   consumes the nonce. The nonce/replay machinery already exists.

**"Connect Bittensor Wallet" (createAccountWallet):**
- Same WC handshake to obtain the ss58 address (a `signMessage` proves
  ownership); `SdkCreateAccountWalletArgs{ blockchain: "TAO", walletAddress: ss58 }`.
- Requires the SDK to accept `"TAO"` + ss58 validation. DB already allows it
  (`blockchain varchar(32)`, `UNIQUE(wallet_address, blockchain)`).

**Per platform:**
- **iOS**: add `ConnectedWalletProvider.bittensor` and route it through the web
  bridge (reuse the macOS `webConnectURL` path on iOS too, since there's no Tao
  deep link). No Curve25519 envelope needed on the WC path.
- **Android**: **net-new** — open the same `ur.io/wallet-connect` bridge in a
  Chrome Custom Tab returning to an `urnetwork://` intent filter. Avoids adding a
  native WalletConnect SDK and matches iOS 1:1.

**Alternative if Tensora cooperates:** if Tao.com adds either a WalletConnect
wallet-side or a Phantom-style `tao://` deep-link + signMessage API, option two
mirrors `ConnectWalletProviderViewModel` almost verbatim (new provider, add `tao`
to `LSApplicationQueriesSchemes`). Cleaner UX, but **depends entirely on an
external party** and is unavailable today.

## (c) Gaps

| # | Gap | Where | Severity |
|---|-----|-------|----------|
| 1 | Tao.com app has no connect protocol (deep link / scheme / WalletConnect / SDK) | External (Tensora) | **Blocker** for Tao-specific; mitigated by WC-agnostic approach |
| 2 | Server can't verify sr25519 — `VerifySignature` → `unsupported blockchain`; no substrate crypto dep | `server/model/auth_model.go:593`, `server/go.mod` | **Blocker** — add `VerifyBittensorSignature` + `go-schnorrkel` + ss58 decode |
| 3 | SDK blockchain enum lacks Bittensor; `AddExternalWallet` rejects non-SOL/MATIC | `sdk/api.go:748`, `sdk/wallet_view_controller.go:278` | Required — add `TAO` const + validation |
| 4 | sr25519 subtleties: `<Bytes>…</Bytes>` wrapping, signing-context/transcript must match, ss58 ≠ raw pubkey | server verify impl | Medium — differential test vs polkadot-js |
| 5 | iOS provider enum + bridge only knows phantom/solflare; envelope assumes Solana wallets | `ConnectWalletProviderViewModel.swift`, `URnetwork-Info.plist` | Medium — add `.bittensor` + WC/web-bridge path |
| 6 | Android has no deep-link/WalletConnect flow at all — only Solana MWA | `android/app/app/src/...` | **Large** — net-new |
| 7 | `ur.io/wallet-connect` bridge only handles Phantom/Solflare methods | web (`ur.io`) | Medium — add a Polkadot/WC provider |
| 8 | Payout rails (Circle USDC Sol/Polygon) don't support TAO addresses | `server/controller/circle_wallet_controller.go` | Product decision — "connect" may be storage-only |
| 9 | gomobile crypto helpers are Solana/Curve25519-oriented | `sdk` | Low/Medium — verification is server-side, so the app may need no new client crypto on the WC path |

## <a id="open-questions"></a>Open questions (decisions needed before building)

1. **Tao.com specifically, or any Bittensor wallet?** If it must literally be the
   Tao.com app, the project is **blocked on Tensora** publishing an API. If any
   Bittensor wallet is acceptable, the WalletConnect path is buildable now.
2. **Is backend + SDK work in scope?** This needs server sr25519 verification and
   an SDK enum bump — not app-only.
3. **What does "Connect Bittensor Wallet" mean for payouts?** Payouts run through
   Circle **USDC on Solana/Polygon**; a Bittensor address isn't a payable
   destination, so "connect" would be **proof-of-ownership / address storage
   only** unless there's a TAO-payout plan.
4. **Android now or iOS-first?** Android is net-new (no WC/deep-link scaffold) vs
   iOS reusing the bridge.

## (d) Rough effort (recommended WC / web-bridge approach)

- **Backend sr25519 verify** (gaps 2, 4): `VerifyBittensorSignature` +
  `go-schnorrkel` + ss58 decode + `<Bytes>` handling + `"TAO"` case + differential
  tests. **~3–5 days** (crypto correctness is the risk; nonce/replay flow exists).
- **SDK enum + validation** (gap 3): `Blockchain` const, acceptance, ss58
  validation, regenerate cgo/gomobile bindings. **~1–2 days.**
- **`ur.io/wallet-connect` Polkadot WC provider** (gap 7): connect +
  `polkadot_signMessage` → `urnetwork://` envelope. **~3–5 days** (separate web
  repo).
- **iOS** (gap 5): `.bittensor` provider, web-bridge route, deep-link return,
  sign-in + connect UI. **~3–4 days.**
- **Android** (gap 6): net-new connect flow (Custom Tab → `urnetwork://` intent
  filter reusing the bridge), sign-in + connect UI, wire the auth/wallet args.
  **~5–8 days.**

**Total (excluding Tao.com cooperation & QA): ~3–4 engineer-weeks**, with backend
sr25519 and Android parity the largest/riskiest items. If the requirement is
*literally* the Tao.com app driving the handshake, the project is **blocked on an
external dependency** until Tensora ships an integration surface.

## Sources

- TAO.com wallet — App Store `id6476235156` · https://www.tao.com/
- Nightly (Bittensor, WalletConnect, iOS+Android) · Nova Wallet
- Bittensor wallets/keys docs (docs.learnbittensor.org)
- polkadot{.js} sign & verify; util-crypto verify-signature
- taostats "Bittensor Auth"; ORO-AI/bittensor-auth
- WalletConnect v2 namespaces spec; Reown Polkadot wallet-integration guide;
  paritytech/polkadot-onboard; Koniverse/SubConnect-v2
- ChainSafe/go-schnorrkel (Go sr25519)
