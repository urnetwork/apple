import Testing
@testable import URnetwork

/// Change password mails a reset link, and the server's reset rewrites the
/// account's email and phone password sign-ins. Gating it on `userAuth`, the
/// identity the account was created with, offered it to Google and Apple
/// accounts, whose reset changed nothing, and never to an account that added
/// an email and password later (inbox 7962, 7969).
struct PasswordResetUserAuthTests {

    @Test func ssoOnlyAccountIsNotOfferedAReset() {
        #expect(passwordResetUserAuth(userAuth: "user@example.com", authType: "google", authTypes: ["google"], userAuths: []) == nil)
        #expect(passwordResetUserAuth(userAuth: "user@example.com", authType: "apple", authTypes: ["apple"], userAuths: []) == nil)
    }

    @Test func passwordAccountIsOfferedTheResetAtItsAddress() {
        let email = [PasswordSignIn(userAuth: "user@example.com", authType: "email")]
        #expect(passwordResetUserAuth(userAuth: "user@example.com", authType: "password", authTypes: ["email"], userAuths: email) == "user@example.com")
        let phone = [PasswordSignIn(userAuth: "+15555550100", authType: "phone")]
        #expect(passwordResetUserAuth(userAuth: "+15555550100", authType: "password", authTypes: ["phone"], userAuths: phone) == "+15555550100")
    }

    /// An account created with a wallet, a seed phrase or as a guest that added
    /// an email and password later has no `userAuth`.
    @Test func accountThatAddedAnEmailIsOfferedTheResetAtThatEmail() {
        let added = [PasswordSignIn(userAuth: "added@example.com", authType: "email")]
        #expect(passwordResetUserAuth(userAuth: nil, authType: "solana", authTypes: ["email", "solana"], userAuths: added) == "added@example.com")
        #expect(passwordResetUserAuth(userAuth: "", authType: "seedphrase", authTypes: ["seedphrase", "email"], userAuths: added) == "added@example.com")
        #expect(passwordResetUserAuth(userAuth: nil, authType: "guest", authTypes: ["email"], userAuths: added) == "added@example.com")
    }

    /// A Google or Apple account that added an email and password is offered
    /// the reset at the added email, not at the provider's.
    @Test func ssoAccountThatAddedAnEmailIsOfferedTheResetAtTheAddedEmail() {
        let added = [PasswordSignIn(userAuth: "added@example.com", authType: "email")]
        #expect(passwordResetUserAuth(userAuth: "provider@example.com", authType: "google", authTypes: ["google", "email"], userAuths: added) == "added@example.com")
    }

    @Test func emailIsPreferredOverPhone() {
        let both = [
            PasswordSignIn(userAuth: "+15555550100", authType: "phone"),
            PasswordSignIn(userAuth: "user@example.com", authType: "email"),
        ]
        #expect(passwordResetUserAuth(userAuth: "+15555550100", authType: "password", authTypes: ["phone", "email"], userAuths: both) == "user@example.com")
    }

    /// An older sdk or server sends no `user_auths`.
    @Test func withoutUserAuthsTheCreatedIdentityIsUsed() {
        #expect(passwordResetUserAuth(userAuth: "user@example.com", authType: "password", authTypes: ["email", "google"], userAuths: []) == "user@example.com")
    }

    @Test func oldServerReadsTheSingleAuthType() {
        #expect(passwordResetUserAuth(userAuth: "user@example.com", authType: "password", authTypes: [], userAuths: []) == "user@example.com")
        #expect(passwordResetUserAuth(userAuth: "user@example.com", authType: "google", authTypes: [], userAuths: []) == nil)
    }

    @Test func noAddressIsNoReset() {
        #expect(passwordResetUserAuth(userAuth: "", authType: "password", authTypes: ["email"], userAuths: []) == nil)
        #expect(passwordResetUserAuth(userAuth: nil, authType: "solana", authTypes: ["solana", "email"], userAuths: []) == nil)
        #expect(passwordResetUserAuth(userAuth: nil, authType: "solana", authTypes: ["email"], userAuths: [PasswordSignIn(userAuth: "", authType: "email")]) == nil)
    }
}
