// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXCore
import Foundation
import NIOCore
import TSCUtility

/// Run the given computations on a given array in batches, exercising
/// a specified amount of parallelism.
///
/// - Discussion:
///     For some blocking operations (such as file system accesses) executing
///     them on the NIO loops is very expensive since it blocks the event
///     processing machinery. Here we use extra threads for such operations.
package struct LLBBatchingFutureOperationQueue: Sendable {

    /// Threads capable of running futures.
    package let group: FXFuturesDispatchGroup

    /// Queue of outstanding operations.
    @usableFromInline
    let operationQueue: OperationQueue

    /// Because `LLBBatchingFutureOperationQueue` is a struct, the compiler
    /// will claim that `maxOpCount`'s setter is `mutating`, even though
    /// `OperationQueue` is a threadsafe class.
    /// This method exists as a workaround to adjust the underlying concurrency
    /// of the operation queue without unnecessary synchronization.
    package func setMaxOpCount(_ maxOpCount: Int) {
        operationQueue.maxConcurrentOperationCount = maxOpCount
    }

    /// Maximum number of operations executed concurrently.
    package var maxOpCount: Int {
        get { operationQueue.maxConcurrentOperationCount }
        set { self.setMaxOpCount(newValue) }
    }

    /// Return the number of operations currently queued.
    @inlinable
    package var opCount: Int {
        return operationQueue.operationCount
    }

    /// Whether the queue is suspended.
    @inlinable
    package var isSuspended: Bool {
        return operationQueue.isSuspended
    }

    ///
    /// - Parameters:
    ///    - name:      Unique string label, for logging.
    ///    - group:     Threads capable of running futures.
    ///    - maxConcurrentOperationCount:
    ///                 Operations to execute in parallel.
    @inlinable
    package init(
        name: String, group: FXFuturesDispatchGroup, maxConcurrentOperationCount maxOpCount: Int,
        qualityOfService: QualityOfService = .default
    ) {
        self.group = group
        self.operationQueue = OperationQueue(
            fx_withName: name, maxConcurrentOperationCount: maxOpCount)
        self.operationQueue.qualityOfService = qualityOfService
    }

    @inlinable
    package func execute<T>(_ body: @escaping () throws -> T) -> FXFuture<T> {
        let promise = group.next().makePromise(of: T.self)
        operationQueue.addOperation {
            promise.fulfill(body)
        }
        return promise.futureResult
    }

    @inlinable
    package func execute<T>(_ body: @escaping () -> FXFuture<T>) -> FXFuture<T> {
        let promise = group.next().makePromise(of: T.self)
        operationQueue.addOperation {
            let f = body()
            f.cascade(to: promise)

            // Wait for completion, to ensure we maintain at most N concurrent operations.
            _ = try? f.wait()
        }
        return promise.futureResult
    }

    /// Order-preserving parallel execution. Wait for everything to complete.
    @inlinable
    package func execute<A, T>(
        _ args: [A], minStride: Int = 1, _ body: @escaping (ArraySlice<A>) throws -> [T]
    ) -> FXFuture<[T]> {
        let futures: [FXFuture<[T]>] = executeNoWait(args, minStride: minStride, body)
        let loop = futures.first?.eventLoop ?? group.next()
        return FXFuture<[T]>.whenAllSucceed(futures, on: loop).map { $0.flatMap { $0 } }
    }

    /// Order-preserving parallel execution.
    /// Do not wait for all executions to complete, returning individual futures.
    @inlinable
    package func executeNoWait<A, T>(
        _ args: [A], minStride: Int = 1, maxStride: Int = Int.max,
        _ body: @escaping (ArraySlice<A>) throws -> [T]
    ) -> [FXFuture<[T]>] {
        let batches: [ArraySlice<A>] = args.tsc_sliceBy(
            maxStride: max(minStride, min(maxStride, args.count / maxOpCount)))
        return batches.map { arg in execute { try body(arg) } }
    }

}
