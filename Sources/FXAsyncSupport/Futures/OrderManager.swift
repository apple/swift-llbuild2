// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 - 2026 Apple Inc. and the Swift project authors
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

package final class LLBOrderManager: Sendable {

    // A safety timer, not to be exceeded.
    private let cancelTimer = DispatchSource.makeTimerSource()
    private let timeout: DispatchTimeInterval

    private typealias WaitListElement = (
        order: Int, promise: FXPromise<Void>, file: String, line: Int
    )

    private enum GroupDesignator: Sendable {
        case managedGroup(FXFuturesDispatchGroup)
        case externallySuppliedGroup(FXFuturesDispatchGroup)
    }

    private struct State: Sendable {
        var waitlist = [WaitListElement]()
        var nextToRun = 1
        var groupDesignator: GroupDesignator
    }

    private let state: NIOLockedValueBox<State>

    private var eventLoop: EventLoop {
        state.withLockedValue { state in
            switch state.groupDesignator {
            case .managedGroup(let group):
                return group.next()
            case .externallySuppliedGroup(let group):
                return group.next()
            }
        }
    }

    package enum Error: Swift.Error {
        case orderManagerReset(file: String, line: Int)
    }

    package init(on loop: EventLoop, timeout: DispatchTimeInterval = .seconds(60)) {
        self.state = NIOLockedValueBox(State(groupDesignator: .externallySuppliedGroup(loop)))
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
    package func order<T: Sendable>(
        _ n: Int, file: String = #file, line: Int = #line, _ callback: @escaping @Sendable () throws -> T
    ) -> EventLoopFuture<T> {
        let promise = eventLoop.makePromise(of: Void.self)

        state.withLockedValue { state in
            state.waitlist.append((order: n, promise: promise, file: file, line: line))
        }

        let future = promise.futureResult.flatMapThrowing {
            try callback()
        }

        future.whenComplete { _ in
            self.state.withLockedValue { state in
                if n == state.nextToRun {
                    state.nextToRun += 1
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
        let wakeup: [EventLoopPromise<Void>] = state.withLockedValue { state in
            let wakeupPromises =
                state.waitlist
                .filter({ $0.order <= state.nextToRun })
                .map({ $0.promise })
            state.waitlist = state.waitlist.filter({ $0.order > state.nextToRun })
            return wakeupPromises
        }
        wakeup.forEach { $0.succeed(()) }
    }

    /// Fail all ordered callbacks. Not calling the callback functions
    /// specified as argument to order(_:_), but failing the outcome.
    package func reset(file: String = #file, line: Int = #line) -> EventLoopFuture<Void> {
        restartInactivityTimer()

        let futures = failPromises(file: file, line: line)

        return EventLoopFuture.whenAllSucceed(futures, on: eventLoop).map { [weak self] _ in
            guard let self = self else { return }
            self.state.withLockedValue { state in
                assert(state.waitlist.isEmpty)
                state.nextToRun = 1
            }
        }
    }

    @discardableResult
    private func failPromises(file: String = #file, line: Int = #line) -> [EventLoopFuture<Void>] {
        let toCancel: [WaitListElement] = state.withLockedValue { state in
            let cancelList = state.waitlist
            state.waitlist = []
            state.nextToRun = Int.max
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

        guard case .managedGroup(let group) = state.withLockedValue({ $0.groupDesignator }) else {
            return
        }

        let q = DispatchQueue(label: "tsf.OrderManager")
        q.async { try! group.syncShutdownGracefully() }
    }
}
