// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import NIOConcurrencyHelpers
import NIOCore

/// A simple in-memory implementation of the `FXFunctionCache` protocol.
public final class FXInMemoryFunctionCache: FXFunctionCache {
    /// The cache.
    private let cache = NIOLockedValueBox([HashableKey: FXDataID]())

    /// Threads capable of running futures.
    public let group: FXFuturesDispatchGroup

    /// The lock protecting content.
    let lock = NIOConcurrencyHelpers.NIOLock()

    /// Create an in-memory database.
    public init(group: FXFuturesDispatchGroup) {
        self.group = group
    }

    public func get(key: FXRequestKey, props: any FXKeyProperties, _ ctx: Context) -> FXFuture<FXDataID?> {
        return group.next().makeSucceededFuture(cache.withLockedValue { $0[HashableKey(key: key)] })
    }

    public func update(key: FXRequestKey, props: any FXKeyProperties, value: FXDataID, _ ctx: Context) -> FXFuture<Void> {
        return group.next().makeSucceededFuture(cache.withLockedValue { $0[HashableKey(key: key)] = value })
    }
}
