//
//  EarningsModels.swift
//  URnetwork
//
//  Plain models for the points-first Earnings screen: the account's points
//  per finalized epoch, the connected Bittensor coldkey, the SDK-held gas key,
//  the settlement-vault claims and the settlement v2 accounts (the Top 200
//  standing is the Protocol leaderboard's SnTopMeResultInfo). They mirror the
//  SDK's sn* shapes so the views never hold gomobile objects.
//

import Foundation
import URnetworkSdk

/// The coldkey alpha settles to. Attached to this device's provider client.
struct SnWalletInfo: Equatable {
    let coldkeySs58: String
    let clientId: String
    let setAtMillis: Int64
}

/// The SDK-generated EVM key that pays claim gas. The secret never leaves the
/// SDK; the app only sees the address and the ss58 mirror to fund it.
struct SnGasKeyInfo: Equatable {
    let address: String
    let mirrorSs58: String
}

/// The SDK's SnEpochClaim.Status. `open`: the vault has not finalized the
/// epoch, so nothing is claimable yet. `notFinalized` ("not-finalized"):
/// despite the SDK's name, the vault has finalized the epoch with nothing for
/// this coldkey to claim, because no payout root was published for it (the
/// root was missed, which is final) or its payout list holds no share for
/// this coldkey. A status this build does not know is `open`, which promises
/// nothing.
enum SnClaimStatus: String {
    case open
    case claimable
    case claimed
    case expired
    case notFinalized = "not-finalized"

    init(sdkStatus: String) {
        self = SnClaimStatus(rawValue: sdkStatus) ?? .open
    }
}

/// The words a v1 claim reads as on Earnings: an epoch's status in the
/// history rows and the claim sheet, and the count under the unclaimed total.
/// `bundle` is the catalog to read (nil: the app's).
enum SnClaimText {

    static func status(_ status: SnClaimStatus, bundle: Bundle? = nil) -> String {
        switch status {
        case .claimable:
            return String(localized: "Unclaimed", bundle: bundle)
        case .claimed:
            return String(localized: "Claimed", bundle: bundle)
        case .expired:
            return String(localized: "Expired", bundle: bundle)
        case .open:
            return String(localized: "Pending", bundle: bundle)
        case .notFinalized:
            // finalized by the vault, never "finalizing": no payout was published for it
            return String(localized: "No payout published", bundle: bundle)
        }
    }

    /// How many epochs the unclaimed total comes from: the claimable ones,
    /// which is what it says (not "finalized epochs").
    static func claimableEpochs(_ count: Int, bundle: Bundle? = nil) -> String {
        String(localized: "Claimable epochs: \(count)", bundle: bundle)
    }
}

/// One finalized epoch's entitlement in the settlement vault.
struct SnEpochClaimInfo: Identifiable, Equatable {
    let epoch: Int64
    let shareBps: Int64
    let amountRao: Int64
    var status: SnClaimStatus
    let claimOpenBlock: Int64
    let expiryBlock: Int64
    var txHash: String

    var id: Int64 { epoch }
}

/// One finalized epoch of the account's points history.
struct AccountEpochInfo: Identifiable, Equatable {
    let epoch: Int64
    let startMillis: Int64
    let endMillis: Int64
    let points: Double
    let shareBps: Int64

    var id: Int64 { epoch }
}

/// The unauthenticated wallet check every address goes through before it is
/// sent anywhere.
struct SnWalletValidation: Equatable {
    let validSyntax: Bool
    let existsOnChain: Bool
    let banned: Bool
    let message: String
}

/// Progress of a direct claim: the SDK signs and sends each epoch's claim
/// from the gas key and reports here.
enum SnClaimEvent {
    case sent(epoch: Int64, txHash: String)
    case confirmed(epoch: Int64, txHash: String, amountRao: Int64)
    case failed(epoch: Int64, message: String)
    case done
}

/// A settlement v2 account as the SDK's claim progress names it: the pool
/// (network-operator id) and the account's fixed index in its tree.
struct SnLedgerAccountKey: Hashable {
    let noId: Int64
    let index: Int64
}

/// What a settlement v2 pool pays for (sdk SnLedgerPoolKind*): the operator's
/// pool, or its capture the flag pool (sn/CAPTURETHEFLAG.md §10), which pays
/// each epoch's draw winners. The sdk reads an entry from a server that
/// predates kinds, and a kind it does not know, as a pool.
enum SnLedgerPoolKind: Equatable {
    case pool
    case ctf

