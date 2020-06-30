// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOConcurrencyHelpers


/// A simple in-memory implementation of the `LLBFunctionCache` protocol.
public final class LLBInMemoryFunctionCache: LLBFunctionCache {
    /// The cache.
    private var cache = [Key: LLBDataID]()

    /// Threads capable of running futures.
    public let group: LLBFuturesDispatchGroup

    /// The lock protecting content.
    let lock = NIOConcurrencyHelpers.Lock()

    /// Create an in-memory database.
    public init(group: LLBFuturesDispatchGroup) {
        self.group = group
    }

    public func get(key: LLBKey, _ ctx: Context) -> LLBFuture<LLBDataID?> {
        return group.next().makeSucceededFuture(lock.withLock { cache[Key(key)] })
    }

    public func update(key: LLBKey, value: LLBDataID, _ ctx: Context) -> LLBFuture<Void> {
        return group.next().makeSucceededFuture(lock.withLockVoid { cache[Key(key)] = value })
    }
}
