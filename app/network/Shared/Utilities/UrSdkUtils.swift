//
//  UrSdkUtils.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 8/27/25.
//

import Foundation
import URnetworkSdk

func intListToArray(_ intList: SdkIntList) -> [Int] {
    
    let n = intList.len()
    var arr: [Int] = []
    
    for i in 0..<n {
        
        let value = intList.get(i)
        arr.append(value)
        
    }
    
    return arr
    
}

func floatListToArray(_ floatList: SdkFloat64List) -> [Double] {
    
    let n = floatList.len()
    var arr: [Double] = []
    
    for i in 0..<n {
        
        let value = floatList.get(i)
        arr.append(value)
    }
    
    return arr
}