    init(sdkKind: String) {
        self = sdkKind == SdkSnLedgerPoolKindCtf ? .ctf : .pool
    }

    /// the kind of a pool known by its id alone (an account the claim reports
    /// that no read listed), as the sdk reads an entry without a kind:
    /// capture the flag's pools are 2^32 + n
    init(noId: Int64) {
        self = SdkSnLedgerCtfPoolIdBase <= noId ? .ctf : .pool
    }
}

/// The coldkey's settlement v2 account in one operator pool, from the SDK's
/// SnLedgerAccount (the operator's GET /sn/ledger/account). Amounts are rao.
/// The balance is cumulative and never expires.
struct SnLedgerAccountInfo: Identifiable, Equatable {
    /// the pool's STSettlementVault2
    let vault: String
    let noId: Int64
    let index: Int64
    /// the cumulative in the latest finalized root
    let finalizedRao: Int64
    /// finalized less paid: what a claim would transfer now
    let claimableRao: Int64
    /// already transferred to the coldkey
    let paidRao: Int64
    /// a committed root that is not finalized yet holds the account, with
    /// pendingRao as its cumulative
    let pending: Bool
    let pendingRao: Int64
    /// what the pool pays for; a pool for a server that predates kinds
    var kind: SnLedgerPoolKind = .pool

    var id: SnLedgerAccountKey {
        SnLedgerAccountKey(noId: noId, index: index)
    }

    /// what the pending root adds to the finalized amount ("Pending: +X,
    /// awaiting finalization"); nil when nothing pending adds to it
    var pendingIncreaseRao: Int64? {
        guard pending, pendingRao > finalizedRao else {
            return nil
        }
        return pendingRao - finalizedRao
    }
}

/// A pool whose ledger the operator could not read just now (sdk
/// SnLedgerUnavailablePool): whether the coldkey has an account there is
/// unknown, so its row says so in place of the balances, never 0, and the
/// other pools show as usual.
struct SnLedgerUnavailablePool: Equatable {
    /// the pool's STSettlementVault2
    let vault: String
    let noId: Int64
    var kind: SnLedgerPoolKind = .pool

    /// the key the sdk's claim reports the pool's failure under: its noId,
    /// and index 0, since its account's index is unknown
    var id: SnLedgerAccountKey {
        SnLedgerAccountKey(noId: noId, index: 0)
    }
}

/// A settlement v2 ledger read (sdk SnLedgerAccountsResult): the coldkey's
/// accounts, one per pool, and the pools that could not be read just now. A
/// server that predates capture the flag names none of the latter.
struct SnLedgerAccountsInfo: Equatable {
    var accounts: [SnLedgerAccountInfo]
    var unavailablePools: [SnLedgerUnavailablePool] = []
}

