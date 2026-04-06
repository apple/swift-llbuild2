// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXCore
import NIOCore

/// A construct which expresses operations which can be asynchronously
/// cancelled. The cancellation is not guaranteed and no ordering guarantees
/// are provided with respect to the order of future's callbacks and the
/// cancel operation returning.
package struct LLBCancellableFuture<T>: LLBCancelProtocol {
    /// The underlying future.
    package let future: FXFuture<T>

    /// The way to asynchronously cancel the operation backing up the future.
    package let canceller: LLBCanceller

    /// Initialize the future with a given canceller.
    package init(_ future: FXFuture<T>, canceller specificCanceller: LLBCanceller? = nil) {
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
    package init(_ future: FXFuture<T>, handler: LLBCancelProtocol) {
        self = LLBCancellableFuture(future, canceller: LLBCanceller(handler))
    }

    /// Conformance to the `CancelProtocol`.
    package func cancel(reason: String?) {
        canceller.cancel(reason: reason)
    }
}

/// Some surface compatibility with EventLoopFuture to minimize
/// the amount of code change in tests and other places.
extension LLBCancellableFuture {
    #if swift(>=5.7)
        @available(
            *, noasync, message: "wait() can block indefinitely, prefer get()", renamed: "get()"
        )
        @inlinable
        package func wait() throws -> T {
            try future.wait()
        }
    #else
        @inlinable
        package func wait() throws -> T {
            try future.wait()
        }
    #endif

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    @inlinable
    package func get() async throws -> T {
        try await future.get()
    }
}
