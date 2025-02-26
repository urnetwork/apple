//
//  MockSKProduct.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/31.
//

import Foundation
import StoreKit

// todo: delete this?

class MockSKProduct: SKProduct {
    private let mockLocalizedTitle: String
    private let mockLocalizedDescription: String
    private let mockPrice: NSDecimalNumber
    private let mockPriceLocale: Locale

    init(localizedTitle: String, localizedDescription: String, price: NSDecimalNumber, priceLocale: Locale) {
        self.mockLocalizedTitle = localizedTitle
        self.mockLocalizedDescription = localizedDescription
        self.mockPrice = price
        self.mockPriceLocale = priceLocale
        super.init()
    }

    override var localizedTitle: String {
        return mockLocalizedTitle
    }

    override var localizedDescription: String {
        return mockLocalizedDescription
    }

    override var price: NSDecimalNumber {
        return mockPrice
    }

    override var priceLocale: Locale {
        return mockPriceLocale
    }
}
