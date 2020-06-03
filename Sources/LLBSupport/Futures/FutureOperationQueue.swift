// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

import NIOConcurrencyHelpers
import NIO


/// A queue for future-producing operations, which limits how many can run
/// concurrently.
public final class LLBFutureOperationQueue {
    /// Maximum allowed number of work items concurrently executing.
    private let maxConcurrentOperations: Int

    /// Maximum allowed number of shares concurrently executing.
    /// This option independently sets a cap on concurrency.
    private let maxConcurrentShares: Int

    /// Lock protecting state.
    private let lock = NIOConcurrencyHelpers.Lock()

    /// The number of executing futures.
    private var numExecuting = 0

    /// The user-specified "shares" that are currently being processed.
    private var numSharesInFLight = 0

    private struct WorkItem {
        let loop: LLBFuturesDispatchLoop
        let share: Int
        let notifyWhenScheduled: LLBPromise<Void>?
        let run: () -> Void
    }

    /// The queue of operations to run.
    private var workQueue = NIO.CircularBuffer<WorkItem>()

    /// Create a new limiter which will only initiate `maxConcurrentOperations`
    /// operations simultaneously.
    public init(maxConcurrentOperations: Int, maxConcurrentShares: Int = .max) {
        self.maxConcurrentOperations = max(1, maxConcurrentOperations)
        self.maxConcurrentShares = max(1, maxConcurrentShares)
    }

    /// NB: calls wait() on a current thread, beware.
    public func enqueueWithBackpressure<T>(on loop: LLBFuturesDispatchLoop, share: Int = 1, body: @escaping () -> LLBFuture<T>) -> LLBFuture<T> {
        let scheduled = loop.makePromise(of: Void.self)

        let future: LLBFuture<T> = enqueue(on: loop, share: share, notifyWhenScheduled: scheduled, body: body)

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
    public func enqueue<T>(on loop: LLBFuturesDispatchLoop, share: Int = 1, notifyWhenScheduled: LLBPromise<Void>? = nil, body: @escaping () -> LLBFuture<T>) -> LLBFuture<T> {
        let promise = loop.makePromise(of: T.self)

        func runBody() {
            let f = body()
            f.whenComplete { _ in
                self.onTaskCompleted {
                    assert(self.numExecuting >= 1)
                    assert(self.numSharesInFLight >= share)
                    self.numExecuting -= 1
                    self.numSharesInFLight -= share
                }
            }
            f.cascade(to: promise)
        }

        let workItem = WorkItem(loop: loop, share: share, notifyWhenScheduled: notifyWhenScheduled, run: runBody)

        self.onTaskCompleted {
            workQueue.append(workItem)
        }

        return promise.futureResult
    }

    private func onTaskCompleted(performUnderLock: () -> Void) {
        // Decrement our counter, and get a new item to run if available.
        let toExecute: (loop: LLBFuturesDispatchLoop, notify: LLBPromise<Void>?, run: () -> Void)? = lock.withLock {
            performUnderLock()

            // If we have room to execute the operation, do so immediately
            // (outside the lock).
            guard numExecuting < maxConcurrentOperations,
                  numSharesInFLight < maxConcurrentShares else {
                return nil
            }

            // Schedule a new operation, if available.
            if let op = workQueue.popFirst() {
                self.numExecuting += 1
                self.numSharesInFLight += op.share
                return (op.loop, op.notifyWhenScheduled, op.run)
            }

            return nil
        }

        if let (loop, notify, run) = toExecute {
            loop.execute {
                notify?.succeed(())
                run()
            }
        }
    }
}
