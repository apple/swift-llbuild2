// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXCore
import Foundation
import NIO
import NIOConcurrencyHelpers

enum FutureOperationQueueError: Error {
    case eventLoopShutDown
}

/// A queue for future-producing operations, which limits how many can run
/// concurrently.
package final class FXFutureOperationQueue: Sendable {
    struct State: Sendable {
        /// Maximum allowed number of work items concurrently executing.
        var maxConcurrentOperations: Int

        /// The number of executing futures.
        var numExecuting = 0

        /// The user-specified "shares" that are currently being processed.
        var numSharesInFLight = 0

        /// The queue of operations to run.
        var workQueue = NIO.CircularBuffer<WorkItem>()
    }

    struct WorkItem {
        let loop: FXFuturesDispatchLoop
        let share: Int
        let notifyWhenScheduled: FXPromise<Void>?
        let run: () -> Void
    }

    private let state: NIOLockedValueBox<State>

    /// Maximum allowed number of shares concurrently executing.
    /// This option independently sets a cap on concurrency.
    private let maxConcurrentShares: Int

    package var maxConcurrentOperations: Int {
        get {
            return self.state.withLockedValue { state in
                return state.maxConcurrentOperations
            }
        }
        set {
            self.scheduleMoreTasks { state in
                state.maxConcurrentOperations = max(1, newValue)
            }
        }
    }

    /// Return the number of operations currently queued.
    package var opCount: Int {
        return self.state.withLockedValue { state in
            return state.numExecuting + state.workQueue.count
        }
    }

    /// Create a new limiter which will only initiate `maxConcurrentOperations`
    /// operations simultaneously.
    package init(maxConcurrentOperations: Int, maxConcurrentShares: Int = .max) {
        self.state = NIOLockedValueBox(
            State(maxConcurrentOperations: max(1, maxConcurrentOperations)))
        self.maxConcurrentShares = max(1, maxConcurrentShares)
    }

    /// NB: calls wait() on a current thread, beware.
    @available(
        *, noasync,
        message: "This method blocks indefinitely, don't use from 'async' or SwiftNIO EventLoops"
    )
    @available(*, deprecated, message: "This method blocks indefinitely and returns a future")
    package func enqueueWithBackpressure<T>(
        on loop: FXFuturesDispatchLoop, share: Int = 1, body: @escaping () -> FXFuture<T>
    ) -> FXFuture<T> {
        let scheduled = loop.makePromise(of: Void.self)

        let future: FXFuture<T> = enqueue(
            on: loop, share: share, notifyWhenScheduled: scheduled, body: body)

        try! scheduled.futureResult.wait()

        return future
    }

    /// Add an operation into the queue, which can run immediately
    /// or at some unspecified time in the future, as permitted by
    /// the `maxConcurrentOperations` setting.
    /// The `share` option independently controls maximum allowed concurrency.
    /// The queue can support low number of high-share loads, or high number of
    /// low-share loads. Useful to model queue size in bytes.
    /// For such use cases, set share to the payload size in bytes.
    package func enqueue<T>(
        on loop: FXFuturesDispatchLoop, share: Int = 1,
        notifyWhenScheduled: FXPromise<Void>? = nil, body: @escaping () -> FXFuture<T>
    ) -> FXFuture<T> {
        let promise = loop.makePromise(of: T.self)

        func runBody() {
            // Ensure we're on the event loop, fail the promise if not
            guard loop.inEventLoop else {
                promise.fail(FutureOperationQueueError.eventLoopShutDown)
                self.scheduleMoreTasks { state in
                    assert(state.numExecuting >= 1)
                    assert(state.numSharesInFLight >= share)
                    state.numExecuting -= 1
                    state.numSharesInFLight -= share
                }
                return
            }

            let f = body()
            f.whenComplete { _ in
                self.scheduleMoreTasks { state in
                    assert(state.numExecuting >= 1)
                    assert(state.numSharesInFLight >= share)
                    state.numExecuting -= 1
                    state.numSharesInFLight -= share
                }
            }
            f.cascade(to: promise)
        }

        let workItem = WorkItem(
            loop: loop, share: share, notifyWhenScheduled: notifyWhenScheduled, run: runBody)

        self.scheduleMoreTasks { state in
            state.workQueue.append(workItem)
        }

        return promise.futureResult
    }

    private func scheduleMoreTasks(performUnderLock: (inout State) -> Void) {
        // Decrement our counter, and get a new item to run if available.
        typealias Item = (loop: FXFuturesDispatchLoop, notify: FXPromise<Void>?, run: () -> Void)
        let toExecute: [Item] = self.state.withLockedValue { state in
            performUnderLock(&state)

            var scheduleItems: [Item] = []

            // If we have room to execute the operation,
            // do so immediately (outside the lock).
            while state.numExecuting < state.maxConcurrentOperations,
                state.numSharesInFLight < self.maxConcurrentShares
            {

                // Schedule a new operation, if available.
                guard let op = state.workQueue.popFirst() else {
                    break
                }

                state.numExecuting += 1
                state.numSharesInFLight += op.share
                scheduleItems.append((op.loop, op.notifyWhenScheduled, op.run))
            }

            return scheduleItems
        }

        for (loop, notify, run) in toExecute {
            loop.execute {
                notify?.succeed(())
                run()
            }
        }
    }
}
