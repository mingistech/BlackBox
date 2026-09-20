import XCTest
@testable import BlackBoxCore

final class PromptHistoryTests: XCTestCase {
    func testHistoryOrderAndDraftRestoration() {
        var history = PromptHistory()
        XCTAssertNil(history.previous(draft: "draft"))
        XCTAssertNil(history.next())
        history.record("first")
        history.record("second")
        XCTAssertEqual(history.previous(draft: "unfinished draft"), "second")
        XCTAssertEqual(history.previous(draft: "second"), "first")
        XCTAssertEqual(history.previous(draft: "first"), "first")
        XCTAssertEqual(history.next(), "second")
        XCTAssertEqual(history.next(), "unfinished draft")
        XCTAssertNil(history.next())
    }

    func testResendingResetsNavigationAndSkipsAdjacentDuplicates() {
        var history = PromptHistory()
        history.record("first")
        history.record("second")
        history.record(" second \n")
        XCTAssertEqual(history.previous(draft: ""), "second")
        XCTAssertEqual(history.previous(draft: "second"), "first")
        history.record("edited first")
        XCTAssertEqual(history.previous(draft: "new draft"), "edited first")
        XCTAssertEqual(history.next(), "new draft")
    }
}
