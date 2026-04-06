// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXCore
import Dispatch
import NIO
import NIOConcurrencyHelpers

/// The `OrderManager` allows explicitly specify dependencies between
/// various callbacks. This is necessary to avoid or induce race conditions
/// in otherwise timing-dependent code, making such code deterministic.
/// The semantics is as follows: the `OrderManager` invokes callbacks
/// specified as arguments to the `order(_:_)` functions starting with 1.
/// The callbacks of order `n` are guaranteed to run to completion before
/// callbacks of order `n+1` are run. If there's a gap in the callbacks order
/// sequence, the callbacks are suspended until the missing callback is
/// registered, `reset()` is called, or global timeout occurs.
/// In addition to that, `reset()` restarts the global timeout.
///
/// Example:
///
///     let manager = OrderManager(on: ...)
///     manager.order(3, { print("3") })
///     manager.order(1, { print("1") })
///     manager.order(2, { print("2") })
///     try manager.order(4).wait()
///
/// The following will be printed out:
///
///     1
///     2
///     3
///

package class LLBOrderManager {

    // A safety timer, not to be exceeded.
    private let cancelTimer = DispatchSource.makeTimerSource()
    private let timeout: DispatchTimeInterval

    private typealias WaitListElement = (
        order: Int, promise: FXPromise<Void>, file: String, line: Int
    )
    private let lock = NIOConcurrencyHelpers.NIOLock()
    private var waitlist = [WaitListElement]()
    private var nextToRun = 1

    private var eventLoop: EventLoop {
        lock.withLock {
            switch groupDesignator {
            case .managedGroup(let group):
                return group.next()
            case .externallySuppliedGroup(let group):
                return group.next()
            }
        }
    }

    private enum GroupDesignator {
        case managedGroup(FXFuturesDispatchGroup)
        case externallySuppliedGroup(FXFuturesDispatchGroup)
    }
    private var groupDesignator: GroupDesignator

    package enum Error: Swift.Error {
        case orderManagerReset(file: String, line: Int)
    }

    package init(on loop: EventLoop, timeout: DispatchTimeInterval = .seconds(60)) {
        self.groupDesignator = GroupDesignator.externallySuppliedGroup(loop)
        self.timeout = timeout
        restartInactivityTimer()
        cancelTimer.setEventHandler { [weak self] in
            guard let self = self else { return }
            _ = self.reset()
            self.cancelTimer.cancel()
        }
        cancelTimer.resume()
    }

    private func restartInactivityTimer() {
        cancelTimer.schedule(deadline: DispatchTime.now() + timeout, repeating: .never)

    }

    /// Run a specified callback in a particular order.
    @discardableResult
    package func order<T>(
        _ n: Int, file: String = #file, line: Int = #line, _ callback: @escaping () throws -> T
    ) -> EventLoopFuture<T> {
        let promise = eventLoop.makePromise(of: Void.self)

        lock.withLockVoid {
            waitlist.append((order: n, promise: promise, file: file, line: line))
        }

        let future = promise.futureResult.flatMapThrowing {
            try callback()
        }

        future.whenComplete { _ in
            self.lock.withLockVoid {
                if n == self.nextToRun {
                    self.nextToRun += 1
                }
            }
            self.unblockWaiters()
        }

        unblockWaiters()
        return future
    }

    @discardableResult
    package func order(_ n: Int, file: String = #file, line: Int = #line) -> EventLoopFuture<Void> {
        return order(n, file: file, line: line, {})
    }

    private func unblockWaiters() {
        let wakeup: [EventLoopPromise<Void>] = lock.withLock {
            let wakeupPromises =
                waitlist
                .filter({ $0.order <= nextToRun })
                .map({ $0.promise })
            waitlist = waitlist.filter({ $0.order > nextToRun })
            return wakeupPromises
        }
        wakeup.forEach { $0.succeed(()) }
    }

    /// Fail all ordered callbacks. Not calling the callback functions
    /// specified as argument to order(_:_), but failing the outcome.
    package func reset(file: String = #file, line: Int = #line) -> EventLoopFuture<Void> {
        restartInactivityTimer()
        let lock = self.lock

        let futures = failPromises(file: file, line: line)

        return EventLoopFuture.whenAllSucceed(futures, on: eventLoop).map { [weak self] _ in
            guard let self = self else { return }
            lock.withLockVoid {
                assert(self.waitlist.isEmpty)
                self.nextToRun = 1
            }
        }
    }

    @discardableResult
    private func failPromises(file: String = #file, line: Int = #line) -> [EventLoopFuture<Void>] {
        let toCancel: [WaitListElement] = lock.withLock {
            let cancelList = waitlist
            waitlist = []
            nextToRun = Int.max
            return cancelList
        }
        let error = Error.orderManagerReset(file: file, line: line)
        return toCancel.sorted(by: { $0.order < $1.order }).map {
            $0.promise.fail(error)
            return $0.promise.futureResult.flatMapErrorThrowing { _ in () }
        }
    }

    deinit {
        cancelTimer.setEventHandler {}
        cancelTimer.cancel()

        failPromises()

        guard case .managedGroup(let group) = groupDesignator else {
            return
        }

        let q = DispatchQueue(label: "tsf.OrderManager")
        q.async { try! group.syncShutdownGracefully() }
    }
}
