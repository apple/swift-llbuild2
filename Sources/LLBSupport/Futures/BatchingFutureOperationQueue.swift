// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation


/// Run the given computations on a given array in batches, exercising
/// a specified amount of parallelism.
///
/// - Discussion:
///     For some blocking operations (such as file system accesses) executing
///     them on the NIO loops is very expensive since it blocks the event
///     processing machinery. Here we use extra threads for such operations.
public struct LLBBatchingFutureOperationQueue {

    /// Threads capable of running futures.
    public let group: LLBFuturesDispatchGroup

    /// Queue of outstanding operations.
    @usableFromInline
    let operationQueue: OperationQueue

    /// Maximum number of operations executed concurrently.
    public let maxOpCount: Int

    /// Return the number of operations currently queued.
    @inlinable
    public var opCount: Int {
        return operationQueue.operationCount
    }

    /// Whether the queue is suspended.
    @inlinable
    public var isSuspended: Bool {
        return operationQueue.isSuspended
    }

    ///
    /// - Parameters:
    ///    - name:      Unique string label, for logging.
    ///    - group:     Threads capable of running futures.
    ///    - maxConcurrentOperationCount:
    ///                 Operations to execute in parallel.
    @inlinable
    public init(name: String, group: LLBFuturesDispatchGroup, maxConcurrentOperationCount maxOpCount: Int, qualityOfService: QualityOfService = .default) {
        self.group = group
        self.maxOpCount = maxOpCount
        self.operationQueue = OperationQueue(llbWithName: name, maxConcurrentOperationCount: maxOpCount)
        self.operationQueue.qualityOfService = qualityOfService
    }

    @inlinable
    public func execute<T>(_ body: @escaping () throws -> T) -> LLBFuture<T> {
        let promise = group.next().makePromise(of: T.self)
        operationQueue.addOperation {
            promise.fulfill(body)
        }
        return promise.futureResult
    }

    @inlinable
    public func execute<T>(_ body: @escaping () -> LLBFuture<T>) -> LLBFuture<T> {
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
    public func execute<A,T>(_ args: [A], minStride: Int = 1, _ body: @escaping (ArraySlice<A>) throws -> [T]) -> LLBFuture<[T]> {
        let futures: [LLBFuture<[T]>] = executeNoWait(args, minStride: minStride, body)
        let loop = futures.first?.eventLoop ?? group.next()
        return LLBFuture<[T]>.whenAllSucceed(futures, on: loop).map{$0.flatMap{$0}}
    }

    /// Order-preserving parallel execution.
    /// Do not wait for all executions to complete, returning individual futures.
    @inlinable
    public func executeNoWait<A,T>(_ args: [A], minStride: Int = 1, maxStride: Int = Int.max, _ body: @escaping (ArraySlice<A>) throws -> [T]) -> [LLBFuture<[T]>] {
        let batches: [ArraySlice<A>] = args.llbSliceBy(maxStride: max(minStride, min(maxStride, args.count / maxOpCount)))
        return batches.map{arg in execute{try body(arg)}}
    }

}
