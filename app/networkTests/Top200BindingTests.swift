//
//  Top200BindingTests.swift
//  networkTests
//
//  Sign fleet binding (Earnings › Top 200): the binding checks, the member
//  entry, the payload and the app link's decode, then the screen's model with
//  a fake device. The fixture is sn's fleet_sign_test.go vector (client seed
//  bytes 0x01..0x20), which mmm's page tests share: a page-built binding must
//  give the bytes `provider fleet sign` prints. No device, no network.
//

import Foundation
import Testing
@testable import URnetwork

struct Top200BindingTests {

    static let clientId = "019b2e10-5a7c-4d3e-8f01-23456789abcd"
    static let clientKey = "0x79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"
    static let signature = "0x8a3e5b990f1a280f0eef9455c81dfbfd251a5ac5a9bc021770cf0a4dee1b4aafab04762d6ca8b587c1e04642d46cff87844b89aefcaddf26700fdbc849efbc0a"
    static let binding = #"{"chain_id":945,"netuid":25,"coordinator":"0xc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3","fleet_id":"0xf0f1f2f3f4f5f6f7f8f9fafbfcfdfeffe0e1e2e3e4e5e6e7e8e9eaebecedeeef","hotkey":"0x0a1c77edb48519069bbb154bf088c7f17678839de458e0679370ae989af3f55c","client_id":"019b2e10-5a7c-4d3e-8f01-23456789abcd","client_key":"0x79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664","generation":3,"valid_from_epoch":100,"valid_to_epoch":200,"commitment_hash":"0x9e1d4fa4a979f45cf003f26d826837250b08b45b8e896f98316cfc60005d3471"}"#
    static let payload = #"{"binding":{"chain_id":945,"netuid":25,"coordinator":"0xc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3","fleet_id":"0xf0f1f2f3f4f5f6f7f8f9fafbfcfdfeffe0e1e2e3e4e5e6e7e8e9eaebecedeeef","hotkey":"0x0a1c77edb48519069bbb154bf088c7f17678839de458e0679370ae989af3f55c","client_id":"019b2e10-5a7c-4d3e-8f01-23456789abcd","client_key":"0x79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664","generation":3,"valid_from_epoch":100,"valid_to_epoch":200,"commitment_hash":"0x9e1d4fa4a979f45cf003f26d826837250b08b45b8e896f98316cfc60005d3471"},"client_signature":"0x8a3e5b990f1a280f0eef9455c81dfbfd251a5ac5a9bc021770cf0a4dee1b4aafab04762d6ca8b587c1e04642d46cff87844b89aefcaddf26700fdbc849efbc0a"}"#