/// What the v2 claim needs from the SDK's chain settings.
/// What URnetwork's claim relay says of the network's settlement v2 balance
/// (sdk SnClaimStatusResult): who claims it, why it is still pending, and what
/// Claim now can do. The decisions are the sdk's (sn_claim_relay.go); this only
/// carries them to the screen.
struct SnClaimStatusInfo: Equatable {
    /// the relay's state, sdk SnClaimRelayStateUnavailable without an answer
    var relayState: String = SdkSnClaimRelayStateUnavailable
    var coldkeySs58: String = ""
    /// sdk SnClaimAction*: what the main control does
    var action: String = SdkSnClaimActionNone
    /// sdk SnClaimReason*: why the balance is pending
    var reason: String = SdkSnClaimReasonNothingPending
    var claimableRao: Int64 = 0
    var valueTaoRao: Int64 = 0
    var pendingRao: Int64 = 0
    var claimNowAvailable = false
    /// sdk SnClaimNowReason*, or an SnClaimReason*, while Claim now can't act
    var claimNowReason: String = ""
    var claimNowNextAtMillis: Int64 = 0
    /// the device's own claim with its gas key can claim this now
    var selfClaimAvailable = false
    var selfClaimNeedsGas = false
    /// in rao of α at the relay's last price, 0 without one
    var automaticThresholdRao: Int64 = 0
    /// in rao of TAO
    var automaticThresholdTaoRao: Int64 = 0
    var transferFloorTaoRao: Int64 = 0
    /// the transfer floor in rao of α at the relay's last price, 0 without
    /// one: a capture the flag balance under it waits (sdk TransferFloorRao)
    var transferFloorRao: Int64 = 0
    var claimNowPeriodDays: Int64 = 0
    /// the balances could not be read: unavailable, never zero
    var unavailable = false
    /// the sdk's rule for the Settlement v2 tile of a network with no wallet on
    /// this device (SnClaimStatusResult.ShowsTile): a claimable or pending
    /// balance, or a claim URnetwork paid in full. Never while unavailable
    var showsTile = false
    /// the claimed state, the mocks' 4d (sdk ShowsClaimed): URnetwork's claim is
    /// the primary account's latest, and nothing is claimable now
    var showsClaimed = false
    /// that claim's page on the explorer (sdk ClaimTxUrl), "" without one
    var claimTxUrl: String = ""
    /// what that claim paid, in rao of α (sdk ClaimAmountRao)
    var claimAmountRao: Int64 = 0
    /// each of the network's accounts, one per coldkey and pool, including a
    /// wallet's it replaced, whose balance URnetwork keeps claiming (sdk
    /// Accounts); the top level is the primary coldkey's accounts together
    var accounts: [SnClaimRelayAccountInfo] = []
    /// the pools whose ledger could not be read just now (sdk
    /// UnavailablePools): the top level leaves them out
    var unavailablePools: [SnLedgerUnavailablePool] = []

    /// URnetwork is the one claiming: it is, or it will once a balance or a
    /// new day allows. Otherwise the device's own claim is the way for now.
    var relayClaims: Bool {
        reason != SdkSnClaimReasonRelayNotRunning && reason != SdkSnClaimReasonRelayPaused
    }
}

/// One of the network's accounts as URnetwork's claim relay sees it (sdk
/// SnClaimRelayAccount): a coldkey's account in one pool. Amounts are rao of
/// α.
struct SnClaimRelayAccountInfo: Equatable {
    var coldkeySs58: String = ""
    var noId: Int64 = 0
    var kind: SnLedgerPoolKind = .pool
    var claimableRao: Int64 = 0
    /// the account's latest claim when URnetwork sent it: the transaction, its
    /// page on the explorer ("" without one) and what it paid; "" and 0 for a
    /// claim anyone else sent, or none
    var claimTxHash: String = ""
    var claimTxUrl: String = ""
    var claimAmountRao: Int64 = 0

    /// URnetwork's claim is the account's latest and nothing is claimable
    /// since: the sdk's ShowsClaimed rule, which it decides for the top level
    /// only, applied to the account
    var showsClaimed: Bool {
        !claimTxHash.isEmpty && claimableRao <= 0
    }
}

/// A capture the flag slot won whose award is not claimed yet (an entry of
/// sdk SnCtfClientResult.UnclaimedWins, from GET /sn/ctf/client, which the sdk
/// asks for the network's wins, every client's, as ur.io does): one of the up
/// to five slots of its country and role in an epoch's draw. The tile draws a
/// line for each.
struct SnCtfWinInfo: Equatable {

    enum Role: Equatable {
        case provider
        case extender
    }

    let role: Role
    /// lowercase ISO 3166-1 alpha-2
    let country: String
    /// the epoch whose draw it won; 0 when not known
    let epoch: Int64

    /// nil for a role this build does not know, or no country
    init?(role: String, country: String, epoch: Int64 = 0) {
        switch role {
        case SdkSnCtfRoleProvider:
            self.role = .provider
        case SdkSnCtfRoleExtender:
            self.role = .extender
        default:
            return nil
        }
        guard !country.isEmpty else {
            return nil
        }
        self.country = country
        self.epoch = epoch
    }

    /// The wins newest first: by epoch, and within an epoch in the order
    /// given (the sdk's: providers before extenders).
    static func newestFirst(_ wins: [SnCtfWinInfo]) -> [SnCtfWinInfo] {
        wins.enumerated()
            .sorted { $0.element.epoch != $1.element.epoch ? $0.element.epoch > $1.element.epoch : $0.offset < $1.offset }
            .map(\.element)
    }

