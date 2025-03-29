//
//  SubscriptionManager.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/31.
//

import Foundation
import StoreKit
import URnetworkSdk

/**
 * For creating a subscription with the App Store
 */
@MainActor
class AppStoreSubscriptionManager: ObservableObject {
    @Published var products: [Product] = []
    @Published var isPurchasing: Bool = false
    @Published private(set) var purchaseSuccess: Bool = false
    
    private var networkId: SdkId?
    var onPurchaseSuccess: () -> Void = {}
    
    private var updateListenerTask: Task<Void, Error>?
    
    init(networkId: SdkId?) {
        self.networkId = networkId
        
        updateListenerTask = listenForTransactions()
        
        Task {
            await fetchProducts()
        }
    }
    
    deinit {
        updateListenerTask?.cancel()
    }
    
    func fetchProducts() async {
        do {
            let productIdentifiers = ["supporter"]
            
            let storeProducts = try await Product.products(for: productIdentifiers)
            
            self.products = storeProducts
            print("Retrieved products: \(storeProducts.count)")
        } catch {
            print("Failed to fetch products: \(error)")
        }
    }
    
    func purchase(product: Product, onSuccess: @escaping (() -> Void)) async throws {
        guard !isPurchasing else { return }
        
        isPurchasing = true
        defer { isPurchasing = false }
        
        self.onPurchaseSuccess = onSuccess
        
        do {
            var purchaseOptions: Set<Product.PurchaseOption> = []
            
            guard let networkId = self.networkId else {
                print("no network id found")
                return
            }
            
            print("networkId.idStr: \(networkId.idStr)")
            
            if let networkUUID = UUID(uuidString: networkId.idStr) {
                print("setting purchase options with app account token: \(networkUUID)")
                purchaseOptions.insert(.appAccountToken(networkUUID))
            } else {
                print("error adding network id to purchase options")
                return
            }
            
            let result = try await product.purchase(options: purchaseOptions)
            
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    print("✅ Purchase verified: \(transaction.id)")
                    
                    logTransactionDetails(transaction)
                    
                    await transaction.finish()
                    
                    onPurchaseSuccess()
                    setPurchaseSuccess(true)
                    
                case .unverified( _, let error):
                    print("Purchase unverified: \(error)")
                    throw error
                }
                
            case .userCancelled:
                print("Purchase cancelled by user")
                throw SKError(.paymentCancelled)
                
            case .pending:
                print("Purchase pending approval")
                
            @unknown default:
                print("Unknown purchase result")
            }
        } catch {
            print("Purchase failed: \(error)")
            throw error
        }
    }
    
    func setPurchaseSuccess(_ success: Bool) {
        self.purchaseSuccess = success
    }

    private func logTransactionDetails(_ transaction: Transaction) {
        print("Transaction ID: \(transaction.id)")
        print("Product ID: \(transaction.productID)")
        print("Purchase Date: \(transaction.purchaseDate)")
        
        if let appAccountToken = transaction.appAccountToken {
            print("App Account Token: \(appAccountToken)")
        }
    }
    
    
    private func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            // Iterate through any transactions that didn't come from a direct call to `purchase()`
            for await result in Transaction.updates {
                do {
                    // Check if the transaction is verified
                    switch result {
                    case .verified(let transaction):
                        print("✅ Verified transaction update: \(transaction.id)")
                        
                        // Log transaction details for debugging
                        await self.logTransactionDetails(transaction)
                        
                        // Finish the transaction
                        await transaction.finish()
                        
                        // If this is a new purchase notification, not just an update
                        if transaction.revocationDate == nil {
                            await MainActor.run {
                                self.onPurchaseSuccess()
                            }
                        }
                        
                    case .unverified(_, let error):
                        print("Unverified transaction: \(error.localizedDescription)")
                    }
                } catch {
                    print("Transaction listener error: \(error.localizedDescription)")
                }
            }
        }
    }
}
