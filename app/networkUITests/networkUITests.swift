//
//  networkUITests.swift
//  networkUITests
//
//  Created by brien on 11/18/24.
//

import XCTest

final class networkUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Main UI"
        attachment.lifetime = .keepAlways
        add(attachment)

        print("URNETWORK_UI_HIERARCHY_BEGIN")
        print(app.debugDescription)
        print("URNETWORK_UI_HIERARCHY_END")
    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
