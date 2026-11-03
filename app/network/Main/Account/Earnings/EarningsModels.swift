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

    /// URnetwork is the one claiming: it is, or it will once a balance or a
    /// new day allows. Otherwise the device's own claim is the way for now.
    var relayClaims: Bool {
        reason != SdkSnClaimReasonRelayNotRunning && reason != SdkSnClaimReasonRelayPaused
    }
}

/// The answer to a Claim now tap.
enum SnClaimNowOutcome: Equatable {
    /// URnetwork sends it first, within the day's budget
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
