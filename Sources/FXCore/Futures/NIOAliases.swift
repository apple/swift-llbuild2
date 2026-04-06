// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIO
import TSCBasic
import TSCUtility

public typealias FXFuture<T> = NIO.EventLoopFuture<T>
public typealias FXPromise<T> = NIO.EventLoopPromise<T>
public typealias FXFuturesDispatchGroup = NIO.EventLoopGroup
public typealias FXFuturesDispatchLoop = NIO.EventLoop

public func FXMakeDefaultDispatchGroup() -> FXFuturesDispatchGroup {
    return MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
}

extension FXPromise {
    /// Fulfill the promise from a returned value, or fail the promise if throws.
    @inlinable
    public func fulfill(_ body: () throws -> Value) {
        do {
            try succeed(body())
        } catch {
            fail(error)
        }
    }
}

/// Support storing and retrieving dispatch group from a context
extension Context {
    public static func with(_ group: FXFuturesDispatchGroup) -> Context {
        return Context(
            dictionaryLiteral: (ObjectIdentifier(FXFuturesDispatchGroup.self), group as Any))
    }

    public var group: FXFuturesDispatchGroup {
        get {
            guard
                let group = self[
                    ObjectIdentifier(FXFuturesDispatchGroup.self), as: FXFuturesDispatchGroup.self
                ]
            else {
                fatalError("no futures dispatch group")
            }
            return group
        }
        set {
            self[ObjectIdentifier(FXFuturesDispatchGroup.self)] = newValue
        }
    }
}

extension FXFuture {
    public func fx_unwrapOptional<T>(
        orError error: Swift.Error
    ) -> EventLoopFuture<T> where Value == T? {
        self.flatMapThrowing { value in
            guard let value = value else {
                throw error
            }
            return value
        }
    }

    public func fx_unwrapOptional<T>(
        orStringError error: String
    ) -> EventLoopFuture<T> where Value == T? {
        fx_unwrapOptional(orError: StringError(error))
    }
}
