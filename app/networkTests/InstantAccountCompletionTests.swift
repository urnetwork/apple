import XCTest
@testable import URnetwork

final class InstantAccountCompletionTests: XCTestCase {
    func testRapidConfirmationStartsOneCreatedLogin() {
        var gate = InstantAccountCompletionGate()
        let first = gate.takeCreatedLogin(jwt: "synthetic-admin-jwt")
        let duplicate = gate.takeCreatedLogin(jwt: "synthetic-admin-jwt")

        XCTAssertEqual(first, .created("synthetic-admin-jwt"))
        XCTAssertNil(duplicate)
        XCTAssertTrue(gate.isCompleting)
        XCTAssertTrue(first?.newNetwork == true)
    }

    func testExistingLoginCannotAcquireCreatedClassification() {
        let login = NetworkLogin.existing("synthetic-existing-jwt")

        XCTAssertFalse(login.newNetwork)
        XCTAssertEqual(login.jwt, "synthetic-existing-jwt")
    }
}
