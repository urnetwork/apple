//
//  NetworkCreateCallback.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/01/10.
//

import Foundation
import URnetworkSdk

class NetworkCreateCallback: OneShotSdkCallback<SdkNetworkCreateResult, SdkNetworkCreateCallbackProtocol>, SdkNetworkCreateCallbackProtocol {
    func result(_ result: SdkNetworkCreateResult?, err: Error?) {
        handleResult(result, err: err)
    }
}
