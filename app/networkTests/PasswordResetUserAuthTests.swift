import Testing
@testable import URnetwork

/// Change password mails a reset link, and the server's reset only rewrites an
/// email or phone password sign-in. Gating it on `userAuth` offered it to
/// Google and Apple accounts, whose reset changed nothing.
struct PasswordResetUserAuthTests {

    @Test func ssoOnlyAccountIsNotOfferedAReset() {
        #expect(passwordResetUserAuth(userAuth: "user@example.com", authType: "google", authTypes: ["google"]) == nil)
        #expect(passwordResetUserAuth(userAuth: "user@example.com", authType: "apple", authTypes: ["apple"]) == nil)
    }

    @Test func passwordAccountIsOfferedTheResetAtItsAddress() {
        #expect(passwordResetUserAuth(userAuth: "user@example.com", authType: "password", authTypes: ["email", "google"]) == "user@example.com")
        #expect(passwordResetUserAuth(userAuth: "+15555550100", authType: "password", authTypes: ["phone"]) == "+15555550100")
    }

    @Test func oldServerReadsTheSingleAuthType() {
        #expect(passwordResetUserAuth(userAuth: "user@example.com", authType: "password", authTypes: []) == "user@example.com")
        #expect(passwordResetUserAuth(userAuth: "user@example.com", authType: "google", authTypes: []) == nil)
    }

    @Test func noAddressIsNoReset() {
        #expect(passwordResetUserAuth(userAuth: "", authType: "password", authTypes: ["email"]) == nil)
        #expect(passwordResetUserAuth(userAuth: nil, authType: "solana", authTypes: ["solana", "email"]) == nil)
    }
}
