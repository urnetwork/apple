//
//  ShownPlan.swift
//  URnetwork
//
//  The plan the plan cards show, as the sdk decides it
//  (SubscriptionProTracker.GetShownPlan, which DeviceManager holds): Pro or
//  Free as the server answered, Pro also by the stored jwt's claim before it
//  answers, and neither until it does. In December 2025 the balance read
//  failed under database load and the app showed a failed read as Free, with
//  its Get Pro, to networks whose paid plans were running (support inbox
//  4074). Only the server says Free.
//

import Foundation

enum ShownPlan: Equatable {
    case pro
    case free
    /// The server has not answered and the claim is not Pro: the first
    /// balance read is on its way.
    case loading
    /// The server has not answered and the last balance read failed.
    case unreachable

    /// From the sdk's decision: its shown plan (the sdk's ShownPlan* values,
    /// "pro", "free" or "unknown") and whether the last balance read failed
    /// (GetLastReadFailed). Any other answer is not known either.
    static func of(sdkPlan: String, lastReadFailed: Bool) -> ShownPlan {
        switch sdkPlan {
        case "pro":
            return .pro
        case "free":
            return .free
        default:
            return lastReadFailed ? .unreachable : .loading
        }
    }

    /// What a plan card's label shows: the plan once it is known, a spinner
    /// while the first read is on its way, or the failed state with a retry.
    var load: SectionLoad {
        switch self {
        case .pro, .free:
            return .loaded
        case .loading:
            return .loading
        case .unreachable:
            return .failed
        }
    }

    /// Get Pro beside the label: only once the server said Free, never for a
    /// plan that is not known yet.
    var offersUpgrade: Bool {
        self == .free
    }
}
