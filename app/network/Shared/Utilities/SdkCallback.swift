//
//  SdkCallback.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/28.
//

import Foundation

class SdkCallback<ResultType, ProtocolType>: NSObject where ProtocolType: AnyObject {
    private let completion: (ResultType?, Error?) -> Void
    
    init(completion: @escaping (ResultType?, Error?) -> Void) {
        self.completion = completion
    }
    
    func handleResult(_ result: ResultType?, err: Error?) {
            self.completion(result, err)
    }
}
