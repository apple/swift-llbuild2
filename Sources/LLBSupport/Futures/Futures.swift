// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIO

public typealias LLBFuture<T> = NIO.EventLoopFuture<T>
public typealias LLBPromise<T> = NIO.EventLoopPromise<T>
public typealias LLBFuturesDispatchGroup = NIO.EventLoopGroup
public typealias LLBFuturesDispatchLoop = NIO.EventLoop


public func LLBMakeDefaultDispatchGroup() -> LLBFuturesDispatchGroup {
    return MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
}

public extension LLBPromise {
    /// Fulfill the promise from a returned value, or fail the promise if throws.
    @inlinable
    func fulfill(_ body: () throws -> Value) {
        do {
            try succeed(body())
        } catch {
            fail(error)
        }
    }
}
