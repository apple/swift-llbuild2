//
//  Copyright © 2019-2020 Apple, Inc. All rights reserved.
//

import FXCore
import NIO
import NIOConcurrencyHelpers
import FXAsyncSupport
import XCTest

class CancellablePromiseTests: XCTestCase {

    var group: EventLoopGroup!

    override func setUp() {
        super.setUp()

        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        super.tearDown()

        try! group.syncShutdownGracefully()
        group = nil
    }

    public enum GenericError: Swift.Error {
        case error
        case error1
        case error2
    }

    func testBasicSuccess() throws {
        let promise = LLBCancellablePromise<Void>(on: group.next())
        XCTAssertTrue(promise.succeed(()))
        XCTAssertNoThrow(try promise.futureResult.wait())
    }

    func testBasicFailure() throws {
        let promise = LLBCancellablePromise<Void>(on: group.next())
        XCTAssertTrue(promise.fail(GenericError.error))
        XCTAssertThrowsError(try promise.futureResult.wait())
    }

    func testCancel() throws {
        let promise = LLBCancellablePromise<Void>(on: group.next())
        XCTAssertTrue(promise.cancel(GenericError.error))
        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            XCTAssert(error is GenericError)
        }
        XCTAssertFalse(promise.succeed(()))
    }

    func testDoubleCancel() throws {
        let promise = LLBCancellablePromise<Void>(on: group.next())
        XCTAssertTrue(promise.cancel(GenericError.error))
        XCTAssertFalse(promise.cancel(GenericError.error1))
        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            guard case .error? = error as? GenericError else {
                XCTFail("Unexpected throw \(error)")
                return
            }
        }
        XCTAssertFalse(promise.fail(GenericError.error2))
    }

    func testLeakIsOK() throws {
        let _ = LLBCancellablePromise<Void>(on: group.next())
    }

}
