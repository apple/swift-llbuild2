// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors


/// A construct which expresses operations which can be asynchronously
/// cancelled. The cancellation is not guaranteed and no ordering guarantees
/// are provided with respect to the order of future's callbacks and the
/// cancel operation returning.
public struct LLBCancellableFuture<T>: LLBCancelProtocol {
    /// The underlying future.
    public let future: LLBFuture<T>

    /// The way to asynchronously cancel the operation backing up the future.
    public let canceller: LLBCanceller

    /// Initialize the future with a given canceller.
    public init(_ future: LLBFuture<T>, canceller specificCanceller: LLBCanceller? = nil) {
        self.future = future
        let canceller = specificCanceller ?? LLBCanceller()
        self.canceller = canceller
        self.future.whenComplete { _ in
            // Do not invoke the cancel handler if the future
            // has already terminated. This is a bit opportunistic
            // and can miss some cancellation invocations, but
            // we expect the cancellation handlers to be no-op
            // when cancelling something that's not there.
            canceller.abandon()
        }
    }

    /// Initialize with a given handler which can be
    /// subsequently invoked through self.canceller.cancel()
    public init(_ future: LLBFuture<T>, handler: LLBCancelProtocol) {
        self = LLBCancellableFuture(future, canceller: LLBCanceller(handler))
    }

    /// Conformance to the `CancelProtocol`.
    public func cancel(reason: String?) {
        canceller.cancel(reason: reason)
    }
}


/// Some surface compatibility with EventLoopFuture to minimize
/// the amount of code change in tests and other places.
extension LLBCancellableFuture {
    @inlinable
    public func wait() throws -> T {
        try future.wait()
    }
}
