//
//  ExtenderPortMappingLineTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The line under the router port mapping switch (EXTENDER.md S10): one line
 * for each state the role reports, from the state, the method name and the
 * ports text alone, and none while off, while no role runs, in a state from a
 * newer device process, or for a mapping with no method or ports text to name.
 * The router's own words, which can name an address, never reach it.
 */
struct ExtenderPortMappingLineTests {

    private static let everyState = [
        SdkExtenderPortMappingOff,
        SdkExtenderPortMappingNotNeeded,
        SdkExtenderPortMappingMapping,
        SdkExtenderPortMappingMapped,
        SdkExtenderPortMappingFailed,
    ]

    // the router's words for a refusal, naming the gateway, and the external
    // address it gave: documentation addresses only
    private static let routerError = "upnp: AddPortMapping: 718 ConflictInMappingEntry at 192.0.2.1"
    private static let externalIp = "203.0.113.7"

    private func line(_ state: String, methodName: String = "", ports: String = "") -> String? {
        ExtenderPortMappingLine.of(state: state, methodName: methodName, ports: ports)
    }

    @Test func notNeededSaysThePublicAddress() {
        #expect(line(SdkExtenderPortMappingNotNeeded) == "Not needed: this device has a public address.")
    }

    @Test func mappingAsksTheRouter() {
        // one ellipsis character, as the catalog's key
        #expect(line(SdkExtenderPortMappingMapping) == "Asking your router\u{2026}")
    }

    @Test func mappedNamesThePortsThenTheMethod() {
        #expect(line(
            SdkExtenderPortMappingMapped,
            methodName: "UPnP",
            ports: "TCP 443, UDP 443, UDP 4053"
        ) == "Your router forwards TCP 443, UDP 443, UDP 4053 (UPnP).")
        // a router port other than the bound one, as the sdk writes it
        #expect(line(
            SdkExtenderPortMappingMapped,
            methodName: "NAT-PMP",
            ports: "TCP 40443→443, UDP 4053"
        ) == "Your router forwards TCP 40443→443, UDP 4053 (NAT-PMP).")
    }

    // a device process older than the two texts sends mapped without them: no
    // line rather than empty parentheses
    @Test func aMappingWithoutItsMethodOrPortsShowsNoLine() {
        #expect(line(SdkExtenderPortMappingMapped, methodName: "PCP") == nil)
        #expect(line(SdkExtenderPortMappingMapped, ports: "TCP 443") == nil)
        #expect(line(SdkExtenderPortMappingMapped) == nil)
    }

    @Test func failedSaysTheRouterDidNotOpenThePorts() {
        #expect(line(SdkExtenderPortMappingFailed) == "Your router didn't open the ports. Trying again later.")
    }

    @Test func offNoRoleAndAnUnknownStateShowNoLine() {
        for state in [SdkExtenderPortMappingOff, "", "something-newer"] {
            #expect(line(state) == nil, "\(state)")
            #expect(line(state, methodName: "PCP", ports: "TCP 443") == nil, "\(state)")
        }
    }

    @Test func onlyTheMappedLineReadsTheMethodAndThePorts() {
        for state in [
            SdkExtenderPortMappingNotNeeded,
            SdkExtenderPortMappingMapping,
            SdkExtenderPortMappingFailed,
        ] {
            #expect(line(state) != nil, "\(state)")
            #expect(line(state, methodName: "PCP", ports: "TCP 443") == line(state), "\(state)")
        }
    }

    // the sdk's own status through the model, in every state: the line is the
    // one drawn without the router's error and external address, and names
    // neither address
    @Test func theRoutersWordsNeverReachTheLine() {
        for state in Self.everyState + ["", "something-newer"] {
            let mapped = state == SdkExtenderPortMappingMapped
            let methodName = mapped ? "PCP" : ""
            let ports = mapped ? "TCP 443, UDP 4053" : ""
            let sdk = SdkExtenderProvideStatus()
            sdk.supported = true
            sdk.state = SdkExtenderProvideStateActive
            sdk.enabled = true
            sdk.portMapping = state
            sdk.portMappingMethodName = methodName
            sdk.portMappingPorts = ports
            sdk.portMappingError = Self.routerError
            sdk.portMappingExternalIp = Self.externalIp

            let text = ExtenderPortMappingLine.of(status: ExtenderProvideStatusModel(sdk))

            #expect(text == line(state, methodName: methodName, ports: ports), "\(state)")
            #expect(!(text ?? "").contains("192.0.2.1"), "\(state)")
            #expect(!(text ?? "").contains(Self.externalIp), "\(state)")
        }
    }
}
