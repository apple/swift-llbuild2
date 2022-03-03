import Foundation
import TSCUtility
import XCTest
import llbuild2fx

final class DeadlineTests: XCTestCase {
    func testDistantFutureDeadlineIsNil() {
        var ctx = Context()
        ctx.fxDeadline = Date.distantFuture

        let deadline = ctx.nioDeadline

        XCTAssertNil(deadline)
    }
}
