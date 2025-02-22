//
//  AuthLoginResult.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/04.
//

import Foundation
import URnetworkSdk

// NOTE: used in LoginInitial to check whether the user already exists or if they should create a new network
enum AuthLoginResult {
    case login(_ jwt: String)
    case promptPassword(SdkAuthLoginResult)
    case create(SdkAuthLoginArgs)
    case failure(Error)
    case verificationRequired(_ userAuth: String)
    case incorrectAuth(_ authAllowed: String)
}

enum AuthLoginError: Error {
    case isInProgress
    case invalidResult
    case invalidArguments
}
