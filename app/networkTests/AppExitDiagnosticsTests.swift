//
//  AppExitDiagnosticsTests.swift
//  networkTests
//
//  Why the app's earlier processes ended (AppExitDiagnostics, support 8190):
//  the app subscribes to MetricKit at launch once its log directory is set,
//  and hands the payloads' times to the sdk in unix milliseconds. What the sdk
//  makes of a payload, and that the upload carries it, is pinned in the sdk
//  (exit_diagnostics_*_test.go) and through the real sdk in
//  FeedbackLogUploadTests.
//

#if canImport(MetricKit)

import Testing
import Foundation
@testable import URnetwork

struct AppExitDiagnosticsTests {

    /// A payload's NSDate crosses as unix milliseconds; a time before 1970,
    /// or none the sdk can take, as 0, and the sdk then reads the json's.
    @Test func payloadTimesCrossAsUnixMillis() {
        #expect(AppExitDiagnostics.unixMillis(Date(timeIntervalSince1970: 1_794_316_740)) == 1_794_316_740_000)
        #expect(AppExitDiagnostics.unixMillis(Date(timeIntervalSince1970: 1.5)) == 1_500)
        #expect(AppExitDiagnostics.unixMillis(Date(timeIntervalSince1970: 0)) == 0)
        #expect(AppExitDiagnostics.unixMillis(.distantPast) == 0)
    }

    // …/apple/app/networkTests/AppExitDiagnosticsTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The app subscribes at launch, after the log directory is configured,
    /// since the sdk writes the file into it, and not under hosted unit tests.
    @Test func theAppSubscribesAtLaunchAfterItsLogDirectory() throws {
        let app = try String(
            contentsOf: Self.appRoot.appendingPathComponent("network/NetworkApp.swift"),
            encoding: .utf8
        )
        let configure = try #require(app.range(of: "DiagnosticsLogLocation.configure(processName:"))
        let start = try #require(app.range(of: "AppExitDiagnostics.shared.start()"))
        #expect(configure.upperBound < start.lowerBound)
        #expect(app.contains("if startupMode.allowsStartupInitialization && !hostsUnitTests {\n            AppExitDiagnostics.shared.start()"))
    }
}

#endif