    /// "You won one of the Iceland provider slots": a slot, never the flag,
    /// which a country's draw holds only once all ten of its slots are won.
    /// The country is named in `locale`'s language (the app's: its
    /// localization), and `bundle` is the catalog to read (nil: the app's).
    func text(locale: Locale? = nil, bundle: Bundle? = nil) -> String {
        let locale = locale ?? Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        let code = country.uppercased()
        let name = locale.localizedString(forRegionCode: code) ?? code
        switch role {
        case .provider:
            return String(localized: "You won one of the \(name) provider slots", bundle: bundle)
        case .extender:
            return String(localized: "You won one of the \(name) extender slots", bundle: bundle)
        }
    }
}

/// A good read of the capture the flag wins: every win not claimed yet,
/// newest first, and whose wins they are. The sdk's ClientId is "" for the
/// network's answer, every client's wins, read with the session's network
/// credential; it names the client for an answer for that client alone, the
/// sdk's read with the client token after the network credential's read
/// failed, or any answer of a server before the network answer. A network
/// answer beats a client answer (owner, 2026-11-12).
struct SnCtfWinsAnswer: Equatable {
    let wins: [SnCtfWinInfo]
    /// the client answered for; "" for the network's answer
    var clientId: String = ""

    /// this client's wins alone
    var fromClient: Bool {
        !clientId.isEmpty
    }
}

/// The answer to a Claim now tap.
enum SnClaimNowOutcome: Equatable {
    /// queued: URnetwork sends it ahead of its automatic claims, the oldest
    /// request first, as each day's budget allows; the coldkey's limit starts
    /// only once this claim goes through
    case requested
    /// not taken: sdk SnClaimNowReason* or SnClaimReason*, and when the
    /// coldkey's limit ends for a tap the limit refused
    case refused(reason: String, nextAtMillis: Int64)
    case failed(String)
}

struct SnLedgerChainInfo: Equatable {
    /// the STSettlementVault2 v2 claims go to; "" until v2 claims are
    /// configured (before activation)
    let vault2Address: String
    /// the explorer's transaction link, "https://…/tx/%s"
    let explorerTxUrl: String

    static let unconfigured = SnLedgerChainInfo(vault2Address: "", explorerTxUrl: "")

    var claimConfigured: Bool {
        !vault2Address.isEmpty
    }

    /// A transaction's explorer link, rendered as the SDK's
    /// SnChainSettings.ExplorerUrlForTx does: the hash in place of %s, else
    /// after a "/". nil without a link template or a hash.
    func explorerUrl(txHash: String) -> URL? {
        guard !explorerTxUrl.isEmpty, !txHash.isEmpty else {
            return nil
        }
        if explorerTxUrl.contains("%s") {
            return URL(string: explorerTxUrl.replacingOccurrences(of: "%s", with: txHash))
        }
        let base = explorerTxUrl.hasSuffix("/") ? String(explorerTxUrl.dropLast()) : explorerTxUrl
        return URL(string: "\(base)/\(txHash)")
    }
}

/// Progress of a settlement v2 claim: the SDK claims every finalized account
/// of the coldkey with a verified claimable, one transaction per account from
/// the gas key, and reports here.
enum SnLedgerClaimEvent: Equatable {
    case sent(noId: Int64, index: Int64, txHash: String)
    case confirmed(noId: Int64, index: Int64, txHash: String, amountRao: Int64)
    case failed(noId: Int64, index: Int64, message: String)
    case done
}

enum EarningsClientError: LocalizedError, Equatable {
    /// the SDK build in use has no subnet surface yet
    case sdkUnavailable
    case noWallet
    case emptyResult
    case message(String)
    /// POST /sn/wallet refused the coldkey signature: it does not verify for
    /// the address (the wallet signed with another account, or other text).
    /// Carries the server's message.
    case signatureMismatch(String)

    /// the SDK's SnError code for `signatureMismatch` (sdk SnErrorCodeSignatureMismatch)
    static let signatureMismatchCode = "signature_mismatch"

    var errorDescription: String? {
        switch self {
        case .sdkUnavailable:
            return "The chain RPC is unreachable. Try again."
        case .noWallet:
            return "Connect a Bittensor wallet first."
        case .emptyResult:
            return "The chain RPC is unreachable. Try again."
        case .message(let message):
            return message
        case .signatureMismatch(let message):
            // as any other coded SDK error reads
            return "\(Self.signatureMismatchCode): \(message)"
        }
    }
}
