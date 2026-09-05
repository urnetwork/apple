import XCTest

final class TunnelLocalStateIdentityTests: XCTestCase {
    func testRotatedJwtForSameInstancePreservesLocalState() {
        XCTAssertFalse(
            tunnelLocalStateRequiresReset(
                storedByJwt: "jwt-before-refresh",
                storedInstanceId: "instance-a",
                configuredByJwt: "jwt-after-refresh",
                configuredInstanceId: "instance-a"
            )
        )
    }

    func testDifferentInstanceResetsEvenWhenJwtMatches() {
        XCTAssertTrue(
            tunnelLocalStateRequiresReset(
                storedByJwt: "same-jwt",
                storedInstanceId: "instance-a",
                configuredByJwt: "same-jwt",
                configuredInstanceId: "instance-b"
            )
        )
    }

    func testMissingOrUnreadableInstanceResets() {
        for storedInstanceId in [nil, ""] as [String?] {
            XCTAssertTrue(
                tunnelLocalStateRequiresReset(
                    storedByJwt: "stored-jwt",
                    storedInstanceId: storedInstanceId,
                    configuredByJwt: "configured-jwt",
                    configuredInstanceId: "instance-a"
                )
            )
        }
    }

    func testMissingConfiguredInstanceResets() {
        XCTAssertTrue(
            tunnelLocalStateRequiresReset(
                storedByJwt: "stored-jwt",
                storedInstanceId: "instance-a",
                configuredByJwt: "configured-jwt",
                configuredInstanceId: ""
            )
        )
    }
}
