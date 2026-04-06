//
//  Copyright © 2019-2021 Apple, Inc. All rights reserved.
//

import FXCore
import Atomics
import NIO
import NIOConcurrencyHelpers
import FXAsyncSupport
import XCTest

class FutureOperationQueueTests: XCTestCase {
    func testBasics() throws {
        let group = FXMakeDefaultDispatchGroup()
        defer { try! group.syncShutdownGracefully() }

        let loop = group.next()
        let p1 = loop.makePromise(of: Bool.self)
        let p2 = loop.makePromise(of: Bool.self)
        let p3 = loop.makePromise(of: Bool.self)
        var p1Started = false
        var p2Started = false
        var p3Started = false

        let manager = LLBOrderManager(on: group.next())

        let q = FXFutureOperationQueue(maxConcurrentOperations: 2)

        // Start the first two operations, they should run immediately.
        _ = q.enqueue(on: loop) { () -> FXFuture<Bool> in
            p1Started = true
            return manager.order(2).flatMap {
                p1.futureResult
            }
        }
        _ = q.enqueue(on: loop) { () -> FXFuture<Bool> in
            p2Started = true
            return manager.order(1).flatMap {
                p2.futureResult
            }
        }

        // Start the third, it should queue.
        _ = q.enqueue(on: loop) { () -> FXFuture<Bool> in
            p3Started = true
            return manager.order(4).flatMap {
                p3.futureResult
            }
        }

        try manager.order(3).wait()
        XCTAssertEqual(p1Started, true)
        XCTAssertEqual(p2Started, true)
        XCTAssertEqual(p3Started, false)

        // Complete the first.
        p1.succeed(true)
        try manager.order(5).wait()

        // Now p3 should have started.
        XCTAssertEqual(p3Started, true)
        p2.succeed(true)
        p3.succeed(true)

        _ = try! p1.futureResult.wait()
        _ = try! p2.futureResult.wait()
        _ = try! p3.futureResult.wait()
    }

    // Stress test.
    func testStress() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try! group.syncShutdownGracefully() }

        let q = FXFutureOperationQueue(maxConcurrentOperations: 2)

        let atomic = ManagedAtomic(0)
        var futures: [FXFuture<Bool>] = []
        let lock = NIOConcurrencyHelpers.NIOLock()
        DispatchQueue.concurrentPerform(iterations: 1_000) { i in
            let result = q.enqueue(on: group.next()) { () -> FXFuture<Bool> in
                // Check that we aren't executing more operations than we would want.
                let p = group.next().makePromise(of: Bool.self)
                let prior = atomic.loadThenWrappingIncrement(ordering: .relaxed)
                XCTAssert(prior >= 0 && prior < 2, "saw \(prior + 1) concurrent tasks at start")
                p.futureResult.whenComplete { _ in
                    let prior = atomic.loadThenWrappingDecrement(ordering: .relaxed)
                    XCTAssert(prior > 0 && prior <= 2, "saw \(prior) concurrent tasks at end")
                }

                // Complete the future at some point
                group.next().execute {
                    p.succeed(true)
                }

                return p.futureResult
            }

            lock.withLockVoid {
                futures.append(result)
            }
        }

        lock.withLockVoid {
            for future in futures {
                _ = try! future.wait()
            }
        }
    }

    // Test dynamic capacity increase.
    func testDynamic() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try! group.syncShutdownGracefully() }

        let manager = LLBOrderManager(on: group.next(), timeout: .seconds(5))

        let q = FXFutureOperationQueue(maxConcurrentOperations: 1)

        let opsInFlight = ManagedAtomic(0)

        let future1: FXFuture<Void> = q.enqueue(on: group.next()) {
            opsInFlight.wrappingIncrement(ordering: .relaxed)
            return manager.order(1).flatMap {
                manager.order(6) {
                    opsInFlight.wrappingDecrement(ordering: .relaxed)
                }
            }
        }

        let future2: FXFuture<Void> = q.enqueue(on: group.next()) {
            opsInFlight.wrappingIncrement(ordering: .relaxed)
            return manager.order(3).flatMap {
                manager.order(6) {
                    opsInFlight.wrappingDecrement(ordering: .relaxed)
                }
            }
        }

        // Wait until future1 adss to opsInFlight.
        try manager.order(2).wait()
        XCTAssertEqual(opsInFlight.load(ordering: .relaxed), 1)

        // The test breaks without this line.
        q.maxConcurrentOperations += 1

        try manager.order(4).wait()
        XCTAssertEqual(opsInFlight.load(ordering: .relaxed), 2)
        try manager.order(5).wait()

        try manager.order(7).wait()
        XCTAssertEqual(opsInFlight.load(ordering: .relaxed), 0)

        try future2.wait()
        try future1.wait()
    }

}
