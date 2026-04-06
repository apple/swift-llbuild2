// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import FXCore
import NIOConcurrencyHelpers
import NIOCore

/// Cache of keys to eventually obtainable values.
///
/// This cache coalesces requests and avoids re-obtaining values multiple times.
package final class LLBEventualResultsCache<Key: Hashable, Value>: FXFutureDeduplicator<Key, Value>
{
    /// The already cached keys.
    @usableFromInline
    internal var storage = [Key: FXFuture<Value>]()

    /// Return the number of entries in the cache.
    @inlinable
    package var count: Int {
        return lock.withLock { storage.count }
    }

    @inlinable
    override internal func lockedCacheGet(key: Key) -> FXFuture<Value>? {
        return storage[key]
    }

    @inlinable
    override internal func lockedCacheSet(_ key: Key, _ future: FXFuture<Value>) {
        storage[key] = future
    }

    @inlinable
    package override subscript(_ key: Key) -> FXFuture<Value>? {
        get { return super[key] }
        set { lock.withLockVoid { storage[key] = newValue } }
    }
}
