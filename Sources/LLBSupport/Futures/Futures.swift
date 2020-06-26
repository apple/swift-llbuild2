// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIO

import TSCUtility

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


/// Support storing and retrieving dispatch group from a context
public extension Context {
    static func with(_ group: LLBFuturesDispatchGroup) -> Context {
        return Context(dictionaryLiteral: (ObjectIdentifier(LLBFuturesDispatchGroup.self), group as Any))
    }

    var group: LLBFuturesDispatchGroup {
        get {
            guard let group = self[ObjectIdentifier(LLBFuturesDispatchGroup.self)] else {
                fatalError("no futures dispatch group")
            }
            return group as! LLBFuturesDispatchGroup
        }
        set {
            self[ObjectIdentifier(LLBFuturesDispatchGroup.self)] = newValue
        }
    }
}
