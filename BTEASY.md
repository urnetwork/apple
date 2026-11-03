# BTEASY: a one-tap Bittensor key for casual miners

Status: plan, not started. The [questions](#open-questions) are answered, and the build starts
with its first step.
Apple first, then the other platforms.

## Goal

A casual miner with no wallet and no TAO taps once and starts earning SN25α. The
app creates a Bittensor key on the device, signs the network's payout consent with
it, and keeps the recovery phrase until the user has saved it. URnetwork relays the
claims and pays their gas.

Two promises, from the owner (2026-11-02), that this plan is checked against:

1. **Setting up a wallet for all miners on your network is a single tap in the app.**
2. **Claiming Top 200 for all miners on your network is a single tap.**

"All miners" here means the one tap handles the whole network, including miners with no
app. For Top 200 the server then binds only the devices that add score, and the rest keep
earning in the pool, because binding every device would cost most of them their pool
earnings (see [What has to hold](#what-has-to-hold)). What each promise doesn't cover yet
is listed under [Where one tap stops](#where-one-tap-stops).

**URnetwork is not a wallet.** The app creates one key and signs for URnetwork's own
payout flow. It can't send funds to anyone. To transfer or use SN25α, the user enters
the recovery phrase into another wallet or btcli. The one on-chain action in the first
version is a minimal **convert SN25α to TAO**, which stays on the same key (see
[Convert](#convert-sn25α-to-tao)). A later phase adds registering for Top 200 (see
[Claiming a Top 200 spot](#claiming-a-top-200-spot)).

### Decided by the owner (2026-11-02)

- The phrase is hidden by default, with tap to reveal, a Hide button, and a Copy
  button once revealed.
- URnetwork relays claims.
- The app gets a minimal convert from SN25α to TAO, with the user choosing the amount.
- Binding opens on mainnet as its own release, with each on-chain step brought to the owner first.
- The fleet hotkey lives on the key holder's device, as a key separate from the recovery phrase.
- The Earnings card's main button is the one tap: it creates the key, saves it for later and signs.
- Headless miners get auto-signing in a `provider` release, and networks with an existing wallet
  get a path of their own.
- URnetwork relays bindings for small fleets, and a miner with no alpha gets a capped top-up
  (questions 15 and 16).
- The delete confirmation warns that deleting the key also gives up one-tap Top 200.
- The relay pays for v2 claims only, up to 0.01 TAO a day (question 1).
- Convert ships as soon as it's ready, with no limit by region (question 2).
- **Where this plan leaves something open, do what's easiest for the end user** (owner, 2026-11-03).

### Not in scope

- Importing an existing recovery phrase. We never ask a user to type one in.
- Sending or transferring funds to another address.
- Holding more than one key per network.
- Anything custodial. URnetwork's servers never see the recovery phrase or the
  private key, only the public address and signatures.
- Replacing the existing wallet paths (Talisman, WalletConnect, manual, btcli).
  They stay for people who already have a wallet.

## Does the key need gas?

**No, as far as the code shows.** A new key with no TAO can do everything in this plan.

| Step | Who signs | Who pays | Evidence |
|---|---|---|---|
| Create the key | Nobody; it's offline | Nothing | |
| Payout consent | The key | Nothing; it's not on chain | Sent to our API, like any wallet's consent |
| Claim | The relayer | URnetwork | The vault's `claim` is open to any caller, and payment "always lands on `coldkey`, so a relayer cannot redirect custody" |
| Convert to TAO, or moving alpha elsewhere | The key | **The key's own alpha** | Subtensor charges these calls in alpha when there's no TAO, and its `CheckNonce` has an explicit case for a coldkey that received stake but never held TAO |

The last row comes from Subtensor's source (main, spec 487). Mainnet runs spec 486, so
**the build's first step proves it on testnet**. Sending TAO out, once converted, uses
that TAO, from another wallet.

## What exists today

| Piece | Where | What it means here |
|---|---|---|
| Payout consent | `Earnings/NetworkConsentFlow.swift`, `NetworkConsentClient.swift`, sdk `api_sn.go` | One sr25519 signature by a coldkey, over a server-issued single-use message (300 s), pays every provider client of the network to that coldkey from the next epoch. Without it the network's earnings aren't paid. |
| Wallet proof | sdk `bittensor_wallet.go` | Apps own only the transport; the sdk decides what's signed and checks the result. `handleProof` takes the address and signature, so a local key can be one more transport. |
| Server check | server `model/auth_bittensor.go` | Verifies sr25519 (`go-schnorrkel`, context `substrate`) over the message, wrapped in `<Bytes>…</Bytes>` or bare. It checks the signature and doesn't care how the key was made. |
| Claiming | sdk `sn_claims.go`, `ClaimAlphaSheet.swift`, `ClaimLedgerSheet.swift` | Signed by the device's gas key (secp256k1, `.sn_gas_key`), **not** the coldkey. Gas is paid in TAO from that key. Alpha lands on the coldkey, as stake under the vault's escrow hotkey on the subnet. |
| Settlement v1 | sn `evm/src/STSettlementVault.sol` | Live on mainnet. A claim expires about 61 days after its epoch finalizes (8 epochs plus 1 of grace, at 7-day epochs), then the amount is carried to the operator's later epochs. |
| Settlement v2 | sn `VERSION2-FINAL.md` | The plan of record. Credit "never expires", and anyone can claim it. Not yet activated on mainnet as far as I can find. |
| Relayer code | sn `miner/claim_v2_daemon.go`, `miner/claim_daemon.go`, `evm/src/STClaimBatcher.sol` | Claim daemons with a relayer key, nonce handling and a batcher already exist, built around a miner's own accounts. |
| Seed phrase screen | `Authenticate/CreateNetworkInstant/SeedphraseDisplayView.swift` | Shows the **account login** seed phrase, which is a different secret. Good visual starting point; no capture protection. |
| Keychain | only `VPNManager.swift`, `PacketTunnelProvider.swift` | The app has no general secret store yet. |
| Screen privacy | one `.privacySensitive()` in `ApiKeysView.swift` | Nothing to reuse. |
| Logout | sdk `local_state.go` `Logout` | Removes the whole local state directory except extender files. Anything stored there is lost on logout, so the key must not live there. |

The relay can only be tested on testnet until settlement goes live.

## The flow

**Entry:** the payout card on Earnings, when the network has no consent. The card
holds the few lines of explanation, so they're read before the tap (see
[Wording](#wording)), one main button, **Set up payouts**, and two smaller links:
**Save the recovery phrase first** and **Use a wallet I already have** (today's flow).
There's no screen between the card and the result.

- **Set up payouts** (the Save later flow) writes the key to the Keychain, reads it
  back, then signs. This is the one tap: consent is done for every miner on the
  network, and the card reads "Payouts start next epoch" with a reminder to back up
  the key.
- **Save the recovery phrase first** (the Save now flow) never writes anything to
  disk. The key exists only in memory. The Key screen opens, and the user taps the
  same button as in the other flow. Only then does the app sign. When consent
  succeeds, the key is dropped from memory.

The one tap is only for a network with no consent. Replacing a payout wallet keeps its
warning (see [Edge cases](#edge-cases)).

**The ordering is the safety rule: the app never signs until the phrase is safe**,
meaning stored and read back, or confirmed by the user. Otherwise earnings could be
paid to a key nobody holds.

### Key screen (the same one for both flows)

- **Hidden by default.** The words are covered, with **Tap to reveal**.
- **Once revealed:** the words, a **Hide** button and a **Copy** button. There's no
  Copy while hidden.
- It hides itself again after 60 s and whenever the app leaves the foreground.
- One destructive action: **I have saved the key, it's OK to delete it now.**
- A confirmation before it acts, where the user enters two of the words: URnetwork
  can't get this key back, earnings keep going to this address, and only the recovery
  phrase can move them. If the network
  hasn't registered for Top 200, it also says that deleting the key gives up the one-tap
  claim, since registering needs this key. After that, claiming takes a wallet holding
  the recovery phrase (see
  [Networks with an existing wallet](#networks-with-an-existing-wallet)).
- The not-a-wallet text is always visible (see [Wording](#wording)).

**Copy** carries a short warning that other apps may be able to read the clipboard.
On iOS it uses a local-only pasteboard item (no Universal Clipboard) that expires
after 60 s. On Mac the app clears the clipboard after 60 s if it still holds the phrase.

### Key states

| State | On disk | In memory | The card shows | Next |
|---|---|---|---|---|
| None | nothing | nothing | Create or connect | Choose a flow |
| Save now, showing | nothing | phrase | Key screen | Confirm, sign, drop it |
| Save now, consent failed | nothing | phrase | Key screen with Retry | Leaving discards the key; no earnings went to it |
| Save later, not linked | Keychain | when needed | Finish setup | Retry the consent |
| Save later, linked | Keychain | when needed | Address, "Back up your key" | Key screen |
| Saved and deleted | nothing | nothing | Address, "This app no longer has the key" | Claims keep working; convert and one-tap Top 200 registration don't |

The address stays visible after deletion, because it comes from the consent and
isn't a secret.

### Edge cases

- **The network already has a consent.** Creating a key replaces the payout wallet
  from the next epoch, and earlier earnings stay on the old coldkey. Warn first.
  The admin security email for payout wallet changes fires as it does today.
- **Logout.** The Keychain item survives, keyed by network id, and returns when
  that network signs in again. Another network on the device can't see it. If a key
  is still unsaved, warn in the logout confirmation.
- **Account deletion.** Warn the same way, then delete the key.
- **Uninstall.** The app can't intercept it. iOS usually keeps Keychain items across
  a reinstall, so a reinstall finds the key when the network signs in, but that
  isn't guaranteed.
- **Lost or replaced device.** A device-only key doesn't move to a new phone or
  through a restore. An unsaved key on a lost phone means lost access to the SN25α.
  This is the main risk of Save later, and the reminder and wording have to say so.
- **A second device on the same network.** It sees the address, and the message
  "This key is on another device". It can't show the phrase. Creating another key
  there replaces the payout wallet, with the warning above.

## Claim relay

Since `claim` is open to any caller and always pays the coldkey, the relayer needs no
permission from the user and can't redirect funds. It doesn't need the app either: the
payout data on chain and in the published artifacts says what's claimable. So this can
run server-side for every consented network, wallet or local key, without anyone
tapping anything.

### What it costs

Gas price checked 2026-11-02: 5 gwei.

| | Gas per claim | TAO per claim |
|---|---|---|
| v1, paying | up to about 2.55M (2.7M limit) | up to about 0.0135 |
| v1, deferred to credit | 516k to 564k | about 0.0028 |
| v2, alone | about 155k | about 0.0008 |
| v2, batched (20+ per transaction, up to 32) | 147k to 149k | about 0.00074 |
| v2, griefed (a third party fills the vault's hotkey list) | about 1.26M | about 0.0063 |

sn's own planning figure for v2 is about 0.19 α per claim, which it says is about 13
weeks of an average provider's earnings at a 100k population. **So relaying everything
every epoch would cost more than many miners earn.** The relay needs a threshold. sn's
default is 1.9 α, which keeps gas at 10% of the claim. There's also a hard floor: a
claim under about 0.0152 α reverts on chain. v1 is far too expensive to relay at any
scale, so this plan assumes v2.

Those α figures use sn's planning price of 0.006587 TAO/α. SN25's pool price on 2026-11-02
is 0.004224, so at today's price a claim is about 0.30 α, the 10% threshold is about 3 α, and
the floor is about 0.024 α. Gas is paid in TAO, so the relay should set its threshold in TAO
value rather than α.

### What we need to do

1. **The policy is decided** (question 1): v2 only, the threshold, and a daily cap of 0.01 TAO.
2. **Create and fund a relayer key.** A dedicated EVM key holding only operating TAO,
   stored in the vault. Funding it, and deploying `STClaimBatcher` if it isn't already
   deployed, are on-chain actions that need the owner's go and a role check first.
3. **Build the relay service** from sn's `claim_v2_daemon.go` and the batcher. It already
   handles the relayer key, nonces, one transaction per account and refusals. What's new
   is covering every consented coldkey rather than one miner's accounts, and reading them
   from `st_ledger_v2_account`.
4. **Cost control:** the 0.01 TAO daily cap, a gas price ceiling, and a stop when a claim's
   gas jumps, which is what griefing looks like.
5. **Monitoring:** relayer balance, spend, claims pending and refused, with dashboards and
   alerts that pass the server's coverage tests.
6. **Apps:** `ClaimAlphaSheet` and `ClaimLedgerSheet` stop asking for gas and show "URnetwork
   claims this for you", what's pending, and why (under the threshold). Self-claiming with
   the gas key stays as a fallback for people who want it now.
7. **Rehearse on testnet,** including griefing and a low relayer balance.

Steps 2 to 5 live in server and sn, and work for every platform at once.

## Convert SN25α to TAO

The user picks an amount, sees an estimate, and taps once. TAO lands on the same key.

This **can't be relayed like a claim**. Unstaking is a Substrate transaction the coldkey
must sign, so it needs the key on the device, and it's only available until the user
deletes it. It also doesn't need relaying: the fee comes from the alpha (see
[Does the key need gas?](#does-the-key-need-gas)). The device submits it directly to the
chain, as claims already do, so URnetwork pays nothing and isn't in the transaction path.

- **Call:** `remove_stake_limit` on the subnet, hotkey = the vault's escrow hotkey, with a
  price limit so the user can't be surprised by slippage.
- **Built on the device.** The sdk constructs and signs the call itself. It must never sign
  a payload a server handed it, or a compromised server could get a transfer signed.
- **New in the sdk:** Substrate transaction encoding (SCALE, runtime metadata, nonce, era,
  signed extensions). sn has a vendored client, which adds to the mobile builds, and it must
  keep working across runtime upgrades, so this needs a rehearsal per runtime.
- **To verify on testnet:** the zero-TAO path end to end, the minimum amount, and the existential
  deposit. Runtime 486 (live now) also has to match the source read here.
- **Still unknown:** whether Talisman, Nova and btcli let a zero-TAO key submit at all. Users who
  take the phrase to another wallet depend on that, so the docs have to say what happens.
- **After conversion,** the TAO still can't leave the app. To send it, the user imports the
  phrase elsewhere. That TAO pays the fee there.

## Claiming a Top 200 spot

A second phase, after the key flow ships. It follows the owner's proposal of 2026-11-02: sign
centrally, distribute to the devices, let them save what they receive, and convert alpha on
demand. No contract change is needed. It can't ship until binding opens on mainnet.
Copy-and-paste docs are being written now for wallet users and fleet operators, and stay
unlinked until then. They stay afterward as the fallback for anyone the one tap can't reach.

### State on 2026-11-02

- **Binding is closed.** `GET /sn/top` returns `binding_open: false`, a constant in server
  `controller/sn_top_controller.go` ("Opening it is a release decision"). `bindFleetMember`
  reverts `StaleCommitment()` without a fresh mirrored commitment, and the `commitment-oracle`
  service is built but not deployed (sn `mainnet/MAINNET.md`). Production `provider fleet`
  commands also need a mainnet runtime authority that hasn't shipped.
- **Few fleets have been bound so far,** and what a seat pays today is unconfirmed.
- **Rank isn't the obstacle for a casual miner.** 199 seats are open. Rank 200 scores
  0.999995, which is one IP prefix at about 100% presence, and 88 of the top 200 have a single
  prefix.
- **Being measured was, and claiming fixes it.** 162 of the top 200 are outside the verify
  cohort, and a provider outside it can't earn a head score. Live members of a claimed fleet
  get priority into the cohort, capped per fleet, with stale members rotated out (owner
  decision 2026-10-29).
- **Room is limited.** The validator keeps every provider it has ever scored and fails hard
  past 4,096. The default census limit is 3,072 and the census holds 2,001, so about 1,070 new
  devices can still enter until the census starts over.
- **The subnet is full** at 256 UIDs, so each registration evicts the lowest-emission UID past
  its 3-day immunity. The burn is 0.0005 TAO, the floor, and can rise with registrations.

### What a seat pays

The head gets 3/10 of the provider share, split by score, and the pool gets 7/10 (server
`LEADERTOP.md` §3.4). With today's projected scores:

| Who has claimed | One IP prefix's share of the provider share |
|---|---|
| All of today's top 200, at their full projected scores | about 0.0017% |
| All of today's top 200, with each fleet showing at most 7 prefixes | about 0.048% |
| Only today's 32 measurable networks, at their full projected scores | about 0.0033% |
| Almost nobody | a large part of the head's 30% |
| For comparison, an average provider in the pool | about 0.0019% |

7 is the cohort's per-fleet priority share at a cohort of 1,500 (`VerifyCohortPriorityPerFleet`).
Members past it get in only as room allows, so a big fleet's real score falls somewhere between
the first two rows, and nobody has measured where. Once the big fleets bind, one prefix pays
between about what the pool pays and about 25 times that, and far more while few have claimed.
Rank 1's projection alone is about 2,858.

### The flow, from one tap

This is the flow for a network whose key is on the key holder's device. The tap covers the
whole network: the server chooses the devices in step 3, and everything else stays in the pool.

| Step | Done by | Cost |
|---|---|---|
| 1. Convert just enough alpha, or receive the top-up | The key, on the device | Fee in alpha, or URnetwork's top-up |
| 2. Burn-register a new hotkey | The key, on the device | The burn and its fee, from step 1 |
| 3. Choose the devices and build the manifest | Server | Nothing |
| 4. Publish the manifest's commitment | The hotkey, on the device | Nothing: `set_commitment` is `Pays::No` in Subtensor's source |
| 5. Mirror the commitment | Commitment oracle | URnetwork |
| 6. Sign each device's binding | The hotkey, on the device | Nothing |
| 7. Deliver each binding; the device checks it, signs with its client key and saves it | Server and device | Nothing |
| 8. Submit each binding | Relayer | URnetwork, for small fleets (question 15): about 263,640 gas a bind, about 0.0013 TAO at 5 gwei, read from two mainnet binds |

A binding starts at the next settlement epoch, up to 7 days later, and lasts at most 12 epochs,
about 3 months. Renewal repeats steps 6 to 8 with no tap.

**Converting on demand.** Signing is free; only the burn and its fee need TAO. Step 1 converts
that amount at the tap, with a price limit. The key must already hold alpha: today's burn is
about 0.12 α, roughly 8 weeks of an average miner's earnings by sn's 100k-population figures.
A miner with too little gets a capped top-up from us instead (question 16), so a new miner isn't
stuck waiting for alpha. At today's burn that costs less than relaying the claim that would fund
it, and all 200 seats come to about 0.1 TAO in burns.

### What has to hold

- **No device gets the hotkey's private key.** The contract checks a client signature and a
  hotkey signature for each device. A binding needs only the public hotkey and those signatures,
  so that's what's distributed and saved. One compromised device must not expose the fleet's
  hotkey.
- **The client signature stays on the device.** The client key exists only there, so a device
  has to be online and on a release with this support. Older devices stay in the pool. Miners
  with no app sign the same way (see [Headless miners](#headless-miners)).
- **Bind only devices that add score, not every active provider.** Bound members leave the pool
  whether or not they're selected, and score counts distinct IP prefixes. A second device on the
  same prefix adds nothing and loses its pool share, and members past the per-fleet priority share
  (7 at a cohort of 1,500) may never be measured. The server picks one device per prefix, up to
  that share, which also cuts the gas.
- **Auto-signing removes a person's check, so the device needs its own.** The dual signature
  exists so that a fleet can't claim a client it doesn't operate. If a device signs whatever
  arrives, a server bug or breach, or a stolen account, could bind its devices to someone else's
  hotkey and stop their pool earnings from the next epoch. A device signs only if the binding
  names its own client id and key (the sdk already refuses others), carries a valid hotkey
  signature, and names a hotkey authorized by a signature from the network's coldkey, which the
  device pins on first use. A changed coldkey or hotkey stops auto-signing. The admin gets an
  email on every change, and a device can opt out.
- **Leaving is as easy as joining.** `revokeFleetBinding` needs only the client key, so any
  device can leave by itself, from the next epoch. A Leave action ships in the first version:
  otherwise an evicted UID or a lost seat costs the pool share for up to 3 months.
- **The hotkey is a separate key on the key holder's device,** not derived from the recovery
  phrase and never sent to our servers. It stays when the phrase is deleted, so renewals and new
  devices keep working, but they wait until that device is online. It survives logout the same way
  the key does. If that device is lost, the fleet can't renew or add devices, and getting a new
  hotkey takes the recovery phrase in another wallet or btcli. Existing bindings run to their end.
- **Manifest changes are batched once per epoch,** since each one needs a new commitment and a
  fresh mirror, and a binding can't start before the next epoch anyway.

### Headless miners

Operators with many devices run `provider` on servers or in Docker, with nobody at the host.
Without a path for them the second promise fails: those devices couldn't sign, so the tap would
bind nothing and they'd stay in the pool.

Today a binding on a host takes a person: `provider fleet sign` (sn `miner/fleet_sign.go`) signs
with the host's client key when someone runs it, and no code signs automatically. A running
`provider` already holds that key, `.provider.key` in its state directory, so the new work is:

- **Auto-signing, in a `provider` release.** A running provider asks the server for its pending
  binding, runs the checks in [What has to hold](#what-has-to-hold), signs with its client key,
  saves the result in its state directory and returns the signature. The operator runs no command,
  and the fleet hotkey is never on the host.
- **One copy of the checks.** The apps and `provider` call the same code, so they can't drift. The
  sdk's `SignSnFleetBinding` already refuses another client id or key; the hotkey signature and
  coldkey authorization checks join it there.
- **Pin before there's anything to attack.** A provider pins the network's coldkey when it first
  sees the network's consent, not when the first binding arrives. A changed coldkey or hotkey stops
  auto-signing and says why in the log. Auto-signing is on by default (question 18), and a flag on
  `provider start` opts out.
- **Leaving.** A short `provider` command signs a revocation with the client key and sends it through
  the relay. Today's `provider fleet revoke` needs a manifest, an RPC endpoint and a relayer key.
- **Cheap to run.** Every provider asks, so the request is slow and jittered, and the server answers
  from the short list of chosen devices.
- **Proxy slots.** Slots on one host share one client key under separate client ids. Each signs only
  for its own id, and the one-device-per-prefix choice applies across them.
- **Lost state.** A host that loses its state directory, such as a container with no volume, gets a
  new key and can't revoke its old binding, which runs to its end. It comes back as a new device.
- **It reaches fleets only as they update.** Hosts restart when they update, and the release is its own
  decision. A device on an older release isn't chosen and stays in the pool, so the card shows how many
  of the network's devices are chosen, ready, and still to update.
- **The manual route stays.** `provider fleet sign` and `provider fleet bind` remain for operators who
  hold their own hotkey. The server sends a device work only for a hotkey its network's coldkey
  authorized, so those operators' devices never auto-sign anything.

### Networks with an existing wallet

These networks consented with a wallet, so the app doesn't hold their coldkey. People who deleted the
app's key join them once they've imported the recovery phrase into a wallet. The tap is the same, and
the wallet signs only what the coldkey has to:

| Step | Done by | Notes |
|---|---|---|
| Create the hotkey | The app, on the device | The same separate key as above; no wallet involved |
| Authorize the hotkey | The wallet | One message signature, through the wallet proof transports that exist today. Devices check it exactly as they check the local key's |
| Register the hotkey, with a conversion first if needed | The wallet | One transaction, the coldkey's own: `register_limit` is signed by the hotkey's owner |
| Steps 3 to 8 | As above | No wallet involved |

**So this is one tap plus up to two wallet approvals, not one signature.** The authorization is one
signature, as planned, but a new registration also needs the coldkey on chain. A relayer can't do it for
them: whoever signs `register_limit` owns the seat, which would be custodial. Question 17 asks whether to
fold the two into one.

- **Only registering needs the transaction.** Afterward, renewals and new devices need no wallet.
- **Transports are unproven for this.** Today's sign messages only. Sending a transaction through them is
  new, and whether a zero-TAO wallet can submit at all is still unknown. Where they can't, the app shows
  the hotkey's address and the btcli command from the copy-and-paste docs.
- **The top-up applies here too,** for a wallet with too little to register (question 16).
- **A network with its own registered hotkey** keeps using `provider fleet` with it, since that hotkey
  isn't on the device.
- **Replacing the payout wallet with a key on this device** (question 9) gets the plain one tap, but
  earlier earnings stay on the old coldkey, so it's never the default.

### Where one tap stops

| Who | What they get |
|---|---|
| Key on this device, enough alpha or a top-up, miners online and updated | Both promises, in one tap each |
| Headless miners on an older `provider` release | Wallet setup covers them; for Top 200 they stay in the pool until they update |
| Network with an existing wallet | One tap, plus up to two wallet approvals, once for Top 200 |
| Key deleted, or Save now | Wallet setup is done; Top 200 takes a wallet holding the phrase |
| Android, Windows and Linux, before the port | No key flow yet; today's wallet paths |
| ur.io | No key flow; wallets and manual signing |

### To prove on testnet, and tests

- A zero-TAO key converts alpha, then registers. A zero-TAO hotkey publishes a commitment.
- The gas for `revokeFleetBinding`, which is unmeasured, and for `bindFleetMember` on testnet: two
  mainnet binds read 263,634 and 263,646 gas.
- A `provider` on the new release binds with no command at the host. One on an older release is never
  chosen and keeps earning in the pool. A provider that restarts mid-binding doesn't sign twice.
- The wallet path: authorize, register, then bind, including a wallet with no TAO and one whose
  transport can't send a transaction.
- Whether a new UID can be evicted before its binding starts: immunity lasts 3 days, and the
  binding can be up to 7 days away.
- Whether anything penalizes a network whose other devices stay in the pool.
- A device refuses a binding for another client or key, a bad hotkey signature, and an unpinned
  or changed hotkey, in the apps and in `provider` alike. Only the chosen devices are bound. Leave
  works from one device, and the opt-out flag stops a provider from signing.

## Design

### Key material, in the sdk

The port to other platforms is why this belongs in the sdk. Add
`bittensor_local_key.go`, exported through gomobile and cgo:

- `BittensorLocalKeyGenerate() (mnemonic, ss58)`
- `BittensorLocalKeyAddress(mnemonic) ss58`
- `BittensorLocalKeySign(mnemonic, message) signature`, wrapping in `<Bytes>…</Bytes>`
  as wallets do

Stateless on purpose: nothing is cached in Go, and it stays out of `LocalState` and
the device RPC, so the phrase never reaches the tunnel extension or any file.

- **Format:** BIP39 phrase, substrate-bip39 derivation (the mini secret comes from
  the entropy, not the standard BIP39 seed), sr25519, SS58 prefix 42.
- **Library:** `ChainSafe/go-schnorrkel` plus a BIP39 wordlist. The server already
  uses both, but the sdk doesn't, so this adds a dependency to the mobile builds.
- **Interop is the requirement:** the phrase must produce the same address in btcli,
  Talisman and Nova. Pin it with known vectors, and check each by hand before ship.
- **Memory:** Go and Swift strings can't be reliably wiped. We keep the phrase in as
  few places as possible, for as short a time as possible, and don't claim more than
  that. macOS may also page memory to disk, so "never written to disk" is exact for
  our code, but best effort for the OS on Mac.

### Storage, on Apple

- Keychain generic password, one item per network id.
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: not in backups, not synced, not
  migrated. On macOS, the data protection keychain.
- Written and read back before any signing. Delete removes the item and verifies
  it's gone.
- Signing with a stored key needs no prompt, so setup stays one tap.

**Never:** logs, analytics, crash reports, `UserDefaults`, local state files, state
restoration, the extension, or the network. The pasteboard only on an explicit Copy.

### Screen privacy, on Apple

"No screenshots" can only be best effort on Apple's platforms, and the UI shouldn't
promise more.

| Control | iOS and iPadOS | macOS |
|---|---|---|
| Block capture | No official API. Render the words in a secure text field's layer, which blanks them in screenshots and recordings. Widely used but unsupported, so it needs a test on each new iOS. | `NSWindow.sharingType = .none`. Reported as not fully honored by newer capture APIs on recent macOS; to verify. |
| Detect capture | `UIScreen.isCaptured` hides the words while recording or mirroring. `userDidTakeScreenshotNotification` warns afterward. | No equivalent. |
| App switcher | Cover the screen when not active. | Hide the words when the window loses focus. |
| Reveal | Tap, after device authentication (Face ID, Touch ID or passcode) for a stored key. | Same, Touch ID or password. |
| Copy | Only once revealed; local-only, expires after 60 s. | Only once revealed; cleared after 60 s. |

Also: no Handoff, and no text selection on the words. VoiceOver reads them only once
revealed.

### Fitting into the existing flow

`NetworkConsentFlow` gets a local key path. The address comes from the key rather
than the address field, then the same challenge, then the sdk signs it, then the
existing `handleProof`. Nothing changes on the server for this part: to the server it's
any other coldkey signing its consent. New Swift pieces: `BittensorLocalKeyStore`,
`BittensorKeyScreen`, and a small state model.

## Wording

Draft; goes through the strings process. It appears on the create screen, the Key
screen and the delete confirmation, in short form on the Earnings card, and in the docs.

> URnetwork is not a wallet. It created this key so you can receive SN25α. To
> transfer or use your SN25α, enter this recovery phrase into a Bittensor wallet
> such as Talisman or Nova, or into btcli.
>
> Anyone with this phrase controls your SN25α. URnetwork will never ask for it, and
> can't recover it. If you lose this device before saving it, your SN25α can't be
> reached.

The delete confirmation adds this while the network hasn't registered for Top 200:

> Deleting this key also gives up claiming a Top 200 spot with one tap. You could still
> claim from a Bittensor wallet holding this recovery phrase.

It must also be clear this is **not** the account seed phrase from sign-up (see
question 7). The docs get tested, exact steps for importing into Talisman, Nova and
`btcli wallet regen-coldkey`, shared with the manual flow's docs now being written.

## Build order

1. **Interop and zero-TAO spike.** Generate and sign; prove the address matches in btcli,
   Talisman and Nova, and that the server accepts the signature. On testnet, prove a
   zero-TAO key that received alpha can unstake with the fee paid in alpha.
2. **sdk API and tests.**
3. **Apple:** Keychain store, then the Key screen with its privacy controls.
4. **Apple:** wire into `NetworkConsentFlow`, Earnings, logout and account deletion.
5. **Claim relay,** in parallel with 2 to 4, since it doesn't depend on them. It must be
   live, or claims shown honestly as pending, before this ships.
6. **Docs and strings,** App Review notes, TestFlight.
7. **Convert** (question 2), as soon as it's ready and its testnet proof passes. The rest
   doesn't wait for it, and it doesn't wait for the rest.
8. **Port.**
9. **Top 200,** once binding is open and convert is proven. Its server side covers every
   platform; each platform adds auto-signing and Leave. A `provider` release adds the same for
   headless miners, without which fleets aren't covered, and the existing-wallet path follows.

### Tests

- **sdk:** known vectors, round trip with the server's verifier, malformed input,
  and no phrase in any error text.
- **Store:** write and read back, per-network isolation, delete, survives logout.
- **Flow:** no signing before the phrase is safe, in both flows. Failed consent keeps
  the key. Leaving Save now discards it. Crash between store and consent resumes at
  Finish setup. Copy is impossible while hidden.
- **Relay:** claims land on the right coldkey, the threshold and the spending cap hold,
  griefing stops it, a refused claim leaves the rest alone.
- **Convert:** the sdk builds the expected call and refuses anything else, the price limit
  holds, works from zero TAO on testnet.
- **A scan** that the phrase doesn't appear in logs, local state, or preferences
  during a full run.
- **Manual:** screenshot and recording on a real iPhone, iPad and Mac.

### Porting

| Platform | Storage | Capture blocking |
|---|---|---|
| Android | Keystore-wrapped encrypted storage, excluded from backup | `FLAG_SECURE`, which is real and enforced |
| Windows | DPAPI or Credential Manager | `SetWindowDisplayAffinity`, which is real for most capture |
| Linux | libsecret, with a clear refusal if there's no keyring | None dependable; say so on screen |
| ur.io (web) | Not offered: no safe storage in a browser | Keeps wallets and manual signing |

The sdk part ports for free, and the relay already covers everyone. Each platform needs
its store, Key screen and strings. Store review needs rechecking at each port.

## Open questions

All answered as of 2026-11-03. The numbers stay because other sections refer to them.

1. **Decided (owner, 2026-11-03): the relay policy below, with a daily cap of 0.01 TAO.** At about 0.19 α a claim, relaying small balances costs
   more than they're worth, and a low threshold has real cost at scale.
   - **Automatic claims:** at sn's 1.9 α default, gas stays at 10% of the claim, but by sn's
     figures an average miner at a 100k population takes about 2.5 years to get there.
   - **On request:** a "Claim now" tap, which we pay for, limited per coldkey.

   The policy is v2 only; automatic at about 0.0125 TAO of value (1.9 α at sn's planning price,
   about 3 α today); "Claim now" once balance clears the transfer floor (0.0001 TAO of value),
   at most once per 30 days per coldkey; and a daily cap of 0.01 TAO on claims. v2 credit never
   expires, so waiting costs the miner nothing. At about 0.00074 to 0.0008 TAO a claim, the cap pays
   for about 12 claims a day; past that, claims wait for the next day. Bindings and top-ups are
   outside this cap (questions 15 and 16).

2. **Decided (owner, 2026-11-03): convert ships as soon as it's ready, with no limit by region.** It's
   separate work from the rest of the key flow, so neither waits for the other.

3. **Decided (owner, 2026-11-03): convert ends when the key is deleted.** Once deleted, the app can't sign,
   so the user goes to a wallet or btcli. That means Save now users never get convert, and the delete
   confirmation says so. A user can keep the key to keep convert, which the Save later flow already
   allows. Deleting also gives up one-tap Top 200 registration, and the delete confirmation says so
   (decided, owner, 2026-11-02).

4. **Decided (owner, 2026-11-03): the key signs the payout consent, plus convert.** Claims use the relay.
   For Top 200 it also signs what the flow's table gives it. The owner's reading is whatever makes
   this easiest for the end user.

5. **Decided (owner, 2026-11-02): Save later is the default,** as the card's main button,
   with the reminder doing the work. Save now stays one tap away, as a smaller link.

6. **Decided (owner, 2026-11-03): the user proves they saved the phrase before deleting,** with the
   confirmation dialog plus entering two of the words, on both flows. It's the only moment that
   stands between a misclick and lost access.

7. **Decided (owner, 2026-11-03): 12 words,** the common default in Bittensor wallets, always called the
   "Bittensor recovery phrase" or similar. The account seed phrase is 24 words and is a different
   secret, so users could confuse them.

8. **Decided (owner, 2026-11-03): device authentication to reveal or delete a stored key,** and none for
   signing during setup or for Save now.

9. **Decided (owner, 2026-11-03): offer replacing an existing payout wallet,** with the warning, since some
   users will be stuck on a wallet that can't sign.

10. **Decided (owner, 2026-11-03): a persistent banner on Earnings while a key is unsaved,** plus one local
    notification when the first epoch becomes claimable, since that's when the key starts to be worth
    something. No repeated nagging.

11. **Decided (owner, 2026-11-03): signed-in accounts only, no guests, and only the network owner's session,**
    matching who can sign the consent today.

12. **Decided (owner, 2026-11-03): both Mac builds see the same key,** App Store and direct, through a shared
    Keychain access group, if entitlements allow it for both.

13. **Decided (owner, 2026-11-02): open binding on mainnet,** as its own release, with each
    on-chain step brought to the owner first. Preparation has started.

14. **Decided (owner, 2026-11-02): the hotkey lives on the key holder's device,** as a key separate
    from the recovery phrase.

15. **Decided (owner, 2026-11-02): URnetwork relays bindings for small fleets up to a device limit,**
    with larger fleets paying their own. Each bound device is its own transaction, at least every 3
    months. Two mainnet binds read about 263,640 gas each, so 7 devices cost about 0.009 TAO per binding
    period at 5 gwei, and 200 fleets of 7 about 1.8 TAO. **The limit is the per-fleet share,** 7 at a
    cohort of 1,500 (owner, 2026-11-03): the server binds no more than that, so every fleet the one tap binds is
    covered. Funding the relayer is an on-chain step that comes to the owner first.

16. **Decided (owner, 2026-11-02): a capped top-up,** only for networks the app already prompts to
    claim. **The cap is the live burn plus its fee, once per network** (owner, 2026-11-03). Still to set: the key
    that pays it. Creating and funding that key are on-chain steps that come to the owner first.

17. **Decided (owner, 2026-11-03): two wallet approvals in the first version,** since it happens once and the
    device check stays simple. The authorization is a message and the registration is a transaction. They
    could become one approval, a single batched transaction, if devices took the chain's record of the
    hotkey's owner as the authorization. That needs a chain read on every device and a transport that can
    send a batch, neither of which exists on the phone today, so fold them later if wallets prove able.

18. **Decided (owner, 2026-11-03): headless auto-signing is on by default,** with the opt-out flag. Opt-in would
    need someone at every host, which is the thing this path removes. The risk is a server bug, breach or
    stolen account reaching those devices, which the coldkey authorization, the pin and the admin email are
    there to catch.

## Found while planning

- **The sdk's notes on TAO.com are out of date.** They say it has no programmatic
  interface; its current extension does. Being handled in the wallet flow fix.
