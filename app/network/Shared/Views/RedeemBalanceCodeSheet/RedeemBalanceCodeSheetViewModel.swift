//
//  RedeemBalanceCodeSheetViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 1/9/26.
//

import Foundation
import URnetworkSdk

/**
 * A credited redeem, from the server's answer: the data the code added to the
 * network's balance (transfer_balance.balance_byte_count) and, for a Pro gift
 * code, the year of Pro it granted (pro).
 *
 * A data code is data only: the server grants its transfer balance with
 * pro = false (RedeemBalanceCodeInTx) and the answer has no pro, so it is
 * confirmed as data added. A gift code grants a year of Pro
 * (mmm/GIFTOFPRIVACY.md §5, §10.2), starting now or, when queued, after the
 * network's current paid Pro period; its answer still carries a transfer
 * balance, of 0 bytes. BalanceCodeRedeemedView confirms either. The server
 * grants in the redeem itself, so the balance and the plan are read once
 * after it, never through the purchase confirmation poll, which waits for a
 * store's webhook.
 */
struct RedeemedBalanceCode: Equatable {

    /// The year of Pro a gift code granted.
    struct ProGrant: Equatable {
        let startTime: Date?
        let endTime: Date?
        /// The year starts after the network's current paid Pro period; false
        /// when that is not known (a code read back from the redeemed list).
        let queued: Bool
    }

    let addedByteCount: Int64
    /// nil for a data code
    let pro: ProGrant?

    init(addedByteCount: Int64, pro: ProGrant? = nil) {
        self.addedByteCount = addedByteCount
        self.pro = pro
    }

    init(result: SdkRedeemBalanceCodeResult) {
        self.addedByteCount = result.transferBalance?.balanceByteCount ?? 0
        self.pro = result.pro.map { pro in
            ProGrant(
                startTime: Self.date(pro.startTime),
                endTime: Self.date(pro.endTime),
                queued: pro.queued
            )
        }
    }

    /// A code this network redeemed earlier, read back from its redeemed list
    /// after a redeem whose answer was lost. The list has a gift's kind and
    /// the end of its year, but not when the year starts or whether it was
    /// queued, so a gift confirms as "A year of Pro is yours.", true either
    /// way.
    init(listed: SdkRedeemedBalanceCode) {
        self.addedByteCount = listed.balanceByteCount
        if listed.kind == SdkBalanceCodeKindProGift {
            self.pro = ProGrant(startTime: nil, endTime: Self.date(listed.endTime), queued: false)
        } else {
            self.pro = nil
        }
    }

    private static func date(_ time: SdkTime?) -> Date? {
        time.map { Date(timeIntervalSince1970: TimeInterval($0.unixMilli()) / 1000) }
    }
}


extension RedeemBalanceCodeSheet {
    
    enum RedeemBalanceCodeError: Error {
        case inProgress
        case unknown(String)
    }
    
    @MainActor
    class ViewModel: ObservableObject {
        
//        @Published var isProcessing: Bool = false
        @Published var code: String = ""
//        @Published var codeInvalid: Bool = false
        @Published var redeemState: ValidationState = .notChecked
        
        let domain = "[RedeemBalanceCodeSheetViewModel]"
        
        let api: UrApiServiceProtocol
        
        init(api: UrApiServiceProtocol) {
            self.api = api
        }

        /// Redeem is offered for a code of a code's length (the SDK's
        /// BalanceCodeLength) as the server matches it, so a code typed as the
        /// card prints it, in groups of four, can be sent. It is sent as typed.
        var canRedeem: Bool {
            redeemState != .validating && Self.normalizedSecret(code).count == Int(SdkBalanceCodeLength)
        }

        func redeem() async -> Result<RedeemedBalanceCode, Error> {
  
            if self.redeemState == .validating {
                return .failure(RedeemBalanceCodeError.inProgress)
            }
            
            self.redeemState = .validating
            
//            if isProcessing {
//                return .failure(RedeemBalanceCodeError.inProgress)
//            }

//            isProcessing = true
//            codeInvalid = false

            let code = self.code

            do {

                let result = try await api.redeemBalanceCode(code)

//                isProcessing = false

                if result.error != nil {
                    // the server answers a code this network already redeemed
                    // as it answers an unknown one: a redeem whose answer was
                    // lost left the code in the redeemed list
                    if let redeemed = await redeemedEarlier(code) {
                        self.redeemState = .valid
                        return .success(redeemed)
                    }
                    self.redeemState = .invalid
//                    codeInvalid = true
                    return .failure(RedeemBalanceCodeError.unknown(result.error?.message ?? "An unknown error occurred redeeming the balance code"))
                }

                self.redeemState = .valid
                return .success(RedeemedBalanceCode(result: result))

            } catch(let error) {
                print("\(domain) Error redeeming balance code: \(error)")
                // no answer: the server may have granted before it was lost
                if let redeemed = await redeemedEarlier(code) {
                    self.redeemState = .valid
                    return .success(redeemed)
                }
                self.redeemState = .invalid
//                isProcessing = false
//                codeInvalid = true
                return .failure(error)
            }

        }

        /// `code` in this network's redeemed list, after a redeem that did not
        /// credit (the SDK's ClassifyBalanceCodeRedeem, matching the code as
        /// the server does). nil when it isn't there or the list can't be read.
        private func redeemedEarlier(_ code: String) async -> RedeemedBalanceCode? {
            let secret = Self.normalizedSecret(code)
            guard !secret.isEmpty,
                  let result = try? await api.getRedeemedBalanceCodes(),
                  result.error == nil,
                  let list = result.balanceCodes else {
                return nil
            }
            for i in 0..<list.len() {
                if let listed = list.get(i), Self.normalizedSecret(listed.secret) == secret {
                    return RedeemedBalanceCode(listed: listed)
                }
            }
            return nil
        }

        /// A code as the server matches it (mmm/GIFTOFPRIVACY.md 9.1, call 2):
        /// spaces, hyphens and dots removed, upper-cased, so a code typed as
        /// the card prints it, in groups of four, is the code.
        nonisolated static func normalizedSecret(_ code: String) -> String {
            String(code.unicodeScalars.filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar) && scalar != "-" && scalar != "."
            }).uppercased()
        }
        
    }
    
}
