//
//  SubscriptionManager.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/31.
//

import Foundation
import StoreKit

class SubscriptionManager: NSObject, ObservableObject {
    @Published var products: [SKProduct] = []
    
    var onPurchase: () -> Void = {}
    private var productRequest: SKProductsRequest?
    
    func fetchProducts() {
        let productIdentifiers = Set(["supporter"]) // Replace with your product ID
        productRequest = SKProductsRequest(productIdentifiers: productIdentifiers)
        productRequest?.delegate = self
        productRequest?.start()
    }

    func purchase(product: SKProduct, onSuccess: @escaping () -> Void) {
        let payment = SKPayment(product: product)
        SKPaymentQueue.default().add(payment)
        self.onPurchase = onSuccess
    }
    
    override init() {
        super.init()
        self.fetchProducts()
        SKPaymentQueue.default().add(self)
    }
    
    deinit {
        SKPaymentQueue.default().remove(self)
    }
    
}

extension SubscriptionManager: SKProductsRequestDelegate {
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        DispatchQueue.main.async {
            print("retrieved products: \(response.products)")
            self.products = response.products
        }
    }
}

extension SubscriptionManager: SKPaymentTransactionObserver {
    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions {
            switch transaction.transactionState {
            case .purchased:
                print("✅ Purchase successful in \(Bundle.main.appStoreReceiptURL?.absoluteString.contains("sandbox") ?? false ? "SANDBOX" : "PRODUCTION")")
                DispatchQueue.main.async {
                    self.onPurchase()
                }
                SKPaymentQueue.default().finishTransaction(transaction)
            case .failed:
                if let error = transaction.error as? SKError {
                    print("❌ Purchase failed: \(error.localizedDescription)")
                }
                SKPaymentQueue.default().finishTransaction(transaction)
            case .purchasing:
                print("💳 Processing purchase in sandbox...")
            default:
                break
            }
        }
    }
}
