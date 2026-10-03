import XCTest
import URnetworkSdk
@testable import URnetwork

// The add sign-in method sheet offered "Seedphrase" and sent AddAuth with no
// auth fields for it; the server answers that with "no auth method supplied",
// so the option always failed. Every method the Add button sends must name
// an auth method the server's AddAuth accepts.
final class AddAuthSheetMethodsTests: XCTestCase {

    func testEveryAddButtonRequestSuppliesAnAuthMethod() {
        for appleAvailable in [false, true] {
            for googleAvailable in [false, true] {
                for method in addAuthSheetMethods(appleAvailable: appleAvailable, googleAvailable: googleAvailable) {
                    guard let args = addAuthButtonArgs(method, email: "a@example.com", password: "a-long-password") else {
                        continue
                    }
                    XCTAssertTrue(addAuthArgsSupplyMethod(args), "\(method.rawValue): the AddAuth request supplies no auth method")
                }
            }
        }
    }

    func testSheetOffersTheProviderMethodsAndEmail() {
        XCTAssertEqual(addAuthSheetMethods(appleAvailable: true, googleAvailable: true), [.apple, .google, .wallet, .email])
        XCTAssertEqual(addAuthSheetMethods(appleAvailable: false, googleAvailable: false), [.wallet, .email])
    }

    func testEmailRequestCarriesTheAddressAndPassword() {
        let args = addAuthButtonArgs(.email, email: "a@example.com", password: "a-long-password")

        XCTAssertEqual(args?.userAuth, "a@example.com")
        XCTAssertEqual(args?.password, "a-long-password")
        XCTAssertNil(addAuthButtonArgs(.wallet, email: "a@example.com", password: "a-long-password"))
    }

    // the server's AddAuth branches (network_user_model.go)
    func testSupplyMatchesTheServerContract() {
        XCTAssertFalse(addAuthArgsSupplyMethod(SdkAddAuthArgs()))

        let emailOnly = SdkAddAuthArgs()
        emailOnly.userAuth = "a@example.com"
        XCTAssertFalse(addAuthArgsSupplyMethod(emailOnly))

        let jwt = SdkAddAuthArgs()
        jwt.authJwt = "token"
        XCTAssertFalse(addAuthArgsSupplyMethod(jwt))
        jwt.authJwtType = "google"
        XCTAssertTrue(addAuthArgsSupplyMethod(jwt))

        let wallet = SdkAddAuthArgs()
        wallet.walletAuth = SdkWalletAuthArgs()
        XCTAssertTrue(addAuthArgsSupplyMethod(wallet))
    }
}
