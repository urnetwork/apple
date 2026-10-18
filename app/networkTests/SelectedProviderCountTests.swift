import XCTest
@testable import URnetwork

final class SelectedProviderCountTests: XCTestCase {

    func testFetchedCountReplacesTheCountCopiedAtSelection() {
        // the location was selected with 12 providers; a later fetch has 40
        let count = selectedProviderCount(
            selectedId: "country:FR",
            selectedCount: 12,
            fetched: [("country:DE", 7), ("country:FR", 40)]
        )
        XCTAssertEqual(count, 40)
    }

    func testSelectionCountWhenTheLocationIsNotInTheFetchedList() {
        let count = selectedProviderCount(
            selectedId: "country:FR",
            selectedCount: 12,
            fetched: [("country:DE", 7)]
        )
        XCTAssertEqual(count, 12)
    }

    func testSelectionCountWhenNothingIsSelected() {
        XCTAssertEqual(selectedProviderCount(selectedId: nil, selectedCount: 0, fetched: [("country:DE", 7)]), 0)
    }
}