    /// the fixture with one field's json value replaced (or the field removed for nil)
    static func binding(_ name: String, _ value: String?) -> String {
        var fields = [
            ("chain_id", "945"),
            ("netuid", "25"),
            ("coordinator", #""0xc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3""#),
            ("fleet_id", #""0xf0f1f2f3f4f5f6f7f8f9fafbfcfdfeffe0e1e2e3e4e5e6e7e8e9eaebecedeeef""#),
            ("hotkey", #""0x0a1c77edb48519069bbb154bf088c7f17678839de458e0679370ae989af3f55c""#),
            ("client_id", #""019b2e10-5a7c-4d3e-8f01-23456789abcd""#),
            ("client_key", #""0x79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664""#),
            ("generation", "3"),
            ("valid_from_epoch", "100"),
            ("valid_to_epoch", "200"),
            ("commitment_hash", #""0x9e1d4fa4a979f45cf003f26d826837250b08b45b8e896f98316cfc60005d3471""#),
        ]
        if let index = fields.firstIndex(where: { $0.0 == name }) {
            if let value {
                fields[index].1 = value
            } else {
                fields.remove(at: index)
            }
        } else if let value {
            fields.append((name, value))
        }
        return "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }

    static func check(_ text: String, clientId: String? = clientId, clientKey: String = clientKey) -> Top200BindingCheck {
        Top200Bindings.check(text, deviceClientId: clientId, deviceClientKey: clientKey)
    }

    static func base64Url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test func theFixtureIsThisDevicesBinding() throws {
        #expect(Self.binding("chain_id", "945") == Self.binding)
        guard case .valid(let text, let binding) = Self.check(Self.binding) else {
            Issue.record("not valid: \(Self.check(Self.binding))")
            return
        }
        #expect(text == Self.binding)
        #expect(binding.chainId == 945)
        #expect(binding.netuid == 25)
        #expect(binding.fleetId == "0xf0f1f2f3f4f5f6f7f8f9fafbfcfdfeffe0e1e2e3e4e5e6e7e8e9eaebecedeeef")
        #expect(binding.hotkey == "0x0a1c77edb48519069bbb154bf088c7f17678839de458e0679370ae989af3f55c")
        #expect(binding.generation == 3)
        #expect(binding.validFromEpoch == 100)
        #expect(binding.validToEpoch == 200)
    }

    @Test func thePayloadWrapsThePastedTextByteForByte() {
        #expect(Top200Bindings.payload(bindingText: Self.binding, signature: Self.signature) == Self.payload)
        // the pasted text is trimmed, never re-serialized
        #expect(Top200Bindings.payload(bindingText: "\n  " + Self.binding + " \n", signature: Self.signature) == Self.payload)
        guard case .valid(let text, _) = Self.check("  \n" + Self.binding + "\n\t") else {
            Issue.record("a padded binding is not valid")
            return
        }
        #expect(text == Self.binding)
    }

    @Test func anotherDevicesBindingIsRefused() {
        // another client id
        #expect(Self.check(Self.binding, clientId: "019b2e10-5a7c-4d3e-8f01-23456789abce") == .otherDevice)
        #expect(Self.check(Self.binding("client_id", #""0f000000-0000-4000-8000-000000000001""#)) == .otherDevice)
        // another client key: the sdk does not check it, so the app must
        #expect(Self.check(Self.binding, clientKey: "0x" + String(repeating: "ab", count: 32)) == .otherDevice)
        #expect(Self.check(Self.binding("client_key", "\"0x" + String(repeating: "cd", count: 32) + "\"")) == .otherDevice)
        // no device client id
        #expect(Self.check(Self.binding, clientId: nil) == .otherDevice)
    }

    @Test func idAndKeyCompareAsBytes() {
        // the id as 0x + 32 hex and upper case hex are the same device
        let hexId = Self.binding("client_id", #""0x019B2E105A7C4D3E8F0123456789ABCD""#)
        guard case .valid = Self.check(hexId) else {
            Issue.record("a 0x client id of this device is not valid")
            return
        }
        guard case .valid = Self.check(Self.binding, clientId: Self.clientId.uppercased(), clientKey: Self.clientKey.uppercased().replacingOccurrences(of: "0X", with: "0x")) else {
            Issue.record("upper case device id and key do not match")
            return
        }
    }

    @Test func notABindingIsInvalid() {
        let cases: [String] = [
            "not json",
            "[]",
            "{}",
            // the payload pasted instead of the binding
            Self.payload,
            // a field missing, an extra field
            Self.binding("commitment_hash", nil),
            Self.binding("client_signature", #""0x00""#),
            // bad hex sizes
            Self.binding("fleet_id", "\"0x" + String(repeating: "f", count: 62) + "\""),
            Self.binding("coordinator", "\"0x" + String(repeating: "c", count: 64) + "\""),
            Self.binding("hotkey", "\"" + String(repeating: "a", count: 64) + "\""),
            Self.binding("client_key", "\"0x" + String(repeating: "g", count: 64) + "\""),
            Self.binding("client_id", #""019b2e10-5a7c-4d3e-8f01""#),
            // the epochs out of order
            Self.binding("valid_to_epoch", "99"),
            // the integers
            Self.binding("netuid", "65536"),
            Self.binding("chain_id", "0"),
            Self.binding("generation", "0"),
            Self.binding("valid_from_epoch", "-1"),
            Self.binding("valid_to_epoch", "200.0"),
            Self.binding("valid_to_epoch", "2e2"),
            Self.binding("chain_id", #""945""#),
            Self.binding("netuid", "true"),
            Self.binding("generation", "null"),
        ]
        for text in cases {
            #expect(Self.check(text) == .invalid, "\(text)")
        }
        #expect(Self.check("") == .empty)
        #expect(Self.check(" \n ") == .empty)
        // the edge of the integer ranges is fine
        guard case .valid = Self.check(Self.binding("valid_to_epoch", "100")),
              case .valid = Self.check(Self.binding("netuid", "65535")) else {
            Issue.record("the range edges are not valid")
            return
        }
    }

    // the sdk's Go decoder matches keys case-insensitively and lets a later
    // duplicate win, so a doubled or case-variant key could show one hotkey in
    // review and sign another; JSONSerialization keeps only one of duplicates
    @Test func everyKeyIsSpelledExactlyAndOnce() {
        let otherHotkey = "\"0x" + String(repeating: "ee", count: 32) + "\""
        let drop = { (text: String) in String(text.dropLast()) }
        let cases: [String] = [
            // a duplicate key, the same or another value
            drop(Self.binding) + #","hotkey":"0x0a1c77edb48519069bbb154bf088c7f17678839de458e0679370ae989af3f55c"}"#,
            drop(Self.binding) + ",\"hotkey\":" + otherHotkey + "}",
            "{\"hotkey\":" + otherHotkey + "," + Self.binding.dropFirst(),
            // a duplicate spelled with an escape
            drop(Self.binding) + ",\"hot\\u006bey\":" + otherHotkey + "}",
            // a case-variant key beside the field, or instead of it
            drop(Self.binding) + ",\"HOTKEY\":" + otherHotkey + "}",
            Self.binding.replacingOccurrences(of: "\"hotkey\"", with: "\"HotKey\""),
            Self.binding.replacingOccurrences(of: "\"client_key\"", with: "\"Client_Key\""),
            // an extra key
            drop(Self.binding) + ",\"note\":\"x\"}",
        ]
        for text in cases {
            #expect(Self.check(text) == .invalid, "\(text)")
        }
        #expect(Top200Bindings.topLevelKeys(#"{"a":{"b":1,"c":"\"d\":"},"e" : [ "f" ]}"#) == ["a", "e"])
        #expect(Top200Bindings.topLevelKeys("[]") == nil)
    }

    @Test func noClientKeyStopsBeforeTheDeviceCheck() {
        #expect(Self.check(Self.binding, clientKey: "") == .noKey)
        // not a binding stays invalid without a key
        #expect(Self.check(Self.payload, clientKey: "") == .invalid)
    }

    @Test func theMemberEntryNamesThisDevice() {
        #expect(Top200Bindings.memberEntry(deviceClientId: Self.clientId, deviceClientKey: Self.clientKey)
            == #"{"client_id":"0x019b2e105a7c4d3e8f0123456789abcd","client_key":"0x79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"}"#)
        #expect(Top200Bindings.memberEntry(deviceClientId: Self.clientId, deviceClientKey: "") == nil)
        #expect(Top200Bindings.memberEntry(deviceClientId: nil, deviceClientKey: Self.clientKey) == nil)
    }

    @Test func theReviewShowsTheFullHotkey() throws {
        let binding = try #require(Top200Bindings.parse(Self.binding))
        let hotkey = Top200Bindings.reviewHotkey(binding)
        #expect(hotkey == "0x0a1c77edb48519069bbb154bf088c7f17678839de458e0679370ae989af3f55c")
        // all 64 hex digits, no ellipsis
        #expect(hotkey.count == 66)
        #expect(!hotkey.contains("…"))
    }

    @Test func longHexShortensForDisplay() {
        #expect(Top200Bindings.shortHex(Self.clientKey) == "0x79b5562e…049664")
        #expect(Top200Bindings.shortHex("0x1234") == "0x1234")
    }

    @Test func theLinkDecodesBase64UrlOnly() {
        #expect(Top200Bindings.decodeLinkBinding("eyJhIjoxfQ") == #"{"a":1}"#)
        #expect(Top200Bindings.decodeLinkBinding(Self.base64Url(Self.binding)) == Self.binding)
        // the url-safe alphabet: - and _ where base64 has + and /
        #expect(Top200Bindings.decodeLinkBinding("eyJ4Ijoifn5-Pz4-In0") == #"{"x":"~~~?>>"}"#)
        #expect(Top200Bindings.decodeLinkBinding("eyJ4Ijoi77u_Pz4ifQ") == "{\"x\":\"\u{FEFF}?>\"}")

        #expect(Top200Bindings.decodeLinkBinding(nil) == nil)
        #expect(Top200Bindings.decodeLinkBinding("") == nil)
        // standard base64 and padding are not base64url
        #expect(Top200Bindings.decodeLinkBinding("eyJhIjoxfQ==") == nil)
        #expect(Top200Bindings.decodeLinkBinding("ab+/") == nil)
        #expect(Top200Bindings.decodeLinkBinding("eyJh IjoxfQ") == nil)
        // a length no base64 has
        #expect(Top200Bindings.decodeLinkBinding("eyJhI") == nil)
        // not UTF-8 (0xff 0xfe)
        #expect(Top200Bindings.decodeLinkBinding("__4") == nil)
        // over 4096 characters, valid base64url or not
        let long = Self.base64Url(String(repeating: " ", count: 3 * 1366))
        #expect(long.count == 5464)
        #expect(Top200Bindings.decodeLinkBinding(long) == nil)
        #expect(Top200Bindings.decodeLinkBinding(String(repeating: "A", count: 4097)) == nil)
        #expect(Top200Bindings.decodeLinkBinding(String(repeating: "A", count: 4096)) != nil)
    }

    @Test func onlyTheSignLinkRoutes() {
        let link = URL(string: "urnetwork://top200/sign?binding=" + Self.base64Url(Self.binding))!
        #expect(Top200SignDestination(url: link) == Top200SignDestination(bindingText: Self.binding))
        // a bad binding still opens the screen, which shows it as invalid
        #expect(Top200SignDestination(url: URL(string: "urnetwork://top200/sign")!) == Top200SignDestination(bindingText: nil))
        #expect(Top200SignDestination(url: URL(string: "urnetwork://top200/sign?binding=" + String(repeating: "A", count: 4100))!)
            == Top200SignDestination(bindingText: nil))
        #expect(Top200SignDestination(url: URL(string: "urnetwork://top200/sign?binding=eyJhIjoxfQ==")!)
            == Top200SignDestination(bindingText: nil))
        // percent escapes are refused, not decoded (%49 is "I")
        #expect(Top200SignDestination(url: URL(string: "urnetwork://top200/sign?binding=eyJh%49joxfQ")!)
            == Top200SignDestination(bindingText: nil))
        #expect(Top200SignDestination(url: URL(string: "urnetwork://top200/sign?binding=eyJhIjoxfQ")!)
            == Top200SignDestination(bindingText: #"{"a":1}"#))
        // a repeated binding parameter is ambiguous: refused, not first or last
        #expect(Top200SignDestination(url: URL(string: "urnetwork://top200/sign?binding=eyJhIjoxfQ&binding=eyJhIjoyfQ")!)
            == Top200SignDestination(bindingText: nil))
        #expect(Top200SignDestination(url: URL(string: "urnetwork://top200/sign?binding=" + Self.base64Url(Self.binding) + "&binding=" + Self.base64Url(Self.binding))!)
            == Top200SignDestination(bindingText: nil))
        // another parameter beside a single binding is not a repeat
        #expect(Top200SignDestination(url: URL(string: "urnetwork://top200/sign?x=1&binding=eyJhIjoxfQ")!)
            == Top200SignDestination(bindingText: #"{"a":1}"#))
        // other links are not this one
        #expect(Top200SignDestination(url: URL(string: "urnetwork://top200/claim?binding=eyJhIjoxfQ")!) == nil)
        #expect(Top200SignDestination(url: URL(string: "urnetwork://onboarding/connect")!) == nil)
        #expect(Top200SignDestination(url: URL(string: "ur://top200/sign?binding=eyJhIjoxfQ")!) == nil)
        #expect(Top200SignDestination(url: URL(string: "https://ur.io/top200/sign?binding=eyJhIjoxfQ")!) == nil)
        // and this one is no other destination
        #expect(OnboardingDestination(url: link) == nil)
    }
}

/// A device with the fixture's client id and key that signs with the fixture's signature.
final class FakeTop200SignDevice: Top200SignDevice, @unchecked Sendable {

    private let stateLock = NSLock()
    private var signedBindings: [String] = []

    let deviceClientId: String?
    let deviceClientKey: String
    let result: Result<String, Error>

    init(
        clientId: String? = Top200BindingTests.clientId,
        clientKey: String = Top200BindingTests.clientKey,
        result: Result<String, Error> = .success(Top200BindingTests.signature)
    ) {
        self.deviceClientId = clientId
        self.deviceClientKey = clientKey
        self.result = result
    }

    var signed: [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return signedBindings
    }

    func clientId() -> String? {
        deviceClientId
    }

    func clientKey() -> String {
        deviceClientKey
    }

    func signFleetBinding(_ bindingJson: String) throws -> String {
        stateLock.lock()
        signedBindings.append(bindingJson)
        stateLock.unlock()
        return try result.get()
    }
}

struct FakeSignError: LocalizedError {
    var errorDescription: String? { "binding client_id is not this device" }
}

@MainActor
struct Top200SignModelTests {

    @Test func signingTheFixtureGivesTheSnPayload() async {
        let device = FakeTop200SignDevice()
        let model = Top200SignModel(device: device)
        await model.load()
        #expect(model.memberEntry == #"{"client_id":"0x019b2e105a7c4d3e8f0123456789abcd","client_key":"0x79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"}"#)
        model.bindingText = "\n" + Top200BindingTests.binding + "\n"
        #expect(model.canSign)
        #expect(model.error == nil)
        await model.sign()
        #expect(device.signed == [Top200BindingTests.binding])
        #expect(model.payload == Top200BindingTests.payload)
        #expect(!model.canSign)
        // an edit drops the payload
        model.bindingText = Top200BindingTests.binding + " "
        #expect(model.payload == nil)
        #expect(model.canSign)
    }

    @Test func theLinkOnlyFillsTheField() async {
        let device = FakeTop200SignDevice()
        let model = Top200SignModel(device: device, link: Top200SignDestination(bindingText: Top200BindingTests.binding))
        await model.load()
        #expect(model.bindingText == Top200BindingTests.binding)
        #expect(model.canSign)
        #expect(model.payload == nil)
        #expect(device.signed.isEmpty)
    }

    @Test func anUnreadableLinkShowsInvalid() async {
        let model = Top200SignModel(device: FakeTop200SignDevice(), link: Top200SignDestination(bindingText: nil))
        await model.load()
        #expect(model.error == .invalid)
        #expect(!model.canSign)
        model.bindingText = Top200BindingTests.binding
        #expect(model.error == nil)
    }

    @Test func anotherDevicesBindingIsNeverSigned() async {
        let device = FakeTop200SignDevice(clientKey: "0x" + String(repeating: "ab", count: 32))
        let model = Top200SignModel(device: device)
        await model.load()
        model.bindingText = Top200BindingTests.binding
        #expect(model.error == .otherDevice)
        #expect(!model.canSign)
        await model.sign()
        #expect(device.signed.isEmpty)
        #expect(model.payload == nil)
    }

    @Test func noClientKeyIsNeverSigned() async {
        let device = FakeTop200SignDevice(clientKey: "")
        let model = Top200SignModel(device: device)
        await model.load()
        #expect(model.keyLoaded)
        #expect(model.memberEntry == nil)
        model.bindingText = Top200BindingTests.binding
        #expect(model.error == .noKey)
        await model.sign()
        #expect(device.signed.isEmpty)
    }

    @Test func aFailedSignShowsTheSdkError() async {
        let model = Top200SignModel(device: FakeTop200SignDevice(result: .failure(FakeSignError())))
        await model.load()
        model.bindingText = Top200BindingTests.binding
        await model.sign()
        #expect(model.payload == nil)
        #expect(model.error == .failed("binding client_id is not this device"))

        let empty = Top200SignModel(device: FakeTop200SignDevice(result: .success("")))
        await empty.load()
        empty.bindingText = Top200BindingTests.binding
        await empty.sign()
        #expect(empty.payload == nil)
        #expect(empty.error == .failed("empty signature"))
    }
}
